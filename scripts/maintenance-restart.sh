#!/usr/bin/env bash
# 维护窗口重启一台 infra 节点：LB 动态标记 upstream down → 等流量排空 → 节点侧兜底 → drain → reboot → 标 up
#
#   maintenance-restart.sh <node> [wait-conn-seconds]
#
# 每一步都打绝对时间戳（UTC HH:MM:SS），便于和客户端 CSV / nginx access log 对齐做归因。
#
# 和 graceful-reboot-infra.sh（§4G/§4J，纯节点侧、不碰 LB）的区别：
#   本脚本走 LB：标记 down 之后**新请求立刻不再来**（不用等 LB 探测失败），动作可审计；
#   代价是 2 次 reload（摘 + 加）——开源 nginx 没有运行时 API，`down` 是静态参数。
#   同时写 manual_hold.list：让容器内的自动健康检查**不要**再去 REMOVE/ADD，
#   否则它会自己再加两次 reload，既多打断客户端连接，也让归因变混乱。
#
# 顺序要点（实测踩过的坑）：
#   1. 先 LB 标 down，再 cordon。反过来会留一个"已 cordon 但流量还在进"的窗口。
#   2. 标 down 后要等连接排空：down 只挡新请求；不过实测 reload 时旧 worker 退出会顺手
#      关掉它到该节点的上游 keepalive 连接，所以 conns 会很快归 0。
#   3. 节点侧再补一刀 nat 摘流：兜住 LB 之外的客户端（监控探测、直连 NodePort、第二个 LB）。
#   4. reboot 完要**先 uncordon**，否则 pod 永远 Pending，等不到 Ready；
#      先 uncordon 是安全的，因为此时 LB 里这个成员还是 down。
#   5. 等节点 Ready 且该节点 /healthz 真能通，再标 up。反过来会把流量打到没有本地 endpoint 的节点。
set -uo pipefail
NODE=${1:?用法: maintenance-restart.sh <node> [wait-conn-seconds]}
WAIT_CONN=${2:-60}
PORTS=${PORTS:-"31000 31001"}
DEAD_PORT=1
NS=ingress-nginx
SEL=app.kubernetes.io/component=controller
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MHOLD=$ROOT/nginx/upstream/manual_hold.list
LBC=${LBC:-nginx-external}

log() { printf '%s %s\n' "$(date -u '+%H:%M:%S')" "$*"; }
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
probe_ok() { local p=${PORTS%% *}; docker exec "$LBC" sh -c "wget -S -O- -q -T3 http://$IP:$p/healthz" >/dev/null 2>&1; }
abort() { log "中止，恢复现场"; rules_off; hold_off; "$ROOT/scripts/lb-mark.sh" "$IP" up >/dev/null 2>&1; kubectl uncordon "$NODE" >/dev/null 2>&1; exit 130; }
trap abort INT TERM

log "[1/9] LB 动态标记 upstream down: $IP"
"$ROOT/scripts/lb-mark.sh" "$IP" down || abort
log "[2/9] 通知自动健康检查保持该节点在线（避免它再加两次 reload）"
hold_on; log "      manual_hold: [$(tr '\n' ' ' < "$MHOLD")]"

log "[3/9] 等 LB 到该节点的连接排空（上限 ${WAIT_CONN}s）"
deadline=$(( $(date +%s) + WAIT_CONN ))
while :; do
  n=$(conns)
  log "      conns=${n}"
  [ "$n" -eq 0 ] && break
  [ $(date +%s) -ge "$deadline" ] && { log "      超时仍有残留，继续（drain 会收尾）"; break; }
  sleep 3
done

log "[4/9] 节点侧兜底摘流（兜住 LB 之外的客户端）"
rules_on; log "      :31000/:31001 新连接现在会被内核 RST"

log "[5/9] cordon + drain ${NODE}"
kubectl cordon "$NODE" >/dev/null
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --force \
       --grace-period=60 --timeout=180s >/dev/null 2>&1 || log "      (drain 有告警：TSC 硬约束下被驱逐 pod 会 Pending，正常)"

log "[6/9] reboot（本实验用 docker restart；生产 = reboot）"
trap - INT TERM
rules_off
docker restart "$NODE" >/dev/null

log "[7/9] 等节点 Ready"
st=""
for i in $(seq 1 60); do
  st=$(kubectl get node "$NODE" -o 'jsonpath={.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  [ "$st" = "True" ] && break
  sleep 5
done
log "      Ready=${st}"

log "[8/9] uncordon（让 pod 能调度回来；LB 里这个成员仍是 down）"
kubectl uncordon "$NODE" >/dev/null
for i in $(seq 1 40); do
  rdy=$(kubectl -n "$NS" get pods -l "$SEL" --field-selector spec.nodeName="$NODE" \
        -o 'jsonpath={range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null | grep -c True)
  [ "${rdy:-0}" -ge 1 ] && break
  sleep 5
done
log "      该节点 Ready 的 ingress pod: ${rdy:-0}"

log "[9/9] 等该节点 /healthz 连续 2 次通过 → LB 标 up → 解除 hold"
ok=0
for i in $(seq 1 60); do
  if probe_ok; then ok=$((ok + 1)); else ok=0; fi
  [ "$ok" -ge 2 ] && break
  sleep 3
done
if [ "$ok" -ge 2 ]; then log "      探测连续通过"; else log "      !! 180s 内探测仍不通，仍标 up（人工确认）"; fi
"$ROOT/scripts/lb-mark.sh" "$IP" up || log "      (标 up 失败，需人工确认 upstream 列表)"
hold_off
sleep 8
log "结果:"; grep 'server ' "$ROOT/nginx/upstream/nodeports.conf" 2>/dev/null | sed 's/^/        /'
kubectl -n "$NS" get pods -l "$SEL" -o 'jsonpath={range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort | uniq -c | sed 's/^/      pod: /'
curl -sS -m 5 -o /dev/null -w '      入口探活: %{http_code}\n' -H 'Host: demo.local' http://127.0.0.1:8080/
