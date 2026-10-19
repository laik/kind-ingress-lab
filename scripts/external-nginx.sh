#!/usr/bin/env bash
# 启动/重建「集群外 nginx」：
#   - nginx.conf 由模板渲染，upstream 成员交给容器内的主动健康检查动态维护
#   - 启动前先用一次性探测把 nodeports.conf 预热，避免冷启动空窗
# HC_MODE=l7（默认，探 /healthz 判 200）| l4（只做 TCP connect）
set -euo pipefail

CLUSTER=${CLUSTER:-ingress-lab}
CTX=kind-${CLUSTER}
NODEPORT=${NODEPORT:-31000}
HOST_PORT=${HOST_PORT:-8080}
CONTAINER=nginx-external
NET=${NET:-kind}
HC_MODE=${HC_MODE:-l7}
HC_PATH=${HC_PATH:-/healthz}
HC_INTERVAL=${HC_INTERVAL:-2}   # 探测间隔（s）
HC_FAIL=${HC_FAIL:-2}          # 连续失败几次摘流
HC_OK=${HC_OK:-2}              # 连续成功几次加回
HC_TIMEOUT=${HC_TIMEOUT:-2}    # 单次探测超时（s）；L4 下就是 nc -w 的超时
HC_ENABLED=${HC_ENABLED:-1}      # 0 = 不起探测循环（纯静态池，见 EVIDENCE.md T12）
HC_CONNECT_TIMEOUT=${HC_CONNECT_TIMEOUT:-500ms}   # 探测窗口期内打到死节点的代价上限

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONF_DIR="$ROOT/nginx/conf"
UP_DIR="$ROOT/nginx/upstream"
SC_DIR="$ROOT/nginx/scripts"
export HC_CONNECT_TIMEOUT
mkdir -p "$CONF_DIR" "$UP_DIR"

# 1) 候选节点 = 所有 infra-node（只取 IPv4）
CAND=$(kubectl --context "$CTX" get nodes -l node-role.kubernetes.io/infra=true \
       -o 'jsonpath={.items[*].status.addresses[?(@.type=="InternalIP")].address}' \
       | tr ' ' '\n' | grep -E '^[0-9]+(\.[0-9]+){3}$' || true)
if [ -z "$CAND" ]; then
  echo "没找到 infra 节点（label: node-role.kubernetes.io/infra=true）" >&2
  exit 1
fi
CAND_ONELINE=$(echo $CAND)
# 注意：必须先写临时文件再 mv。直接 `> nodes` 会先把文件截断，
# 容器里的 healthcheck 正好撞上就会读到空列表 → upstream 被清空 → “no live upstreams” → 502。
printf '%s\n' $CAND > "$UP_DIR/.nodes.tmp" && mv "$UP_DIR/.nodes.tmp" "$UP_DIR/nodes"
echo "候选 infra 节点 (写入 $UP_DIR/nodes):"
sed 's/^/  /' "$UP_DIR/nodes"

# 2) 一次性探测预热 nodeports.conf（在 kind 网络里跑）
if [ "$HC_MODE" = "l4" ]; then
  SEED=$(docker run --rm --network "$NET" alpine:3.20 sh -c "
for ip in $CAND_ONELINE; do
  if nc -z -w $HC_TIMEOUT \"\$ip\" $NODEPORT; then echo \"IN \$ip\"; else echo \"OUT \$ip (tcp-timeout)\"; fi
done")
else
  SEED=$(docker run --rm --network "$NET" alpine:3.20 sh -c "
for ip in $CAND_ONELINE; do
  code=\$(wget -S -O- -q -T $HC_TIMEOUT \"http://\$ip:$NODEPORT$HC_PATH\" 2>&1 >/dev/null | awk '/HTTP\//{print \$2; exit}')
  if [ \"\$code\" = \"200\" ]; then echo \"IN \$ip\"; else echo \"OUT \$ip (\$code)\"; fi
done")
fi
echo "${HC_MODE} 预热探测:"
echo "$SEED" | awk '{printf "  %s = %s\n",$2,$1}'
IPS=$(echo "$SEED" | awk '$1=="IN"{print $2}')
[ -n "$IPS" ] || { echo "没有任何节点通过 ${HC_MODE} 探测，仍会启动 nginx（upstream 置 down，返回 502）" >&2; }

{ echo "# 预热生成 (mode=${HC_MODE})，之后由容器内 healthcheck.sh 维护"
  for ip in $IPS; do echo "        server $ip:$NODEPORT max_fails=3 fail_timeout=15s;"; done
  [ -n "$IPS" ] || echo "        server 127.0.0.1:1 down;"
} > "$UP_DIR/nodeports.conf"

# 3) 渲染 nginx.conf
python3 - "$CONF_DIR/nginx.conf.tmpl" "$CONF_DIR/nginx.conf" <<'PY'
import os, sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
s = s.replace("__UPSTREAM_SERVERS__", "")
s = s.replace("__CONNECT_TIMEOUT__", os.environ.get("HC_CONNECT_TIMEOUT", "500ms"))
open(dst, "w").write(s)
PY
echo "generated: $CONF_DIR/nginx.conf (proxy_connect_timeout=$HC_CONNECT_TIMEOUT)"

# 4) 起容器（自定义 entrypoint：后台健康检查 + 前台 nginx）
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run -d --name "$CONTAINER" \
  --network "$NET" \
  -p "${HOST_PORT}:80" \
  -v "$CONF_DIR/nginx.conf:/etc/nginx/nginx.conf:ro" \
  -v "$SC_DIR:/etc/nginx/scripts:ro" \
  -v "$UP_DIR:/etc/nginx/upstream" \
  -e HC_MODE="$HC_MODE" -e HC_PORT="$NODEPORT" -e HC_PATH="$HC_PATH" \
  -e HC_INTERVAL="$HC_INTERVAL" -e HC_FAIL="$HC_FAIL" -e HC_OK="$HC_OK" \
  -e HC_TIMEOUT="$HC_TIMEOUT" -e HC_ENABLED="$HC_ENABLED" \
  --restart unless-stopped \
  --entrypoint /bin/sh \
  nginx:1.27-alpine /etc/nginx/scripts/entrypoint.sh >/dev/null
sleep 3

echo
echo "=== 外部 nginx (${HC_MODE} 主动探测已启用) ==="
docker ps --filter "name=$CONTAINER" --format '{{.Names}}\t{{.Status}}\t{{.Ports}}'
echo "  当前 upstream 成员:"; sed 's/^/    /' "$UP_DIR/nodeports.conf"
echo
echo "=== 验证 ==="
curl -sS -m 10 "http://127.0.0.1:${HOST_PORT}/" | grep -E 'Hostname|^Host:|^GET' | sed 's/^/  /'
curl -sS -m 10 -H 'Host: api.demo.local' "http://127.0.0.1:${HOST_PORT}/v1" | grep -E 'Hostname|^GET' | sed 's/^/  /'
printf "  nginx 自身健康: "; curl -sS -m 5 "http://127.0.0.1:${HOST_PORT}/nginx-health"
echo "  healthcheck 日志:"
docker logs "$CONTAINER" 2>&1 | grep -E '^\[hc |^\[entrypoint' | tail -4 | sed 's/^/    /'
