#!/usr/bin/env python3
"""汇总多轮演练结果（读 failover-test.sh / l4-blindspot-test.sh 的产物目录）

对每个目录输出：状态码、重试数、摘流耗时（第一个受影响请求 → [hc] REMOVE）、耗时分布。
用法: ./scripts/summarize-runs.py /tmp/failover-l4 /tmp/failover-l4-post2 /tmp/l4-blindspot
"""
import csv
import glob
import os
import re
import statistics
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from importlib import import_module
probe = import_module("ingress-probe")

HC_REMOVE = re.compile(r"\[hc (\d\d):(\d\d):(\d\d)\] REMOVE (\S+)")
HC_ADD = re.compile(r"\[hc (\d\d):(\d\d):(\d\d)\] ADD (\S+)")


def hhmmss(h, m, s):
    return int(h) * 3600 + int(m) * 60 + int(s)


def log_time(row):
    # nginx 日志时间戳是 UTC（容器内）
    return hhmmss(*[int(x) for x in re.search(r":(\d\d):(\d\d):(\d\d)", row["time"]).groups()])


def summarize(d):
    out = {"dir": d}
    # 客户端侧
    rows = []
    for f in sorted(glob.glob(os.path.join(d, "*.csv"))):
        rows += list(csv.DictReader(open(f)))
    if rows:
        out["n"] = len(rows)
        st = {}
        for r in rows:
            st[r["status"] or "ERR"] = st.get(r["status"] or "ERR", 0) + 1
        out["status"] = st
        out["bad"] = sum(v for k, v in st.items() if k != "200")
        out["errs"] = sum(1 for r in rows if r["err"])
        ms = [float(r["ms"]) for r in rows]
        out["p50"], out["p95"], out["p99"], out["max"] = (
            probe.pct(ms, 50), probe.pct(ms, 95), probe.pct(ms, 99), max(ms))
        out["slow"] = sum(1 for x in ms if x > 1000)

    # nginx 侧 + 摘流时间线
    nlog = retried = 0
    first_hit = remove_at = add_at = None
    for f in sorted(glob.glob(os.path.join(d, "*.nginx.log"))):
        text = open(f, errors="replace").read()
        for line in text.splitlines():
            m = HC_REMOVE.search(line)
            if m:
                remove_at = hhmmss(*m.groups()[:3])
            m2 = HC_ADD.search(line)
            if m2:
                add_at = max(add_at or 0, hhmmss(*m2.groups()[:2]))
        for r in probe.parse_logs(text):
            nlog += 1
            if r["retries"] > 0 and first_hit is None:
                first_hit = log_time(r)
            retried += r["retries"]
    out["nginx_log"] = nlog
    out["retries"] = retried
    if first_hit and remove_at:
        out["detect_s"] = remove_at - first_hit
    return out


def main():
    hdr = (f"{'目录':<24}{'请求':>6}{'200':>7}{'非200':>7}{'传输错':>7}{'重试':>6}"
           f"{'摘流':>7}{'>1s':>5}{'p50':>7}{'p95':>7}{'p99':>7}{'max':>7}")
    print(hdr)
    print("-" * len(hdr))
    for d in sys.argv[1:]:
        s = summarize(d)
        print(f"{os.path.basename(d):<24}{s.get('n',0):>6}{s.get('status',{}).get('200',0):>7}"
              f"{s.get('bad',0):>7}{s.get('errs',0):>7}{s.get('retries',0):>6}"
              f"{(str(s['detect_s'])+'s' if s.get('detect_s') is not None else '-') :>7}"
              f"{s.get('slow',0):>5}{s.get('p50',0):>7.0f}{s.get('p95',0):>7.0f}"
              f"{s.get('p99',0):>7.0f}{s.get('max',0):>7.0f}")


if __name__ == "__main__":
    main()
