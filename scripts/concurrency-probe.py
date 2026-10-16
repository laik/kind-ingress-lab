#!/usr/bin/env python3
"""闭环并发压测：N 个常驻 client，各自持有持久连接（keep-alive）持续打请求。

和 ingress-probe.py（开环、固定 rps、每请求新建连接）的区别：
  - 并发度是确定的（--concurrency 3~5），任何时刻都有 N 个 client 在打；
  - 连接是复用的 ⇒ 会命中 LB 到 infra-node 的 upstream keepalive 连接池
    （节点被关掉时，池里那些"半开"的连接才是真实生产里最疼的部分）；
  - --slow 让后端多睡一会儿 ⇒ 关节点那一刻真的有 N 个请求在飞。

用法:
  ./scripts/concurrency-probe.py run --concurrency 5 --duration 60 --out /tmp/conc/B.csv
  ./scripts/concurrency-probe.py run --method POST --slow 1.0 ...
"""
import argparse
import csv
import http.client
import re
import statistics
import sys
import threading
import time

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from importlib import import_module
probe = import_module("ingress-probe")   # 复用 pct() / parse_logs()


def pct(vals, p):
    return probe.pct(vals, p)


def worker(wid, a, results, lock, stop, seq):
    m = re.match(r"https?://([^/:]+)(?::(\d+))?", a.url)
    host, port = m.group(1), int(m.group(2) or 80)
    npool = max(1, int(getattr(a, "connections", 1) or 1))   # 每个 client 的持久连接数
    pool = [None] * npool
    n = 0

    def new_conn(i):
        c = http.client.HTTPConnection(host, port, timeout=a.timeout)
        c.connect()
        pool[i] = c

    def attempt(i, q, hdrs, body):        # 返回 (status, err)；err 非空 = 连接级失败
        if pool[i] is None:
            try:
                new_conn(i)
            except Exception as e:
                return 0, "ConnectFailed: " + type(e).__name__
        try:
            pool[i].request(a.method, q, body=body, headers=hdrs)
            r = pool[i].getresponse()
            r.read()
            if (r.getheader("connection") or "").lower() == "close":
                try:
                    pool[i].close()
                except Exception:
                    pass
                pool[i] = None
            return r.status, ""
        except Exception as e:
            try:
                pool[i].close()
            except Exception:
                pass
            pool[i] = None               # 连接不可信，下次重建
            return 0, type(e).__name__ + ": " + str(e)[:70]

    # 错开起跑时间：否则 N 个 client 的周期完全同步，每一批请求会被 least_conn（per-worker）
    # 整体发到同一个 upstream —— 关节点时“要么全中要么全不中”，样本失真。
    if a.stagger:
        stop.wait(wid * a.stagger)
    if npool > 1:                        # 预建连接池：否则 1s/请求要 20 多秒才建满，测的不是稳态
        for i in range(npool):
            try:
                new_conn(i)
            except Exception:
                pass

    while not stop.is_set():
        with lock:
            seq["n"] += 1
            rid = f"w{wid}-{seq['n']}"
        n += 1
        q = f"{a.path}{'&' if '?' in a.path else '?'}probe={rid}"
        hdrs = {"Host": a.host, "User-Agent": "concurrency-probe/1.0"}
        body = None
        if a.method == "POST":
            hdrs["Content-Type"] = "application/x-www-form-urlencoded"
            body = "probe=" + rid
        t0 = time.monotonic()
        wall = time.time()
        retries = 2 if getattr(a, "retry_once", False) else 1
        attempts, status, err = 0, 0, ""
        while attempts < retries:
            attempts += 1
            status, err = attempt(n % npool, q, hdrs, body)
            if err == "":
                break
            if attempts < retries:
                stop.wait(0.05)          # 只重试“没拿到任何响应”的连接级失败，并用新连接
        ms = (time.monotonic() - t0) * 1000
        with lock:
            results.append({"id": rid, "worker": wid, "ts": wall, "status": status,
                            "ms": ms, "err": err, "attempts": attempts})
        if a.think:
            stop.wait(a.think)
    for c in pool:
        if c:
            try:
                c.close()
            except Exception:
                pass


def cmd_run(a):
    results, lock, stop, seq = [], threading.Lock(), threading.Event(), {"n": 0}
    threads = [threading.Thread(target=worker, args=(i, a, results, lock, stop, seq), daemon=True)
               for i in range(a.concurrency)]
    t_start = time.time()
    for t in threads:
        t.start()
    if a.mark:
        print(f"  [{a.mark}] 起压: {a.concurrency} 个常驻 client，{a.method}，"
              f"think={a.think}s slow={a.slow}s", flush=True)
    deadline = t_start + a.duration
    while time.time() < deadline:
        time.sleep(5)
        with lock:
            recent = [r for r in results if r["ts"] > time.time() - 5]
        if recent:
            ok = sum(1 for r in recent if r["status"] == 200)
            bad = [r for r in recent if r["status"] != 200 or r["err"]]
            slow = sum(1 for r in recent if r["ms"] > 1000)
            print(f"  t={time.time()-t_start:6.1f}s conc={a.concurrency} req={len(recent):4d} "
                  f"ok={ok:4d} 非200/失败={len(bad):2d} >1s={slow:3d} "
                  f"p50={pct([r['ms'] for r in recent],50):5.0f} max={max(r['ms'] for r in recent):6.0f}ms",
                  flush=True)
    stop.set()
    for t in threads:
        t.join()

    with open(a.out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["id", "worker", "ts", "status", "ms", "err", "attempts"])
        w.writeheader()
        w.writerows(results)

    import collections
    print(f"\n=== 闭环并发汇总 ({a.duration}s, {a.concurrency} 个常驻 client, {a.method}) -> {a.out} ===")
    print(f"  总请求: {len(results)}")
    st = collections.Counter(r["status"] or "ERR" for r in results)
    print("  状态码: " + ", ".join(f"{s}={c}" for s, c in st.most_common()))
    errs = [r for r in results if r["err"]]
    print(f"  传输错误(连接被断/超时): {len(errs)}")
    for e, c in collections.Counter(r["err"] for r in errs).most_common(5):
        print(f"    {c}x  {e}")
    ms = [r["ms"] for r in results]
    print(f"  耗时: n={len(ms)} p50={pct(ms,50):.0f} p95={pct(ms,95):.0f} "
          f"p99={pct(ms,99):.0f} max={max(ms):.0f}ms")
    for th in (1000, 5000, 20000):
        s = [r for r in results if r["ms"] > th]
        print(f"  慢请求(>{th}ms): {len(s)} ({100.0*len(s)/max(1,len(results)):.1f}%)")
    worst = sorted(results, key=lambda r: -r["ms"])[:8]
    print("  最慢的 8 个: " + ", ".join(f"{r['id']}={r['ms']:.0f}ms/{r['status'] or r['err'][:20]}"
                                        for r in worst))
    # 每个 client 的吞吐，用来确认"并发确实是持续的"
    per = collections.Counter(r["worker"] for r in results)
    print("  每个 client 完成的请求数: " + ", ".join(f"w{k}={v}" for k, v in sorted(per.items())))


def cmd_join(a):
    rows = probe.parse_logs(probe.read_nginx_logs(a.since, a.logfile))
    by_id = {r["probe_id"]: r for r in rows if r["probe_id"]}
    client = list(csv.DictReader(open(a.csvfile)))
    print(f"=== 客户端 vs nginx 日志关联 (client={len(client)}, nginx={len(by_id)}) ===")
    lat = {}
    for c in client:
        r = by_id.get(c["id"])
        if not r:
            lat.setdefault("<客户端有、nginx 日志里没有>", []).append(float(c["ms"]))
            continue
        lat.setdefault(", ".join(r["ups"]), []).append(float(c["ms"]))
    for chain, vals in sorted(lat.items(), key=lambda x: -statistics.median(x[1])):
        print(f"  {chain:<50} n={len(vals):4d} p50={pct(vals,50):6.0f}ms "
              f"p95={pct(vals,95):6.0f}ms max={max(vals):6.0f}ms")
    # 慢请求明细
    slow = [(c, by_id.get(c["id"])) for c in client if float(c["ms"]) > 1000]
    if slow:
        print(f"\n  >1s 的请求（{len(slow)} 个）:")
        for c, r in sorted(slow, key=lambda x: -float(x[0]["ms"]))[:12]:
            ups = ", ".join(r["ups"]) if r else "-"
            urt = r["urt"] if r else "-"
            print(f"    {c['id']:<12} client={float(c['ms']):7.0f}ms status={c['status'] or c['err'][:24]:<24} "
                  f"upstream=[{ups}] urt={urt}")


def main():
    p = argparse.ArgumentParser(description="闭环并发压测")
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--url", default="http://127.0.0.1:8080")
    r.add_argument("--path", default="/")
    r.add_argument("--host", default="demo.local")
    r.add_argument("--concurrency", type=int, default=5)
    r.add_argument("--connections", type=int, default=1,
                   help="每个 client 维护多少条持久连接（轮转）。>1 时大部分连接处于空闲 ⇒ 专门压 LB reload 对空闲连接的影响")
    r.add_argument("--duration", type=int, default=60)
    r.add_argument("--method", choices=["GET", "POST"], default="GET")
    r.add_argument("--think", type=float, default=0.1, help="每个 client 两次请求之间的间隔(s)")
    r.add_argument("--stagger", type=float, default=0.0,
                   help="client 错开起跑的间隔(s)，建议 = slow/concurrency，避免整批同步落到同一个 upstream")
    r.add_argument("--slow", type=float, default=0.0,
                   help="让后端多睡 X 秒（用 /slow?sleep=Xs，需要 slow-backend）")
    r.add_argument("--timeout", type=float, default=60.0)
    r.add_argument("--retry-once", action="store_true",
                   help="连接级失败（没拿到任何响应）时，新建连接重试一次。用于量化“客户端重试能不能抹平 reload”")
    r.add_argument("--out", default="/tmp/conc.csv")
    r.add_argument("--mark", default="")
    r.set_defaults(func=cmd_run)
    j = sub.add_parser("join")
    j.add_argument("--csvfile", required=True)
    j.add_argument("--since", default="10m")
    j.add_argument("--logfile")
    j.set_defaults(func=cmd_join)
    a = p.parse_args()
    if a.cmd == "run" and a.slow:
        a.path = f"{a.path}?sleep={a.slow}"
    a.func(a)


if __name__ == "__main__":
    main()
