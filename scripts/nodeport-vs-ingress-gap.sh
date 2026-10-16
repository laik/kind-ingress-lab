#!/usr/bin/env bash
# 量 "NodePort 的中断/恢复" 与 "ingress-nginx 的实际可用" 之间的 GAP。
#
# 对同一个 infra 节点，每 0.5s 采样四条独立信号：
#   A tcp      : nc -z <node>:31000            ← kube-proxy 的 NodePort 路径（LB 的 L4 探测看到的就是这个）
#   B healthz  : GET http://<node>:31000/healthz ← ingress 默认 server（LB 的 L7 探测看到的就是这个）
#   C biz      : GET http://<node>:31000/  Host: demo.local ← 业务路由真的能服务吗
#   D k8s      : 该节点上 Ready 的 ingress pod 数（= EndpointSlice 里有没有这个节点的本地 endpoint）
#
# 用法: ./scripts/nodeport-vs-ingress-gap.sh [node] [restart|stop|drain]
set -uo pipefail
NODE=${1:-ingress-lab-worker2}
ACTION=${2:-restart}
OUT=${OUT:-/tmp/gap-$NODE}
SECS=${SECS:-150}
NODEPORT=${NODEPORT:-31000}
NS=ingress-nginx
SEL=app.kubernetes.io/component=controller
mkdir -p "$OUT"

nip() { kubectl get node "$1" -o 'jsonpath={.status.addresses[?(@.type=="InternalIP")].address}' | awk '{print $1}'; }
IP=$(nip "$NODE")
echo "节点 $NODE = $IP:$NODEPORT   动作=$ACTION   采样 ${SECS}s"

# ---- 数据面采样（在 kind 网络里的容器里跑，避免宿主机不可达 172.18.0.x）----
docker exec nginx-external sh -c "
END=\$(( \$(date +%s) + $SECS ))
while [ \$(date +%s) -lt \$END ]; do
  tcp=\$(nc -z -w 1 $IP $NODEPORT >/dev/null 2>&1 && echo TCP-OK || echo '  --  ')
  hz=\$(wget -S -O- -q -T 1 http://$IP:$NODEPORT/healthz 2>&1 >/dev/null | awk '/HTTP\//{print \$2; exit}')
  biz=\$(wget -S -O- -q -T 1 --header='Host: demo.local' http://$IP:$NODEPORT/ 2>&1 >/dev/null | awk '/HTTP\//{print \$2; exit}')
  echo \"\$(date -u '+%H:%M:%S') \$tcp healthz=\${hz:----} biz=\${biz:----}\"
  sleep 1
done" > "$OUT/dataplane.txt" 2>&1 &
DP=$!

# ---- 控制面采样 ----
( ENDC=$(( $(date +%s) + SECS )); while [ $(date +%s) -lt $ENDC ]; do
    pods=$(kubectl -n "$NS" get pods -l "$SEL" --field-selector "spec.nodeName=$NODE" \
            -o 'jsonpath={range .items[*]}{.status.podIP}{" "}{end}' 2>/dev/null)
    r=$(kubectl -n "$NS" get pods -l "$SEL" --field-selector "spec.nodeName=$NODE" \
         -o 'jsonpath={range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null \
         | grep -c '^True$' || true)
    eps=$(kubectl -n "$NS" get endpointslices -l kubernetes.io/service-name=ingress-nginx-controller \
           -o json 2>/dev/null | PODS="$pods" python3 -c '
import json,sys,os
want=set(p for p in os.environ.get("PODS","").split() if p)
d=json.load(sys.stdin); n=0
for s in d.get("items",[]):
    for e in s.get("endpoints",[]):
        if e.get("conditions",{}).get("ready") and any(a in want for a in e.get("addresses",[])):
            n+=1
print(n)' 2>/dev/null || echo "?")
    ready=$(kubectl get node "$NODE" -o 'jsonpath={.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "?")
    echo "$(date -u '+%H:%M:%S') nodeReady=$ready podsReadyOnNode=${r:-0} localEndpoints=${eps:-?}"
    sleep 1
  done ) > "$OUT/controlplane.txt" 2>&1 &
CP=$!

sleep 5
echo ">>> 执行 $ACTION"
T0=$(date -u '+%H:%M:%S')
case "$ACTION" in
  restart) docker restart "$NODE" >/dev/null ;;
  stop)    docker stop  "$NODE" >/dev/null ;;
  drain)   kubectl cordon "$NODE" >/dev/null 2>&1
           kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --force --grace-period=60 --timeout=180s >/dev/null 2>&1 ;;
esac
echo "    于 $T0"

wait $DP $CP 2>/dev/null
[ "$ACTION" = stop ] && docker start "$NODE" >/dev/null && echo "(已 docker start 复原)"

echo; echo "===== 时间线（只打印状态发生变化的时刻）====="
python3 - "$OUT/dataplane.txt" "$OUT/controlplane.txt" "$T0" <<'PY'
import sys, re
dp = [l for l in open(sys.argv[1]) if l.strip()]
cp = [l for l in open(sys.argv[2]) if l.strip()]
def parse(line, keys):
    p = line.split()
    t = p[0]
    tcp = p[1] if len(p) > 1 else "?"
    vals = {"tcp": tcp}
    for k in keys:
        m = re.search(rf"{k}=(\S+)", line)
        vals[k] = m.group(1) if m else "?"
    return t, vals
prev = None
print(f"{'时间':<10} {'tcp':<7} {'healthz':<8} {'biz':<8}  控制面")
for line in dp:
    t, v = parse(line, ["healthz", "biz"])
    ctl = next((c for c in cp if c.startswith(t)), "")
    state = (v["tcp"], v["healthz"], v["biz"], ctl[len(t):].strip())
    if state != prev:
        print(f"{t:<10} {v['tcp']:<7} {v['healthz']:<8} {v['biz']:<8}  {ctl[len(t):].strip()}")
        prev = state
PY
echo; echo "原始数据: $OUT/dataplane.txt  $OUT/controlplane.txt"
