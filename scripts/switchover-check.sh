#!/usr/bin/env bash
# 专项验证：关闭一个 infra 节点时，外部 nginx 会不会出现 502/503/504，切换是否干净
#
#   1) 稳态压测 20s
#   2) 停掉一个 infra 节点，继续压测 60s
#   3) 统计 nginx access log 状态码分布 + error_log 里的 5xx / "no live upstreams"
#   4) 把摘流时间线和状态码对齐，看切换瞬间有没有 5xx
#   5) 恢复节点
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROBE="$ROOT/scripts/ingress-probe.py"
DEAD_NODE=${DEAD_NODE:-ingress-lab-worker2}
OUT=${OUT:-/tmp/switchover}
RATE=${RATE:-20}
mkdir -p "$OUT"

echo "############ 502/503 专项验证：关闭 $DEAD_NODE ############"
"$ROOT/scripts/external-nginx.sh" >/dev/null 2>&1
echo "  upstream:"; grep 'server ' "$ROOT/nginx/upstream/nodeports.conf" | sed 's/^/    /'
docker exec nginx-external sh -c 'echo "    探测参数: path=$HC_PATH interval=$HC_INTERVAL fail=$HC_FAIL ok=$HC_OK"'
grep -o 'proxy_connect_timeout [^;]*' "$ROOT/nginx/conf/nginx.conf" | sed 's/^/    /'

echo; echo "----- 稳态 ${RATE}rps × 20s -----"
python3 "$PROBE" probe --duration 20 --rate "$RATE" --out "$OUT/base.csv" >/dev/null 2>&1
docker logs nginx-external > "$OUT/all.log" 2>&1

echo; echo "----- 停节点 + 继续压测 60s -----"
docker stop "$DEAD_NODE" >/dev/null; date '+  停止于 %H:%M:%S'
python3 "$PROBE" probe --duration 60 --rate "$RATE" --out "$OUT/out.csv" 2>&1 | tail -6
docker logs nginx-external > "$OUT/all.log" 2>&1
grep -E '^\[hc ' "$OUT/all.log" | sed 's/^/  /'

echo
echo "===== ① nginx access log 状态码分布（全量）====="
python3 "$PROBE" analyze --logfile "$OUT/all.log" 2>/dev/null | grep -E '状态码|重试|首次选中' -A4 | head -12

echo
echo "===== ② 有没有 5xx？====="
codes=$(awk '{for(i=1;i<=NF;i++) if($i ~ /^status=/){sub("status=","",$i); print $i}}' "$OUT/all.log" | sort | uniq -c)
echo "$codes" | sed 's/^/  access status: /'
bad=$(echo "$codes" | awk '$2 ~ /^5/ {s+=$1} END{print s+0}')
echo "  5xx 总数: $bad"

echo
echo "===== ③ error_log 里会产生 502 的那几类事件 ====="
for pat in 'no live upstreams' 'upstream timed out' 'server temporarily disabled' 'connect() failed' 'upstream prematurely closed'; do
  n=$(grep -c "$pat" "$OUT/all.log" 2>/dev/null || true)
  printf "  %-32s %s\n" "$pat" "$n"
done
echo "  其中会产生 5xx 的只有 'no live upstreams'（所有 upstream 都不可用时才出现）"

echo
echo "===== ④ 客户端侧状态码 ====="
python3 - <<PY
import csv, collections
rows=list(csv.DictReader(open("$OUT/out.csv")))
c=collections.Counter(r["status"] or "ERR" for r in rows)
print("  故障期请求:", len(rows), dict(c))
print("  5xx:", sum(v for k,v in c.items() if str(k).startswith("5")), " 传输错误:", sum(v for k,v in c.items() if k=="ERR"))
lat=[float(r["ms"]) for r in rows]
lat.sort()
print(f"  p50={lat[len(lat)//2]:.0f}ms p95={lat[int(len(lat)*.95)]:.0f}ms p99={lat[int(len(lat)*.99)]:.0f}ms max={lat[-1]:.0f}ms")
PY

echo
echo "===== ⑤ 切换瞬间（摘流+reload）前后有没有 5xx ====="
python3 - <<PY
import re, time
rows=[]
for line in open("$OUT/all.log", errors="replace"):
    m=re.search(r'\[(\d+/\w+/\d+:\d+:\d+:\d+) [^\]]*\].*?status=(\d{3})', line)
    if m: rows.append((time.mktime(time.strptime(m.group(1),'%d/%b/%Y:%H:%M:%S')), int(m.group(2))))
hc=[]
for line in open("$OUT/all.log", errors="replace"):
    m=re.match(r'\[hc (\d+):(\d+):(\d+)\] (REMOVE|ADD|upstream 变更.*)', line)
    if m: hc.append((f"{m.group(1)}:{m.group(2)}:{m.group(3)}", m.group(4)[:40]))
print("  摘流/加回事件:")
for t,e in hc: print(f"    {t}  {e}")
by5 = [t for t,s in rows if s>=500]
print(f"  5xx 请求时间点: {len(by5)}")
PY

echo
echo "----- 恢复 $DEAD_NODE -----"
docker start "$DEAD_NODE" >/dev/null; sleep 40
kubectl get node "$DEAD_NODE" --no-headers | awk '{print "  "$1" "$2}'
python3 "$PROBE" probe --duration 20 --rate "$RATE" --out "$OUT/back.csv" >/dev/null 2>&1
docker logs nginx-external --since 2m > "$OUT/back.log" 2>&1
grep -E '^\[hc ' "$OUT/back.log" | sed 's/^/  /'
echo "  恢复后 upstream:"; grep 'server ' "$ROOT/nginx/upstream/nodeports.conf" | sed 's/^/    /'
echo
echo "############ 结论 ############"
final_bad=$(awk '{for(i=1;i<=NF;i++) if($i ~ /^status=/){sub("status=","",$i); print $i}}' "$OUT/back.log" | grep -c '^5' || true)
echo "  恢复后 20s 内 5xx: $final_bad"
