#!/usr/bin/env bash
# 动态调整 infra-node 数量，并把 ingress 副本数按 每节点3个 重算
#   ./scripts/scale-infra.sh add    ingress-lab-worker3
#   ./scripts/scale-infra.sh remove ingress-lab-worker3
#   ./scripts/scale-infra.sh status
set -euo pipefail
CLUSTER=${CLUSTER:-ingress-lab}
CTX=kind-${CLUSTER}
PER_NODE=${PER_NODE:-3}
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

infra_count() {
  kubectl --context "$CTX" get nodes -l node-role.kubernetes.io/infra=true --no-headers 2>/dev/null | wc -l | tr -d ' '
}
show() {
  echo "infra nodes:"
  kubectl --context "$CTX" get nodes -l node-role.kubernetes.io/infra=true \
    -o custom-columns='NODE:.metadata.name,IP:.status.addresses[0].address' --no-headers | sed 's/^/  /'
  echo "ingress pod 分布:"
  kubectl --context "$CTX" -n ingress-nginx get pods -l app.kubernetes.io/component=controller -o wide --no-headers \
    | awk '{c[$7]++} END {for(n in c) print "   "n": "c[n]}' | sort
}

case "${1:-status}" in
  add)
    node="${2:?node name required}"
    kubectl --context "$CTX" label node "$node" node-role.kubernetes.io/infra=true --overwrite
    kubectl --context "$CTX" taint node "$node" node-role.kubernetes.io/infra:NoSchedule --overwrite
    N=$(infra_count); R=$((N * PER_NODE))
    echo "infra-node=$N -> replicas=$R"
    helm --kube-context "$CTX" upgrade ingress-nginx ingress-nginx/ingress-nginx \
      -n ingress-nginx -f "$ROOT/ingress-nginx-values.yaml" \
      --post-renderer "$ROOT/scripts/post-render-itp.py" \
      --set controller.replicaCount=$R --wait --timeout 5m >/dev/null
    # 等新节点上出现本地 endpoint，再让上游 LB 导流
    ip=$(kubectl --context "$CTX" get node "$node" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' | awk '{print $1}')
    for i in $(seq 1 30); do
      if docker run --rm --network kind alpine:3.20 nc -z -w 2 "$ip" "${NODEPORT:-31000}" >/dev/null 2>&1; then
        echo "  $ip:${NODEPORT:-31000} 已有本地 endpoint，可以导流"; break
      fi
      sleep 2
    done
    ;;
  remove)
    node="${2:?node name required}"
    kubectl --context "$CTX" cordon "$node"
    kubectl --context "$CTX" drain "$node" --ignore-daemonsets --delete-emptydir-data --force --timeout=3m || {
      echo "  ⚠ drain 可能因 topologySpread(DoNotSchedule) 卡住，见 PITFALLS.md P-06"; }
    kubectl --context "$CTX" label node "$node" node-role.kubernetes.io/infra- >/dev/null 2>&1 || true
    kubectl --context "$CTX" taint node "$node" node-role.kubernetes.io/infra:NoSchedule- >/dev/null 2>&1 || true
    N=$(infra_count); R=$((N * PER_NODE))
    echo "infra-node=$N -> replicas=$R"
    helm --kube-context "$CTX" upgrade ingress-nginx ingress-nginx/ingress-nginx \
      -n ingress-nginx -f "$ROOT/ingress-nginx-values.yaml" \
      --post-renderer "$ROOT/scripts/post-render-itp.py" \
      --set controller.replicaCount=$R --wait --timeout 5m >/dev/null
    ;;
  status) : ;;
  *) echo "用法: $0 {add|remove|status} [node]"; exit 1 ;;
esac
show
