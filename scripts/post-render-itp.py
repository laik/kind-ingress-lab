#!/usr/bin/env python3
"""helm post-renderer: 给 ingress-nginx-controller 这个 Service 注入 internalTrafficPolicy。

chart 4.15.1 的 values 里没有 internalTrafficPolicy 这个字段（grep templates/ 无结果），
用 post-renderer 注入可以随 helm upgrade 幂等重放，不会被覆盖回去。

用法: helm upgrade ... --post-renderer ./scripts/post-render-itp.py
环境变量:
  ITP_SERVICE      目标 Service 名 (默认 ingress-nginx-controller)
  ITP_VALUE        要设置的值 (默认 Local)
"""
import os
import sys

TARGET = os.environ.get("ITP_SERVICE", "ingress-nginx-controller")
VALUE = os.environ.get("ITP_VALUE", "Local")

docs = sys.stdin.read().split("\n---\n")
out = []

for doc in docs:
    if not doc.strip():
        out.append(doc)
        continue
    lines = doc.split("\n")

    kind = None
    name = None
    spec_idx = None
    already = None
    for i, ln in enumerate(lines):
        if ln.startswith("kind: "):
            kind = ln.split(":", 1)[1].strip()
        # metadata.name 是 2 空格缩进，避免匹配到 selector/label 里的名字
        elif ln.startswith("  name: ") and name is None:
            name = ln.split(":", 1)[1].strip()
        elif ln == "spec:" and spec_idx is None:
            spec_idx = i
        elif ln.startswith("  internalTrafficPolicy:"):
            already = i

    if kind == "Service" and name == TARGET and spec_idx is not None:
        if already is not None:
            lines[already] = f"  internalTrafficPolicy: {VALUE}"
        else:
            lines.insert(spec_idx + 1, f"  internalTrafficPolicy: {VALUE}")
        doc = "\n".join(lines)

    out.append(doc)

sys.stdout.write("\n---\n".join(out))
