#!/usr/bin/env bash
# L4 探测的盲区实验：NodePort 能 TCP 建连，但 HTTP 出不来时，L4 探测会说"健康"。
#
# 做法：在 infra 节点上插一条 nat PREROUTING DNAT，把 :31000 的入向流量劫持到
#       一个「accept 之后立刻关闭连接」的 TCP sink（alpine: nc -l -k -e /bin/true）。
#       kube-proxy 的链还在，三次握手照样成功 → L4 探测认为这个节点可用；
#       但 HTTP 层没有任何响应 → 业务请求会真的掉（GET 靠重试兜住，POST 直接 502）。
#
# 对照组：同样的故障注入，把探测换成 L7（探 /healthz 判 200）→ 节点会被摘掉 → 不掉。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROBE="$ROOT/scripts/ingress-probe.py"
NODE=${NODE:-ingress-lab-worker2}
NODEPORT=${NODEPORT:-31000}
OUT=${OUT:-/tmp/l4-blindspot}
DUR=${DUR:-30}
RATE=${RATE:-5}
mkdir -p "$OUT"

NIP=$(kubectl get node "$NODE" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' | awk '{print $1}')
echo "############ L4 盲区实验：在 $NODE ($NIP) 上把 :$NODEPORT 接到一个「只握手不回答」的 TCP sink ############"

cleanup() {
  docker exec "$NODE" iptables -t nat -D PREROUTING -p tcp --dport "$NODEPORT" \
      -j DNAT --to-destination "${SINK_IP:-0.0.0.0}:8080" 2>/dev/null
  kubectl delete pod tcp-sink -n demo --ignore-not-found --wait=false >/dev/null 2>&1
}
trap cleanup EXIT

# 1) 起 sink（只监听、accept 后立刻关闭，永远不吐 HTTP）
kubectl apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata: { name: tcp-sink, namespace: demo }
spec:
  nodeSelector: { kubernetes.io/hostname: "$NODE" }
  tolerations: [{ key: node-role.kubernetes.io/infra, operator: Exists, effect: NoSchedule }]
  containers:
    - name: sink
      image: alpine:3.20
      command: ["nc","-l","-p","8080","-k","-e","/bin/true"]
YAML
kubectl wait --for=condition=Ready pod/tcp-sink -n demo --timeout=60s >/dev/null
SINK_IP=$(kubectl get pod tcp-sink -n demo -o jsonpath='{.status.podIP}')
echo "  sink pod: tcp-sink @ $SINK_IP:8080 (accept 即关)"

# 2) 劫持 NodePort（插在 kube-proxy 的 KUBE-SERVICES 跳转之前）
docker exec "$NODE" iptables -t nat -I PREROUTING 1 -p tcp --dport "$NODEPORT" \
  -j DNAT --to-destination "$SINK_IP:8080"
echo "  已插入: iptables -t nat -I PREROUTING 1 -p tcp --dport $NODEPORT -j DNAT --to $SINK_IP:8080"
sleep 2

# 3) 关键：两种探测对同一个节点的判断
echo; echo "===== 同一个节点，L4 探测 vs L7 探测 ====="
docker run --rm --network kind alpine:3.20 sh -c "
if nc -z -w 2 $NIP $NODEPORT; then echo '  L4 (nc -z)      -> 连接成功  ⇒ 判定【健康】'; else echo '  L4 (nc -z)      -> 失败        ⇒ 判定【不可用】'; fi
code=\$(wget -S -O- -q -T 2 http://$NIP:$NODEPORT/healthz 2>&1 >/dev/null | awk '/HTTP\//{print \$2; exit}')
echo \"  L7 (/healthz)   -> HTTP='\${code:-<无响应>}'  ⇒ 判定【不可用】\"
"
echo "  当前 upstream 成员:"; grep 'server ' "$ROOT/nginx/upstream/nodeports.conf" | sed 's/^/    /'

# 4) 打流量：GET（可重试）和 POST（非幂等，nginx 默认不重试）
run() { # $1=method $2=tag
  echo; echo "----- ${HC_MODE:-l4} 探测下，$1 请求 ${DUR}s -----"
  python3 "$PROBE" probe --method "$1" --duration "$DUR" --rate "$RATE" --host demo.local \
    --out "$OUT/$2.csv" 2>&1 | tail -7
  docker logs nginx-external --since 1m > "$OUT/$2.nginx.log" 2>&1
  python3 "$PROBE" analyze --logfile "$OUT/$2.nginx.log" | sed -n '1,12p'
}
HC_MODE=$(docker inspect nginx-external --format '{{range .Config.Env}}{{println .}}{{end}}' \
          | sed -n 's/^HC_MODE=//p'); export HC_MODE
run GET  "$HC_MODE-get"
run POST "$HC_MODE-post"

# 5) 换成 L7 探测，同样的故障注入再来一遍
echo; echo "===== 切换成 L7 探测（探 /healthz），等它把这个「TCP 通、HTTP 死」的节点摘掉 ====="
HC_MODE=l7 HC_INTERVAL=${HC_INTERVAL:-2} HC_FAIL=${HC_FAIL:-2} HC_OK=${HC_OK:-2} \
  "$ROOT/scripts/external-nginx.sh" >/dev/null 2>&1
sleep $(( ${HC_INTERVAL:-2} * ${HC_FAIL:-2} + 4 ))
docker logs nginx-external --since 1m 2>&1 | grep -E '^\[hc ' | tail -4 | sed 's/^/  /'
echo "  摘流后 upstream 成员:"; grep 'server ' "$ROOT/nginx/upstream/nodeports.conf" | sed 's/^/    /'
run POST l7-post

echo; echo "===== 结论对照 ====="
for f in "$OUT"/*.csv; do
  [ -f "$f" ] || continue
  python3 - "$f" <<'PY'
import csv,sys,collections,statistics
rows=list(csv.DictReader(open(sys.argv[1])))
st=collections.Counter(r["status"] for r in rows)
ms=[float(r["ms"]) for r in rows]
bad=sum(1 for r in rows if r["status"]!="200" or r["err"])
print(f"  {sys.argv[1].split('/')[-1]:<16} n={len(rows):4d} 200={st.get('200',0):4d} 非200/失败={bad:3d} "
      f"p50={statistics.median(ms) if ms else 0:.0f}ms max={max(ms) if ms else 0:.0f}ms")
PY
done
trap - EXIT
cleanup
