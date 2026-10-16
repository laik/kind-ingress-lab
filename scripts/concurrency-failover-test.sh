#!/usr/bin/env bash
# 闭环并发故障演练：**一条不间断的并发流量**（N 个常驻 client、持久连接、始终有请求在飞），
# 中途关掉一个 infra-node，再恢复。
#
#   t=0            起压（concurrency=N，持续 TOTAL 秒）
#   t=PHASE_A      docker stop <infra>
#   t=PHASE_A+PHASE_B  docker start <infra>
#   t=TOTAL        停压并按时间窗分析
#
# 和 failover-test.sh（开环 5rps、每请求新建连接）的区别：
#   - 并发度恒定，任何时刻都有 N 个请求在打 ⇒ 关节点那一刻真的有请求"在飞"；
#   - 连接复用 ⇒ 会命中 LB→节点 的 upstream keepalive 池（半开连接是最疼的部分）；
#   - --slow 让后端睡 X 秒，把在飞时间放大到可观测。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROBE="$ROOT/scripts/concurrency-probe.py"
DEAD_NODE=${DEAD_NODE:-ingress-lab-worker2}
CONC=${CONC:-5}
CONNS=${CONNS:-1}                # 每个 client 持多少条持久连接（总连接数 = CONC × CONNS）
RETRY=${RETRY:-0}                  # 1 = 连接级失败时客户端重试一次（量化“重试能不能抹平 reload”）
SLOW=${SLOW:-1.0}                 # 后端延迟(s)，制造真正的在飞请求
THINK=${THINK:-0.05}              # 每个 client 两次请求之间的间隔(s)
STAGGER=${STAGGER:-}              # 错开起跑；留空则自动 = SLOW/CONC（避免整批同步落到同一个 upstream）
METHOD=${METHOD:-GET}
KILL_MODE=${KILL_MODE:-stop}     # stop=优雅停；kill=硬 crash；drain=kubectl 维护；restart=重启；graceful=先 LB 摘流再重启；reboot=节点侧 REJECT+等连接排空+drain+重启（不依赖 LB）；maint=LB 标 down+等排空+节点侧兜底+drain+重启
PRE_DRAIN=${PRE_DRAIN:-15}       # graceful 模式下，摘流后等在飞请求排空的秒数（必须 > 业务最长请求时间）
WAIT_CONN=${WAIT_CONN:-45}       # reboot 模式下，等 NodePort 连接数降到 0 的上限秒数
PHASE_A=${PHASE_A:-20}; PHASE_B=${PHASE_B:-60}; PHASE_C=${PHASE_C:-30}
OUT=${OUT:-/tmp/conc-$METHOD-$KILL_MODE}
TOTAL=$((PHASE_A + PHASE_B + PHASE_C + 10))
mkdir -p "$OUT"

dist() { kubectl -n ingress-nginx get pods -l app.kubernetes.io/component=controller \
           -o 'jsonpath={range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort | uniq -c | sed 's/^/    /'; }

echo "############ 闭环并发演练（持续 ${TOTAL}s）: 在 t=${PHASE_A}s ${KILL_MODE} $DEAD_NODE ############"
if [ "${LB_SETUP:-1}" = 1 ]; then "$ROOT/scripts/external-nginx.sh" >/dev/null 2>&1; else echo "  (LB_SETUP=0：不动 LB，用当前配置跑)"; fi
echo "  upstream 成员:"; grep 'server ' "$ROOT/nginx/upstream/nodeports.conf" | sed 's/^/  /'
echo "  ingress pod 分布:"; dist
echo "  慢后端(制造在飞请求):"; kubectl -n demo get pods -l app=slow \
  -o 'jsonpath={range .items[*]}{.metadata.name}{"  @"}{.spec.nodeName}{"\n"}{end}' | sed 's/^/    /'

: > "$OUT/events.txt"
[ -n "$STAGGER" ] || STAGGER=$(python3 -c "print(round(${SLOW}/${CONC},3))")
python3 "$PROBE" run --concurrency "$CONC" --connections "$CONNS" --duration "$TOTAL" --slow "$SLOW" --think "$THINK" \
  --stagger "$STAGGER" ${RETRY:+$([ "$RETRY" = 1 ] && echo --retry-once)} \
  --method "$METHOD" --host demo.local --path /slow --out "$OUT/all-$METHOD.csv" --mark "全程" \
  > "$OUT/load.log" 2>&1 &
LOAD=$!
echo "  压测已起（pid ${LOAD}），concurrency=${CONC} connections/client=${CONNS}（总连接 $((CONC*CONNS))） method=${METHOD} slow=${SLOW}s think=${THINK}s stagger=${STAGGER}s"

sleep "$PHASE_A"
DIP=$(kubectl get node "$DEAD_NODE" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' | awk '{print $1}')
date -u '+stop %s %Y-%m-%dT%H:%M:%SZ' >> "$OUT/events.txt"
echo; echo ">>> t=+${PHASE_A}s  $KILL_MODE $DEAD_NODE ($DIP)"
case "$KILL_MODE" in
  kill) docker kill "$DEAD_NODE" >/dev/null ;;
  restart) docker restart "$DEAD_NODE" >/dev/null ;;
  graceful) "$ROOT/scripts/graceful-restart-infra.sh" "$DEAD_NODE" "$PRE_DRAIN" >"$OUT/graceful.log" 2>&1 & ;;
  reboot)   PRE_DRAIN_LB=0 "$ROOT/scripts/graceful-reboot-infra.sh" "$DEAD_NODE" "$WAIT_CONN" >"$OUT/reboot.log" 2>&1 & ;;
  maint)    "$ROOT/scripts/maintenance-restart.sh" "$DEAD_NODE" "$WAIT_CONN" >"$OUT/maint.log" 2>&1 & ;;
  drain) kubectl cordon "$DEAD_NODE" >/dev/null 2>&1
         kubectl drain "$DEAD_NODE" --ignore-daemonsets --delete-emptydir-data --force \
                  --grace-period=60 --timeout=180s >"$OUT/drain.log" 2>&1 ;;
  *)     docker stop "$DEAD_NODE" >/dev/null ;;
esac
( for i in $(seq 1 $((PHASE_B/10))); do sleep 10
    printf "  t=+%3ds node=%-7s upstream成员=%s\n" $((PHASE_A+i*10)) \
      "$(kubectl get node $DEAD_NODE -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo '?')" \
      "$(grep -c 'server 1' "$ROOT/nginx/upstream/nodeports.conf")"
  done ) & WATCHER=$!
sleep "$PHASE_B"
kill $WATCHER 2>/dev/null; wait $WATCHER 2>/dev/null
date -u '+start %s %Y-%m-%dT%H:%M:%SZ' >> "$OUT/events.txt"
echo; echo ">>> t=+$((PHASE_A+PHASE_B))s  恢复 $DEAD_NODE"
case "$KILL_MODE" in
  drain)     kubectl uncordon "$DEAD_NODE" >/dev/null 2>&1 ;;
  restart|graceful|reboot|maint) : ;;   # 已经把节点带回来了
  *)         docker start "$DEAD_NODE" >/dev/null ;;
esac
sleep "$PHASE_C"
wait $LOAD
docker logs nginx-external --since 10m > "$OUT/nginx.log" 2>&1

echo; echo "===== 压测输出 ====="; cat "$OUT/load.log"
echo; echo "===== healthcheck 时间线 ====="
docker logs nginx-external --since 10m 2>&1 | grep -E '^\[hc ' | tail -8 | sed 's/^/  /'

echo; echo "===== 按时间窗分析（客户端视角）====="
python3 - "$OUT/all-$METHOD.csv" "$OUT/events.txt" "$OUT/nginx.log" <<'PY'
import csv, sys, collections, statistics, datetime
rows = list(csv.DictReader(open(sys.argv[1])))
ev = []
for line in open(sys.argv[2]):
    p = line.split()
    if len(p) >= 2:
        ev.append((p[0], int(p[1])))
t0 = min(float(r["ts"]) for r in rows)
bounds = [("基线", t0)] + [(k, ts) for k, ts in ev] + [("结束", float("inf"))]
def win(a, b):
    return [r for r in rows if a <= float(r["ts"]) < b]
def pct(v, p):
    if not v: return 0
    s = sorted(v); return s[min(len(s)-1, max(0, int(round(p/100.0*(len(s)-1)))))]
def ts_str(x):
    return datetime.datetime.fromtimestamp(x, datetime.timezone.utc).strftime("%H:%M:%S")
print(f"  总请求 {len(rows)}，起压 {ts_str(t0)} UTC")
print(f"  {'窗口':<10}{'请求':>6}{'200':>6}{'非200':>7}{'连接错':>7}{'在飞被切':>9}{'p50':>7}{'p95':>8}{'p99':>8}{'max':>8}")
for i in range(len(bounds)-1):
    name, a = bounds[i]; b = bounds[i+1][1]
    rs = win(a, b)
    if not rs: continue
    ms = [float(r["ms"]) for r in rs]
    bad = sum(1 for r in rs if r["status"] != "200")
    errs = sum(1 for r in rs if r["err"])
    print(f"  {name:<10}{len(rs):>6}{sum(1 for r in rs if r['status']=='200'):>6}{bad:>7}{errs:>7}"
          f"{'-':>9}{pct(ms,50):>7.0f}{pct(ms,95):>8.0f}{pct(ms,99):>8.0f}{max(ms):>8.0f}")

# 关节点瞬间在飞的请求
stop = [ts for k, ts in ev if k == "stop"][0]
inf = [r for r in rows if float(r["ts"]) <= stop <= float(r["ts"]) + float(r["ms"])/1000]
print(f"\n  关节点瞬间（{ts_str(stop)} UTC）在飞的请求: {len(inf)}")
for r in sorted(inf, key=lambda x: -float(x["ms"]))[:10]:
    print(f"    {r['id']:<12} 起 {ts_str(float(r['ts']))} "
          f"耗时={float(r['ms']):8.0f}ms status={r['status'] or r['err'][:30]}")
slow = [r for r in rows if float(r["ms"]) > 3000]
print(f"  耗时 >3s 的请求: {len(slow)}" + ("  ← 这些是被切到的在飞/半开连接" if slow else ""))
for r in sorted(slow, key=lambda x: -float(x["ms"]))[:10]:
    print(f"    {r['id']:<12} {float(r['ms']):8.0f}ms status={r['status'] or r['err'][:30]}")
bad = [r for r in rows if r["status"] != "200" or r["err"]]
print(f"  非 200 / 连接错误的请求: {len(bad)}")
for r in bad[:10]:
    print(f"    {r['id']:<12} {ts_str(float(r['ts']))} {float(r['ms']):8.0f}ms "
          f"status={r['status'] or r['err'][:40]}")
PY
echo; echo "===== 慢请求经过了哪个 upstream（客户端 vs nginx 日志）====="
python3 "$ROOT/scripts/concurrency-probe.py" join --csvfile "$OUT/all-$METHOD.csv" --logfile "$OUT/nginx.log"

echo; echo "===== 恢复后状态 ====="
echo "  upstream 成员:"; grep 'server ' "$ROOT/nginx/upstream/nodeports.conf" | sed 's/^/    /'
echo "  ingress pod 分布:"; dist
