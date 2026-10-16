#!/usr/bin/env bash
# 计划内维护重启一台 infra 节点：**完全在节点侧完成摘流**，不碰 LB 配置、不触发 reload。
#
#   graceful-reboot-infra.sh <node> [wait-conn-seconds]
#
# 实测最优（§4J）：5585 请求 0 个非200、0 个客户端断连、**0 次 reload**。
#
# 关键设计：
#   * 节点侧摘流用 `iptables -t nat -I PREROUTING 1 ... -j DNAT --to <nodeIP>:1`。
#     不能用 REJECT：kube-proxy 的 DNAT 在 nat PREROUTING，包到 filter INPUT 时 dport 已是 podIP:80，
#     `--dport 31000` 的 REJECT 在"还有本地 endpoint"时是空操作；REJECT 放 mangle PREROUTING 被内核拒。
#   * 写 manual_hold.list 告诉 LB 的健康检查"这台在维护，别摘"：
#     否则健康检查会因为探测失败而 REMOVE/ADD ⇒ 两次 reload ⇒ 每次打断 3~8/5000 个客户端连接。
#     节点侧已经把新连接变成 RST 了，LB 会自己重试到别的节点，客户端无感。
#   * 不要在 reboot 前删规则：规则随 netns 消失，提前删会留下一个 kube-proxy DROP 的黑洞窗口
#     （实测造成 17 次 500ms 的 connect 超时）。
#   * 恢复顺序：reboot → 等 Ready → **先 uncordon**（cordon 下 pod 永远 Pending）→
#     等该节点 /healthz 真的能通 → 再从 hold 名单移除。反了会让 LB 把流量打到没有 endpoint 的节点。
#
# 用法: graceful-reboot-infra.sh <node> [wait-conn-seconds]
set -uo pipefail
NODE=${1:?用法: graceful-reboot-infra.sh <node> [wait-conn-seconds]}
WAIT_CONN=${2:-60}
PORTS=${PORTS:-"31000 31001"}
DEAD_PORT=${DEAD_PORT:-1}
NS=ingress-nginx
SEL=app.kubernetes.io/component=controller
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MHOLD=$ROOT/nginx/upstream/manual_hold.list     # 容器内 /etc/nginx/upstream/manual_hold.list
LBC=${LBC:-nginx-external}

exec_i() { docker exec "$NODE" "$@"; }
IP=$(kubectl get node "$NODE" -o 'jsonpath={.status.addresses[?(@.type=="InternalIP")].address}' | awk '{print $1}')
[ -n "$IP" ] || { echo "拿不到 $NODE 的 InternalIP"; exit 1; }

conns() {
  local n=0 c p
  for p in $PORTS; do
    c=$(exec_i sh -c "conntrack -L -p tcp --dport $p 2>/dev/null | grep -c ESTABLISHED || true")
    c=$(printf '%s' "$c" | tr -dc '0-9'); [ -n "$c" ] || c=0
    n=$((n + c))
  done
  echo "$n"
}
rules_on() {
  for p in $PORTS; do
    exec_i iptables -t nat -C PREROUTING -p tcp --dport "$p" -j DNAT --to-destination "$IP:$DEAD_PORT" 2>/dev/null ||
    exec_i iptables -t nat -I PREROUTING 1 -p tcp --dport "$p" -j DNAT --to-destination "$IP:$DEAD_PORT"
  done
}
rules_off() {
  for p in $PORTS; do
    exec_i iptables -t nat -D PREROUTING -p tcp --dport "$p" -j DNAT --to-destination "$IP:$DEAD_PORT" 2>/dev/null || true
  done
}
hold_on()  { touch "$MHOLD"; grep -qx "$IP" "$MHOLD" || echo "$IP" >> "$MHOLD"; }
hold_off() { if [ -f "$MHOLD" ]; then grep -vx "$IP" "$MHOLD" > "$MHOLD.tmp" 2>/dev/null || true; mv "$MHOLD.tmp" "$MHOLD"; fi; }
probe_ok() { # 从 LB 容器里探一下该节点的 /healthz（和健康检查同一个信号）
  local p=${PORTS%% *}
  docker exec "$LBC" sh -c "wget -S -O- -q -T3 http://$IP:$p/healthz" >/dev/null 2>&1
}
abort() { echo "(中止，恢复现场)"; rules_off; hold_off; kubectl uncordon "$NODE" >/dev/null 2>&1; exit 130; }
trap abort INT TERM

echo "[1/8] cordon ${NODE}"
kubectl cordon "$NODE" >/dev/null

echo "[2/8] 通知 LB 健康检查保持该节点在线（避免白白两次 reload）+ 节点侧摘流"
hold_on
rules_on
echo "      hold: [$(tr '\n' ' ' < "$MHOLD")]"
echo "      新连接会被内核 RST（不是黑洞）；当前连接数: $(conns)"

echo "[3/8] 等连接排空（最多 ${WAIT_CONN}s）"
deadline=$(( $(date +%s) + WAIT_CONN ))
while :; do
  n=$(conns)
  printf "      t=+%3ds conns=%s\n" $(( WAIT_CONN - (deadline - $(date +%s)) )) "$n"
  [ "$n" -eq 0 ] && break
  [ $(date +%s) -ge "$deadline" ] && { echo "      超时仍有残留连接，继续（drain 会收尾）"; break; }
  if [ $(( deadline - $(date +%s) )) -le $(( WAIT_CONN / 2 )) ]; then
    for p in $PORTS; do exec_i sh -c "conntrack -D -p tcp --dport $p >/dev/null 2>&1 || true"; done
  fi
  sleep 5
done

echo "[4/8] drain ${NODE}"
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --force \
       --grace-period=60 --timeout=180s >/dev/null 2>&1 || echo "      (drain 有告警：TSC 硬约束下被驱逐 pod 会 Pending，正常)"

echo "[5/8] reboot（本实验用 docker restart；生产 = reboot / 换硬件）"
trap - INT TERM
rules_off            # 只为了中途失败时不残留；正常路径下规则会随 netns 消失，
                     # 但这里删掉是为了让"节点已下线"这件事由 kube-proxy 的 DROP 表达 —— 
                     # 实测会引入 500ms 黑洞窗口，所以放到 restart 前最后一刻再删。
docker restart "$NODE" >/dev/null

echo "[6/8] 等节点 Ready"
st=""
for i in $(seq 1 60); do
  st=$(kubectl get node "$NODE" -o 'jsonpath={.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  [ "$st" = "True" ] && break
  sleep 5
done
echo "      Ready=${st}"

echo "[7/8] uncordon（让 pod 能被调度回来；LB 侧该节点仍在 hold 里，不会被摘）"
kubectl uncordon "$NODE" >/dev/null
for i in $(seq 1 40); do
  rdy=$(kubectl -n "$NS" get pods -l "$SEL" --field-selector spec.nodeName="$NODE" \
        -o 'jsonpath={range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null | grep -c True)
  [ "${rdy:-0}" -ge 1 ] && break
  sleep 5
done
echo "      该节点 Ready 的 ingress pod: ${rdy:-0}"

echo "[8/8] 等该节点 /healthz 真的能通（连续 2 次），再解除 hold（交还给 LB 的正常逻辑）"
# 实测这里要等够久：uncordon 之后 Deployment 重建 3 个 pod + kube-proxy 同步 endpoint，
# 60s 不够（当时只有 1 个 pod Ready）。给到 180s，并且要求连续 2 次通过再解除。
ok=0
for i in $(seq 1 60); do
  if probe_ok; then ok=$((ok + 1)); else ok=0; fi
  [ "$ok" -ge 2 ] && break
  sleep 3
done
if [ "$ok" -ge 2 ]; then echo "      探测连续通过，解除 hold"; hold_off
else echo "      !! 180s 内探测仍不通：保持 hold（LB 不会摘它），需要人工确认"; fi
sleep 8
echo "      upstream:"; grep 'server ' "$ROOT/nginx/upstream/nodeports.conf" 2>/dev/null | sed 's/^/        /'
kubectl -n "$NS" get pods -l "$SEL" -o 'jsonpath={range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort | uniq -c | sed 's/^/      pod: /'
