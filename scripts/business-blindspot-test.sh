#!/usr/bin/env bash
# 场景 S4：业务面故障 —— 节点可达、NodePort 通、/healthz 也 200，但这条业务路由服务不了。
#
# 注入方式：在目标节点上把「ingress pod → 业务 pod」的 FORWARD 包 DROP 掉。
#   · NodePort 的入向包（LB → pod）不受影响 ⇒ TCP 照样握手、默认 server 的 /healthz 照样 200
#   · ingress 代理到后端的出向包被丢 ⇒ 业务请求 10s 后 504（proxy_read_timeout）
# 这正是能力矩阵里「L4 和 L7 默认 /healthz 都看不见」的那一类故障。
#
# 对照组：
#   1) LB 用默认 L7 探测（探默认 server 的 /healthz，不带业务 Host）→ 判定健康 → 流量继续进来 → 掉
#   2) LB 用 canary 探测（HC_HOST=canary.demo.local，走真实 server/location/upstream 全链路）
#      → 判定不可用 → 6s 内摘除 → 不掉
#
# 用法: ./scripts/business-blindspot-test.sh [node]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NODE=${1:-ingress-lab-worker2}
NODEPORT=${NODEPORT:-31000}
OUT=${OUT:-/tmp/business-blindspot}
DUR=${DUR:-30}
RATE=${RATE:-5}
CANARY_HOST=${CANARY_HOST:-canary.demo.local}
mkdir -p "$OUT"

NIP=$(kubectl get node "$NODE" -o 'jsonpath={.status.addresses[?(@.type=="InternalIP")].address}' | awk '{print $1}')
# 本节点 pod 的 CIDR（kind 每节点一个 /24）+ 其它节点 pod 的 CIDR
# ⚠ 只能用 pod 网段（10.x）：172.18.0.0/24 是 kind 的 docker 网络，LB 就在里面；
#   DROP 掉「pod → 172.18.0.0/24」会把响应包也干掉，连 TCP 握手都成不了（实测踩过）。
SELF_PREFIX=$(kubectl get pod -n ingress-nginx -l app.kubernetes.io/component=controller \
                --field-selector "spec.nodeName=$NODE" -o 'jsonpath={.items[0].status.podIP}' | awk -F. '{print $1"."$2"."$3}')
SELF_NET="$SELF_PREFIX.0/24"
ALL_NETS=$(kubectl get pods -A -o 'jsonpath={.items[*].status.podIP}' | tr ' ' '\n' \
             | grep -E '^10\.' | awk -F. '{print $1"."$2"."$3}' | sort -u \
             | grep -v "^$SELF_PREFIX$" | awk '{print $1".0/24"}')
echo "############ 业务面故障：在 $NODE ($NIP) 上 DROP 掉 $SELF_NET → 业务 pod 的 FORWARD 包 ############"
echo "  受影响网段: $(echo $ALL_NETS)"

cleanup() {
  for n in $ALL_NETS; do
    docker exec "$NODE" iptables -D FORWARD -s "$SELF_NET" -d "$n" -j DROP 2>/dev/null || true
  done
}
trap cleanup EXIT

apply_rules() { for n in $ALL_NETS; do docker exec "$NODE" iptables -I FORWARD 1 -s "$SELF_NET" -d "$n" -j DROP; done; }

run() { # $1=tag $2=描述
  echo; echo "----- $2：${DUR}s × ${RATE}rps POST -----"
  python3 "$ROOT/scripts/ingress-probe.py" probe --method POST --duration "$DUR" --rate "$RATE" \
      --host demo.local --out "$OUT/$1.csv" 2>&1 | tail -6
  docker logs nginx-external --since 2m > "$OUT/$1.nginx.log" 2>&1
  python3 "$ROOT/scripts/ingress-probe.py" analyze --logfile "$OUT/$1.nginx.log" | sed -n '1,10p'
}

# 1) 注入故障
apply_rules
sleep 2
echo; echo "===== 同一个节点，三种信号的判断（故障已注入）====="
docker run --rm --network kind alpine:3.20 sh -c "
nc -z -w 2 $NIP $NODEPORT >/dev/null 2>&1 && echo '  L4  TCP :31000        -> 握手成功        ⇒ 判定【健康】' || echo '  L4  TCP :31000        -> 失败            ⇒ 判定【不可用】'
c1=\$(wget -S -O- -q -T 3 http://$NIP:$NODEPORT/healthz 2>&1 >/dev/null | awk '/HTTP\//{print \$2; exit}')
echo \"  L7  /healthz 默认server -> HTTP='\${c1:-超时}'      ⇒ 判定【健康】\"
c2=\$(wget -S -O- -q -T 3 --header=Host:$CANARY_HOST http://$NIP:$NODEPORT/healthz 2>&1 >/dev/null | awk '/HTTP\//{print \$2; exit}')
echo \"  L7  canary 业务路由     -> HTTP='\${c2:-超时}'      ⇒ 判定【不可用】\"
"

# 2) 对照 A：默认 L7 探测（探 /healthz，不带业务 Host）—— 看不见这个故障
echo; echo "===== 对照 A：LB 用默认 L7 探测（/healthz，无业务 Host）→ 节点不会被摘 ====="
HC_MODE=l7 HC_HOST= HC_INTERVAL=2 HC_FAIL=2 HC_OK=2 "$ROOT/scripts/external-nginx.sh" >/dev/null 2>&1
sleep 4
grep -E '^\[hc ' <(docker logs nginx-external 2>&1) | tail -2 | sed 's/^/  /'
echo "  upstream 成员:"; grep 'server ' "$ROOT/nginx/upstream/nodeports.conf" | sed 's/^/    /'
run A-default-l7 "默认 L7 探测（看不见业务面故障）"

# 3) 对照 B：canary 探测 —— 能看见，摘掉
echo; echo "===== 对照 B：LB 用 canary 探测（走真实业务路由）→ 应摘除该节点 ====="
HC_MODE=l7 HC_HOST=$CANARY_HOST HC_INTERVAL=2 HC_FAIL=2 HC_OK=2 "$ROOT/scripts/external-nginx.sh" >/dev/null 2>&1
sleep $(( 2 * 2 + 4 ))
docker logs nginx-external 2>&1 | grep -E '^\[hc ' | tail -3 | sed 's/^/  /'
echo "  upstream 成员:"; grep 'server ' "$ROOT/nginx/upstream/nodeports.conf" | sed 's/^/    /'
run B-canary "canary 探测（能看见业务面故障）"

echo; echo "===== 对照汇总 ====="
python3 - "$OUT"/*.csv <<'PY'
import csv,sys,collections,statistics
for f in sys.argv[1:]:
    rows=list(csv.DictReader(open(f)))
    st=collections.Counter(r["status"] for r in rows)
    ms=[float(r["ms"]) for r in rows]
    bad=sum(1 for r in rows if r["status"]!="200" or r["err"])
    print(f"  {f.split('/')[-1]:<20} n={len(rows):4d} 200={st.get('200',0):4d} 非200/失败={bad:3d} "
          f"p50={statistics.median(ms) if ms else 0:.0f}ms p95={sorted(ms)[int(len(ms)*.95)] if ms else 0:.0f}ms max={max(ms) if ms else 0:.0f}ms")
PY
cleanup; trap - EXIT
