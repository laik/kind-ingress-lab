#!/usr/bin/env bash
# 拆掉整套环境（只删 ingress-lab 集群和 nginx-external 容器，不动你其它容器）
set -euo pipefail
docker rm -f nginx-external >/dev/null 2>&1 || true
kind delete cluster --name ingress-lab
echo "done"
