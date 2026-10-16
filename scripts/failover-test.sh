#!/usr/bin/env bash
# 故障演练（主动探测版）：关掉一个 infra-node，验证 nginx 能否自动摘流/加回
#   HC_MODE=l7（默认）探 /healthz；HC_MODE=l4 只做 TCP connect
#
#   A 基线 30s
#   B 停掉 infra 节点，观察 90s   <-- 期望: 探测窗口内有少量慢请求，之后自动摘干净
#   C 恢复节点，观察 60s          <-- 期望: 连续 OK_MAX 次探测成功后自动加回
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROBE="$ROOT/scripts/ingress-probe.py"
export HC_MODE=${HC_MODE:-l7}
export HC_INTERVAL=${HC_INTERVAL:-2} HC_FAIL=${HC_FAIL:-2} HC_OK=${HC_OK:-2} HC_TIMEOUT=${HC_TIMEOUT:-2}
DEAD_NODE=${DEAD_NODE:-ingress-lab-worker2}
OUT=${OUT:-/tmp/failover-$HC_MODE}
METHOD=${METHOD:-GET}          # POST 用来验证非幂等请求会不会真的掉
PHASE_A=${PHASE_A:-30}; PHASE_B=${PHASE_B:-90}; PHASE_C=${PHASE_C:-60}
mkdir -p "$OUT"

dead_ip() { kubectl get node "$DEAD_NODE" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' | awk '{print $1}'; }
snap()    { docker logs nginx-external --since 4m > "$OUT/$1.nginx.log" 2>&1; }
hcl()     { docker logs nginx-external --since 4m 2>&1 | grep -E '^\[hc '; }
dist()    { kubectl -n ingress-nginx get pods -l app.kubernetes.io/component=controller \
              -o 'jsonpath={range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort | uniq -c | sed 's/^/    /'; }

phase() { echo; echo "----- 阶段 $1: ${2}s ($METHOD) -----";
  python3 "$PROBE" probe --method "$METHOD" --duration "$2" --rate 5 --host demo.local --out "$OUT/$1-$METHOD.csv" 2>&1 | tail -8; snap "$1"; }

echo "############ ${HC_MODE} 主动探测版演练: 关闭 $DEAD_NODE ############"
"$ROOT/scripts/external-nginx.sh" >/dev/null 2>&1
echo "  upstream 初始成员:"; grep 'server ' "$ROOT/nginx/upstream/nodeports.conf" | sed 's/^/  /'
echo "  探测参数: mode=${HC_MODE} interval=${HC_INTERVAL}s fail=${HC_FAIL} ok=${HC_OK} probe_timeout=${HC_TIMEOUT}s → 摘流约需 $(( HC_INTERVAL * HC_FAIL + HC_TIMEOUT ))s"
echo "  ingress pod 分布:"; dist

phase A "$PHASE_A"

DIP=$(dead_ip)
echo; echo ">>> docker stop $DEAD_NODE ($DIP)"
docker stop "$DEAD_NODE" >/dev/null; date '+  停止于 %H:%M:%S'
( for i in $(seq 1 9); do sleep 10
    printf "  t=+%3ds node=%-7s upstream成员=%s\n" $((i*10)) \
      "$(kubectl get node $DEAD_NODE -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo '?')" \
      "$(grep -c 'server ' "$ROOT/nginx/upstream/nodeports.conf")"
  done ) & WATCHER=$!
phase B "$PHASE_B"
kill $WATCHER 2>/dev/null; wait $WATCHER 2>/dev/null

echo; echo "===== 摘流时间线（healthcheck 日志）====="; hcl | sed 's/^/  /'
echo; echo "===== 阶段 B：nginx 侧分析 ====="; python3 "$PROBE" analyze --logfile "$OUT/B.nginx.log"
echo; echo "===== 阶段 B：客户端 vs upstream 链路 ====="; python3 "$PROBE" join --csvfile "$OUT/B-$METHOD.csv" --logfile "$OUT/B.nginx.log"

echo; echo ">>> docker start $DEAD_NODE"; docker start "$DEAD_NODE" >/dev/null
sleep 45; kubectl get node "$DEAD_NODE" --no-headers | awk '{print "  "$1" "$2}'
# 只刷新候选列表（不重启容器），验证运行中的 healthcheck 能自动加回新 IP
kubectl --context "kind-${CLUSTER:-ingress-lab}" get nodes -l node-role.kubernetes.io/infra=true \
  -o 'jsonpath={.items[*].status.addresses[?(@.type=="InternalIP")].address}' | tr ' ' '\n' \
  | grep -E '^[0-9]+(\.[0-9]+){3}$' > "$ROOT/nginx/upstream/.nodes.tmp"
# 非原子重写会瞬间把候选列表截成空，导致 healthcheck 把 upstream 清空（no live upstreams → 502）
[ -s "$ROOT/nginx/upstream/.nodes.tmp" ] && mv "$ROOT/nginx/upstream/.nodes.tmp" "$ROOT/nginx/upstream/nodes" \
  || rm -f "$ROOT/nginx/upstream/.nodes.tmp"
echo "  刷新后的候选节点:"; sed 's/^/    /' "$ROOT/nginx/upstream/nodes"
phase C "$PHASE_C"
echo; echo "===== 加回时间线 ====="; hcl | tail -5 | sed 's/^/  /'
echo "  最终 upstream 成员:"; grep 'server ' "$ROOT/nginx/upstream/nodeports.conf" | sed 's/^/  /'
echo "  ingress pod 分布:"; dist
