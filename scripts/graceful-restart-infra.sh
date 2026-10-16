#!/usr/bin/env bash
# 优雅重启一台 infra-node：让 502 = 0 的顺序。
#
#   1) cordon                防止新 pod 被调度上来
#   2) LB 预摘流             把该节点从 upstream 候选里摘掉（生产里 = 撤 BGP 宣告 / LB 摘节点）
#   3) 等 PRE_DRAIN 秒       在飞请求排空（必须 > 业务最长请求时间）
#   4) drain                 优雅终止 ingress pod（endpoint 先摘，nginx 自己 drain）
#   5) docker restart        真正的重启
#   6) 等节点/pod Ready
#   7) uncordon + 加回候选   healthcheck 探测连续 OK_MAX 次成功后自动 ADD
#
# 关键点：第 2、3 步必须在第 4、5 步之前 —— 顺序错了就会出现
# "请求已发到那台节点、连接被中途关闭" 的 502（非幂等请求 nginx 不重试）。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NODE=${1:?用法: graceful-restart-infra.sh <node-name> [pre-drain-seconds]}
PRE_DRAIN=${2:-15}
CLUSTER=${CLUSTER:-ingress-lab}
CTX=kind-${CLUSTER}
NODEPORT=${NODEPORT:-31000}
UP="$ROOT/nginx/upstream"
# PRE_DRAIN_LB=0 → 不做第 2 步（不从 LB 候选里摘掉该节点），只靠 k8s 侧 cordon/drain + LB 自己的探测被动摘流
PRE_DRAIN_LB=${PRE_DRAIN_LB:-1}

nip() { kubectl --context "$CTX" get node "$1" \
        -o 'jsonpath={.status.addresses[?(@.type=="InternalIP")].address}' | awk '{print $1}'; }
candidates() { kubectl --context "$CTX" get nodes -l node-role.kubernetes.io/infra=true \
        -o 'jsonpath={.items[*].status.addresses[?(@.type=="InternalIP")].address}' \
        | tr ' ' '\n' | grep -E '^[0-9]+(\.[0-9]+){3}$'; }
write_list() { # 原子替换候选列表（直接 > 会先截断，healthcheck 读到空 → no live upstreams → 502）
  printf '%s\n' "$@" > "$UP/.nodes.tmp" && mv "$UP/.nodes.tmp" "$UP/nodes"; }

IP=$(nip "$NODE")
echo "[1/7] cordon $NODE"
kubectl --context "$CTX" cordon "$NODE" >/dev/null

if [ "$PRE_DRAIN_LB" = "1" ]; then
  echo "[2/7] LB 预摘流：从 upstream 候选里去掉 $IP"
  write_list $(candidates | grep -v "^$IP$")
  echo "      当前候选: $(tr '\n' ' ' < "$UP/nodes")"
else
  echo "[2/7] 跳过 LB 预摘流（PRE_DRAIN_LB=0）：节点留在 LB 池里，靠 LB 探测被动摘流"
fi

echo "[3/7] 等 ${PRE_DRAIN}s 让在飞请求排空（必须 > 业务最长请求时间）"
sleep "$PRE_DRAIN"

echo "[4/7] drain ${NODE}（优雅终止 ingress pod，endpoint 先摘）"
kubectl --context "$CTX" drain "$NODE" --ignore-daemonsets --delete-emptydir-data --force \
       --grace-period=60 --timeout=180s >/dev/null 2>&1 || echo "      drain 有告警（TSC 硬约束下被驱逐 pod 会 Pending，正常）"

echo "[5/7] docker restart $NODE"
docker restart "$NODE" >/dev/null

echo "[6/7] 等节点 Ready"
for i in $(seq 1 60); do
  st=$(kubectl --context "$CTX" get node "$NODE" -o \
       jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  [ "$st" = "True" ] && break
  sleep 5
done
echo "      node Ready=$st ip=$(nip "$NODE")"

echo "[7/7] uncordon + 加回候选（healthcheck 探测通过会自动 ADD）"
kubectl --context "$CTX" uncordon "$NODE" >/dev/null
for i in $(seq 1 24); do
  n=$(kubectl --context "$CTX" -n ingress-nginx get pods -l app.kubernetes.io/component=controller \
        -o 'jsonpath={range .items[*]}{.spec.nodeName}{"\n"}{end}' 2>/dev/null | grep -c "^${NODE}$" || true)
  [ "${n:-0}" -ge 1 ] && break
  sleep 5
done
write_list $(candidates)
echo "      候选已恢复: $(tr '\n' ' ' < "$UP/nodes")"

echo
echo "结果："
grep 'server ' "$UP/nodeports.conf" | sed 's/^/  upstream: /'
kubectl --context "$CTX" -n ingress-nginx get pods -l app.kubernetes.io/component=controller \
  -o 'jsonpath={range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort | uniq -c | sed 's/^/  pod:    /'
