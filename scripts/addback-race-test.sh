#!/usr/bin/env bash
# 场景 S3：节点「恢复」时，LB 什么时候把它加回来才算优雅？
#
# 摘流（把坏节点移出池子）和加回（把好节点放回池子）是两件事，加回的风险是反的：
# 加早了 = 流量打到一个「还在启动、没有本地 endpoint / 规则没 sync」的节点上。
# 本脚本用同一种故障注入（docker restart 一台 infra 节点）跑三遍，只换「加回信号」：
#
#   A) HC_MODE=l4  HC_OK=1 HC_INTERVAL=1   → TCP 三次握手通就加回（最快，也最早踩坑）
#   B) HC_MODE=l7  HC_OK=2 HC_INTERVAL=2   → /healthz 连续 2 次 200 才加回（默认推荐）
#   C) 同 B，但 HC_HOST=canary.demo.local  → 探测一条真实业务路由（canary），
#      即「这台节点真的能把一条业务请求跑通」才加回
#
# 每轮全程开环打流量，并独立采样该节点的 tcp / healthz / biz 三个信号，最后对齐：
#   加回时刻（[hc] ADD） vs 该节点真正能服务业务的时刻（biz=200）
#   加回过早 ⇒ 统计「加回之后、能服务之前」这段时间里 LB 送过去多少个请求、结果如何
#
# 用法: ./scripts/addback-race-test.sh [node]        产物在 /tmp/addback-race/<轮次>/
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NODE=${1:-ingress-lab-worker2}
OUT=${OUT:-/tmp/addback-race}
NODEPORT=${NODEPORT:-31000}
RATE=${RATE:-5}
WARM=${WARM:-15}          # restart 之前的采样秒数
COOL=${COOL:-120}        # restart 之后的采样秒数
CANARY_HOST=${CANARY_HOST:-canary.demo.local}
mkdir -p "$OUT"

ip_of() { kubectl get node "$NODE" -o 'jsonpath={.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null | awk '{print $1}'; }

# 一轮：$1=轮次名 $2=HC_MODE $3=HC_OK $4=HC_INTERVAL $5=HC_HOST(可空)
run_round() {
  local tag=$1 mode=$2 ok=$3 iv=$4 host=$5
  local d="$OUT/$tag"; mkdir -p "$d"
  echo
  echo "############ 轮次 $tag: mode=$mode ok=$ok interval=${iv}s host='${host:-<无业务Host>}' ############"

  HC_MODE=$mode HC_OK=$ok HC_INTERVAL=$iv HC_HOST=$host HC_FAIL=${HC_FAIL:-2} HC_TIMEOUT=${HC_TIMEOUT:-2} \
    "$ROOT/scripts/external-nginx.sh" > "$d/lb-setup.log" 2>&1
  sleep 5
  echo "  upstream 成员:"; grep 'server ' "$ROOT/nginx/upstream/nodeports.conf" | sed 's/^/    /'
  local IP; IP=$(ip_of); echo "  目标节点 $NODE = $IP"
  echo "$IP" > "$d/nodeip"

  # 独立采样：这个节点的三个信号（和 LB 的探测互相独立，用来判定「什么时候真的能服务」）
  docker exec nginx-external sh -c "
END=\$(( \$(date +%s) + $WARM + $COOL + 10 ))
while [ \$(date +%s) -lt \$END ]; do
  tcp=\$(nc -z -w 1 $IP $NODEPORT >/dev/null 2>&1 && echo TCP-OK || echo '  --  ')
  hz=\$(wget -S -O- -q -T 1 http://$IP:$NODEPORT/healthz 2>&1 >/dev/null | awk '/HTTP\//{print \$2; exit}')
  bz=\$(wget -S -O- -q -T 1 --header='Host: $CANARY_HOST' http://$IP:$NODEPORT/healthz 2>&1 >/dev/null | awk '/HTTP\//{print \$2; exit}')
  echo \"\$(date -u '+%H:%M:%S') \$tcp healthz=\${hz:-none} canary=\${bz:-none}\"
  sleep 1
done" > "$d/signals.txt" 2>&1 &
  local SIG=$!

  # 全程流量（经过 LB）
  python3 "$ROOT/scripts/ingress-probe.py" probe --method POST --duration $((WARM + COOL + 10)) \
      --rate "$RATE" --host demo.local --out "$d/P.csv" > "$d/load.log" 2>&1 &
  local LOAD=$!

  sleep "$WARM"
  date -u '+%H:%M:%S' > "$d/restart.at"
  echo ">>> t=+${WARM}s  docker restart $NODE  ($(cat "$d/restart.at") UTC)"
  docker restart "$NODE" > "$d/restart.log" 2>&1
  wait $SIG
  sleep 3
  kill $LOAD 2>/dev/null; wait $LOAD 2>/dev/null
  docker logs nginx-external > "$d/nginx.log" 2>&1
  grep -E '^\[hc ' "$d/nginx.log" > "$d/hc.log" || true
  echo "  healthcheck 事件:"; sed 's/^/    /' "$d/hc.log"

  # ---- 对齐：加回时刻 vs 能服务时刻 vs 这段时间里送过去的请求 ----
  python3 - "$d" "$NODEPORT" <<'PY'
import csv, re, sys, os, json, datetime
d, port = sys.argv[1], sys.argv[2]
def hhmmss(s): h,m,sec=s.split(':'); return int(h)*3600+int(m)*60+int(sec)
restart = hhmmss(open(os.path.join(d,'restart.at')).read().strip())

# 1) 信号时间线：restart 之后第一次 TCP-OK / healthz=200 / canary=200
sig = {'tcp':None,'healthz':None,'canary':None}
for line in open(os.path.join(d,'signals.txt')):
    p=line.split()
    if len(p)<4: continue
    t=hhmmss(p[0]); rel=t-restart
    if rel<0: continue
    if p[1]=='TCP-OK' and sig['tcp'] is None: sig['tcp']=rel
    for k,pat in (('healthz','healthz=200'),('canary','canary=200')):
        if pat in line and sig[k] is None: sig[k]=rel
print("  相对 restart 的时刻:")
for k in ('tcp','healthz','canary'):
    print(f"    首次 {k:<8} = " + (f"+{sig[k]}s" if sig[k] is not None else "未恢复（采样窗口内）"))

# 2) LB 什么时候把它加回来（[hc] ADD / REMOVE），以及 reload 次数
hc_add=[]; hc_rm=[]; reload=0
for line in open(os.path.join(d,'hc.log')):
    m=re.match(r'\[hc (\d\d:\d\d:\d\d)\] (ADD|REMOVE)\s+(\S+)', line)
    if m:
        rel=hhmmss(m.group(1))-restart
        (hc_add if m.group(2)=='ADD' else hc_rm).append((rel,m.group(3)))
    if 'reload nginx' in line: reload+=1
print(f"  LB 摘流(REMOVE): " + (", ".join(f"+{r}s {ip}" for r,ip in hc_rm) or "无"))
print(f"  LB 加回(ADD)   : " + (", ".join(f"+{r}s {ip}" for r,ip in hc_add) or "无"))
print(f"  reload 次数    : {reload}")

# 3) 解析 access log：哪些请求被送到目标节点，结果如何
LOG=re.compile(r'\S+ - (?P<ups>.*?) \[(?P<t>[^\]]+)\] "(?P<m>\S+) (?P<path>\S+)[^"]*" host="[^"]*" -> ingress_host="[^"]*" status=(?P<st>\d+) rt=(?P<rt>[\d.]+)')
IP=open(os.path.join(d,'nodeip')).read().strip()
hit=[]; total=0; bad=0
for line in open(os.path.join(d,'nginx.log')):
    m=LOG.search(line)
    if not m: continue
    total+=1
    ts=datetime.datetime.strptime(m.group('t').split()[0],'%d/%b/%Y:%H:%M:%S').timetuple()
    rel=int(ts.tm_hour)*3600+int(ts.tm_min)*60+int(ts.tm_sec)-restart
    ups=[u.strip() for u in m.group('ups').split(',')]
    st=int(m.group('st')); rt=float(m.group('rt'))*1000
    if st!=200: bad+=1
    if any(u.startswith(IP+':') for u in ups):
        hit.append((rel,ups,st,rt))
first_ok=None
for rel,ups,st,rt in hit:
    if st==200 and first_ok is None: first_ok=rel
print(f"  全程: 请求 {total} 个，非 200 {bad} 个；被送到目标节点的 {len(hit)} 个")
# 两个不同的风险窗口，分开统计：
#   W1 = restart → LB 摘流完成（摘得慢的代价）
#   W2 = LB 加回 → 该节点真能服务业务（加得早的代价）
rm_at = min([r for r,_ in hc_rm]) if hc_rm else None
add_at = min(adds) if (adds:= [r for r,_ in hc_add]) else None
ready = sig['canary'] if sig['canary'] is not None else 10**9
w1 = [h for h in hit if h[0] >= 0 and (rm_at is None or h[0] <= rm_at)]
w2 = [h for h in hit if add_at is not None and h[0] >= add_at and h[0] < ready]
print(f"  W1 摘流前（restart→REMOVE）送到该节点: {len(w1)} 个，其中非 200 {sum(1 for h in w1 if h[2]!=200)} 个")
print(f"  W2 加回过早（ADD→能服务）送到该节点: {len(w2)} 个，其中非 200 {sum(1 for h in w2 if h[2]!=200)} 个")
prem=w1+w2
print(f"  在「该节点能服务业务」之前就被送到它的请求: {len(prem)}")
for h in sorted(prem)[:8]:
    print(f"    +{h[0]:>4}s  {' -> '.join(h[1]):<40} status={h[2]} rt={h[3]:.0f}ms")
print(f"  该节点第一次成功服务(经 LB 的 200): " + (f"+{first_ok}s" if first_ok is not None else "-"))
PY
}

# canary 路由必须先存在
kubectl apply -f "$ROOT/manifests/canary-ingress.yaml" >/dev/null 2>&1 && echo "canary 路由已应用: http://$CANARY_HOST:$NODEPORT/healthz"

run_round A-l4-fast   l4 1 1 ""
run_round B-l7-rec    l7 2 2 ""
run_round C-l7-canary l7 2 2 "$CANARY_HOST"

echo
echo "############ 三轮对照 ############"
python3 - "$OUT" <<'PY'
import os,sys,re,csv,datetime
root=sys.argv[1]
print(f"{'轮次':<14}{'首次TCP':>9}{'首次healthz':>13}{'首次canary':>12}{'LB加回':>9}{'过早导流请求':>14}{'其中非200':>11}{'reload':>8}")
for tag in sorted(os.listdir(root)):
    d=os.path.join(root,tag)
    if not os.path.isdir(d): continue
    def hh(s): h,m,sec=s.split(':'); return int(h)*3600+int(m)*60+int(sec)
    try: restart=hh(open(f"{d}/restart.at").read().strip())
    except Exception: continue
    sig={'tcp':None,'healthz':None,'canary':None}
    for line in open(f"{d}/signals.txt"):
        p=line.split()
        if len(p)<4: continue
        rel=hh(p[0])-restart
        if rel<0: continue
        if p[1]=='TCP-OK' and sig['tcp'] is None: sig['tcp']=rel
        if 'healthz=200' in line and sig['healthz'] is None: sig['healthz']=rel
        if 'canary=200' in line and sig['canary'] is None: sig['canary']=rel
    add=[]; reload=0
    for line in open(f"{d}/hc.log"):
        m=re.match(r'\[hc (\d\d:\d\d:\d\d)\] ADD',line)
        if m: add.append(hh(m.group(1))-restart)
        if 'reload nginx' in line: reload+=1
    IP=open(f"{d}/nodeip").read().strip()
    LOG=re.compile(r'\S+ - (?P<ups>.*?) \[(?P<t>[^\]]+)\] .*? status=(?P<st>\d+)')
    prem=0; prembad=0
    for line in open(f"{d}/nginx.log"):
        m=LOG.search(line)
        if not m: continue
        ts=datetime.datetime.strptime(m.group('t').split()[0],'%d/%b/%Y:%H:%M:%S')
        rel=ts.hour*3600+ts.minute*60+ts.second-restart
        ups=[u.strip() for u in m.group('ups').split(',')]
        if rel>=0 and any(u.startswith(IP+':') for u in ups):
            ready=sig['canary'] if sig['canary'] is not None else 10**9
            if rel<ready:
                prem+=1
                if m.group('st')!='200': prembad+=1
    f=lambda v: f"+{v}s" if v is not None else "-"
    print(f"{tag:<14}{f(sig['tcp']):>9}{f(sig['healthz']):>13}{f(sig['canary']):>12}"
          f"{(f(min(add)) if add else '未加回'):>9}{prem:>14}{prembad:>11}{reload:>8}")
PY
echo "  原始数据: $OUT/<轮次>/{signals.txt,hc.log,nginx.log,P.csv}"
