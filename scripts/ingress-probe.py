#!/usr/bin/env python3
"""ingress-lab 观测工具

子命令:
  probe    持续打请求到外部 nginx，记录每个请求的状态码/耗时，输出 CSV
  analyze  解析 nginx access log，统计 upstream 命中、重试、状态码、耗时分布
  join     把 probe 的 CSV 和 nginx log 按请求 id 关联，定位"慢请求经过了哪个 upstream"

每个请求带唯一标记 ?probe=<id>，因此客户端观测和 nginx 侧日志可以精确对齐。
nginx 的 $upstream_addr 在发生重试时是逗号分隔的，例如 "172.18.0.4:31000, 172.18.0.2:31000"
—— 这就是判断"有没有不正常的情况"的关键信号。
"""
import argparse
import collections
import csv
import http.client
import os
import re
import statistics
import subprocess
import sys
import threading
import time

DEFAULT_URL = "http://127.0.0.1:8080/"
DEFAULT_HOST = "demo.local"
CONTAINER = os.environ.get("NGINX_CONTAINER", "nginx-external")


# ---------------------------------------------------------------- utilities
def parse_url(url):
    m = re.match(r"https?://([^/:]+)(?::(\d+))?(/.*)?$", url)
    if not m:
        sys.exit(f"bad url: {url}")
    host, port, path = m.group(1), m.group(2), m.group(3) or "/"
    return host, int(port or 80), path


def pct(vals, p):
    if not vals:
        return 0.0
    s = sorted(vals)
    k = min(len(s) - 1, max(0, int(round((p / 100.0) * (len(s) - 1)))))
    return s[k]


def show_dist(name, vals):
    if not vals:
        print(f"  {name}: 无数据")
        return
    print(f"  {name}: n={len(vals)} min={min(vals):.0f}ms p50={pct(vals,50):.0f} "
          f"p95={pct(vals,95):.0f} p99={pct(vals,99):.0f} max={max(vals):.0f}ms")


# --------------------------------------------------------------------- probe
def cmd_probe(a):
    host, port, path = parse_url(a.url)
    deadline = time.time() + a.duration
    results = []
    lock = threading.Lock()
    counter = {"n": 0}
    stop = threading.Event()

    def one():
        with lock:
            counter["n"] += 1
            pid = counter["n"]
        rid = f"p{pid}"
        q = f"{path}{'&' if '?' in path else '?'}probe={rid}"
        t0 = time.time()
        status, err = 0, ""
        try:
            conn = http.client.HTTPConnection(host, port, timeout=a.timeout)
            hdrs = {"Host": a.host, "User-Agent": "ingress-probe/1.0"}
            if a.method == "POST":
                # 非幂等请求：nginx 默认（proxy_next_upstream 不带 non_idempotent）不会重试
                hdrs["Content-Type"] = "application/x-www-form-urlencoded"
                conn.request("POST", q, body=b"probe=" + rid.encode(), headers=hdrs)
            else:
                conn.request("GET", q, headers=hdrs)
            r = conn.getresponse()
            r.read()
            status = r.status
            conn.close()
        except Exception as e:
            err = type(e).__name__ + ": " + str(e)[:60]
        ms = (time.time() - t0) * 1000
        with lock:
            results.append({"id": rid, "ts": t0, "status": status, "ms": ms, "err": err})

    threads = []
    interval = 1.0 / max(1, a.rate)
    t_start = time.time()
    while time.time() < deadline:
        t = threading.Thread(target=one, daemon=True)
        t.start()
        threads.append(t)
        # 控制发送速率
        sleep_for = interval - (time.time() - t_start) % interval
        time.sleep(max(0.005, sleep_for))
        # 每 10s 打一行窗口统计
        if int(time.time() - t_start) % 10 == 0 and time.time() - t_start > 1:
            with lock:
                recent = [r for r in results if r["ts"] > time.time() - 10]
            if recent:
                ok = sum(1 for r in recent if r["status"] == 200)
                slow = sum(1 for r in recent if r["ms"] > 1000)
                print(f"  t={time.time()-t_start:6.1f}s  req={len(recent):3d} ok={ok:3d} "
                      f"slow>1s={slow:2d} p95={pct([r['ms'] for r in recent],95):6.0f}ms", flush=True)
    for t in threads:
        t.join()

    with open(a.out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["id", "ts", "status", "ms", "err"])
        w.writeheader()
        w.writerows(results)

    print(f"\n=== probe 汇总 ({a.duration}s, 目标 {a.url}, Host={a.host}) ===")
    print(f"  总请求: {len(results)}  -> CSV: {a.out}")
    by_status = collections.Counter(r["status"] for r in results)
    print("  状态码: " + ", ".join(f"{s}={c}" for s, c in sorted(by_status.items(), key=lambda x: -x[1])))
    errs = [r for r in results if r["err"]]
    print(f"  传输错误: {len(errs)}")
    for e in collections.Counter(r["err"] for r in errs).most_common(5):
        print(f"    {e[1]}x  {e[0]}")
    show_dist("耗时(全部)", [r["ms"] for r in results])
    slow = [r for r in results if r["ms"] > 1000]
    print(f"  慢请求(>1s): {len(slow)}  ({100.0*len(slow)/max(1,len(results)):.1f}%)")
    if slow:
        print("    最慢的 5 个: " + ", ".join(f"{r['id']}={r['ms']:.0f}ms/{r['status'] or r['err']}"
                                              for r in sorted(slow, key=lambda x: -x["ms"])[:5]))


# ------------------------------------------------------------------- analyze
LOG_RE = re.compile(
    r'(?P<client>\S+) - (?P<upstreams>.*?) \[(?P<time>[^\]]+)\] "(?P<method>\S+) (?P<path>\S+) [^"]*" '
    r'host="(?P<host>[^"]*)" -> ingress_host="(?P<ih>[^"]*)" status=(?P<status>\d+) '
    r'rt=(?P<rt>[\d.]+) urt=(?P<urt>.*)$'
)


def read_nginx_logs(since, logfile=None):
    if logfile:
        with open(logfile, errors="replace") as f:
            return f.read()
    out = subprocess.run(["docker", "logs", CONTAINER, "--since", since],
                         capture_output=True, text=True)
    return out.stdout + out.stderr


def parse_logs(text):
    rows = []
    for line in text.splitlines():
        m = LOG_RE.search(line)
        if not m:
            continue
        d = m.groupdict()
        ups = [u.strip() for u in d["upstreams"].split(",")]
        d["ups"] = ups
        d["retries"] = len(ups) - 1
        d["status"] = int(d["status"])
        d["rt"] = float(d["rt"]) * 1000
        d["probe_id"] = ""
        q = re.search(r"[?&]probe=([\w-]+)", d["path"])
        if q:
            d["probe_id"] = q.group(1)
        rows.append(d)
    return rows


def cmd_analyze(a):
    rows = parse_logs(read_nginx_logs(a.since, a.logfile))
    src = a.logfile or f"container={CONTAINER}, since={a.since}"
    print(f"=== nginx access log 分析 ({src}, 共 {len(rows)} 条) ===")
    if not rows:
        print("  没有匹配到日志（确认 log_format main 已启用）")
        return
    print("  状态码: " + ", ".join(f"{s}={c}" for s, c in
                                  collections.Counter(r["status"] for r in rows).most_common()))
    first = collections.Counter(r["ups"][0] for r in rows)
    print("  首次选中的 upstream:")
    for u, c in first.most_common():
        print(f"    {u:<24} {c}")
    retried = [r for r in rows if r["retries"] > 0]
    print(f"  发生重试的请求: {len(retried)} ({100.0*len(retried)/max(1,len(rows)):.1f}%)")
    chain = collections.Counter(", ".join(r["ups"]) for r in retried)
    for c, n in chain.most_common(6):
        print(f"    {n:3d}x  {c}")
    # 重试的时间分布：能看出 nginx 每隔 fail_timeout 就重新探一次死节点
    if retried:
        def ts(r):
            return time.mktime(time.strptime(r["time"].split()[0], "%d/%b/%Y:%H:%M:%S"))
        times = sorted(ts(r) for r in retried)
        buckets = collections.Counter(int(t // 10) * 10 for t in times)
        t0 = min(buckets)
        print("  重试时间线（10s 粒度，相对第一个重试）:")
        for b in sorted(buckets):
            print(f"    +{b-t0:4d}s  {'#' * buckets[b]} {buckets[b]}")
        if len(times) > 1:
            gaps = [round(b - a) for a, b in zip(times, times[1:]) if 0 < b - a < 60]
            if gaps:
                print(f"  重试间隔: 中位数 {int(statistics.median(gaps))}s / 最大 {max(gaps)}s"
                  f"  ← 对应 upstream 配置里的 fail_timeout=15s（nginx 开源版只有被动健康检查）")
    show_dist("请求耗时", [r["rt"] for r in rows])
    slow = [r for r in rows if r["rt"] > 1000]
    if slow:
        print(f"  慢请求(>1s) 的首个 upstream 分布: "
              + ", ".join(f"{u}={c}" for u, c in collections.Counter(r["ups"][0] for r in slow).most_common()))


def cmd_join(a):
    rows = parse_logs(read_nginx_logs(a.since, a.logfile))
    by_id = {r["probe_id"]: r for r in rows if r["probe_id"]}
    with open(a.csvfile) as f:
        client = list(csv.DictReader(f))
    print(f"=== 客户端观测 vs nginx 日志关联 (client={len(client)}, nginx={len(by_id)}) ===")
    lat_by_up = collections.defaultdict(list)
    mism = []
    for c in client:
        r = by_id.get(c["id"])
        if not r:
            mism.append(c["id"])
            continue
        lat_by_up[", ".join(r["ups"])].append(float(c["ms"]))
    print("  客户端看到的耗时，按 nginx upstream 链路分组:")
    for chain, vals in sorted(lat_by_up.items(), key=lambda x: -statistics.median(x[1])):
        print(f"    {chain:<48} n={len(vals):4d} p50={pct(vals,50):6.0f}ms p95={pct(vals,95):6.0f}ms max={max(vals):6.0f}ms")
    if mism:
        print(f"  客户端有但 nginx 日志里没有的请求(说明连接根本没建立): {len(mism)} -> {mism[:8]}")


def main():
    p = argparse.ArgumentParser(description="ingress-lab 观测工具")
    sub = p.add_subparsers(dest="cmd", required=True)

    pp = sub.add_parser("probe")
    pp.add_argument("--url", default=DEFAULT_URL)
    pp.add_argument("--host", default=DEFAULT_HOST)
    pp.add_argument("--duration", type=int, default=60)
    pp.add_argument("--rate", type=int, default=5, help="每秒请求数")
    pp.add_argument("--timeout", type=float, default=10.0)
    pp.add_argument("--method", choices=["GET", "POST"], default="GET",
                    help="POST 用于验证非幂等请求在 upstream 出错时会不会真的掉")
    pp.add_argument("--out", default="/tmp/probe.csv")
    pp.set_defaults(func=cmd_probe)

    pa = sub.add_parser("analyze")
    pa.add_argument("--since", default="5m")
    pa.add_argument("--logfile", help="从快照文件读，而不是 docker logs（容器被重建时用这个）")
    pa.set_defaults(func=cmd_analyze)

    pj = sub.add_parser("join")
    pj.add_argument("--csvfile", default="/tmp/probe.csv")
    pj.add_argument("--since", default="10m")
    pj.add_argument("--logfile", help="从快照文件读，而不是 docker logs")
    pj.set_defaults(func=cmd_join)

    a = p.parse_args()
    a.func(a)


if __name__ == "__main__":
    main()
