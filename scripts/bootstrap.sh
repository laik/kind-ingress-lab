#!/usr/bin/env bash
# 一条命令重建整套环境: kind 5 节点 -> 角色标签/taint -> ingress-nginx(NodePort 31000, 只跑 infra) -> demo 业务 -> 集群外 nginx
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLUSTER=ingress-lab
CTX=kind-${CLUSTER}
INFRA_NODES=${INFRA_NODES:-"ingress-lab-worker ingress-lab-worker2"}
WORKER_NODES=${WORKER_NODES:-"ingress-lab-worker3 ingress-lab-worker4"}

echo "### 1/5 创建 kind 集群 (1 control-plane + 2 infra + 2 worker)"
kind get clusters 2>/dev/null | grep -qx "$CLUSTER" && {
  echo "  已存在，跳过创建（如需重建: ./scripts/teardown.sh）"; } || {
  kind create cluster --config "$ROOT/kind-config.yaml" --wait=5m
}
kubectl config use-context "$CTX" >/dev/null

echo "### 2/5 打角色标签 + infra taint（不能用 kind 的 labels: 字段，见 README 坑#1）"
for n in $INFRA_NODES; do
  kubectl label node "$n" node-role.kubernetes.io/infra=true --overwrite >/dev/null
  kubectl taint node "$n" node-role.kubernetes.io/infra=:NoSchedule --overwrite >/dev/null
done
for n in $WORKER_NODES; do
  kubectl label node "$n" node-role.kubernetes.io/node= --overwrite >/dev/null
  kubectl taint node "$n" node-role.kubernetes.io/infra:NoSchedule- >/dev/null 2>&1 || true
done
kubectl get nodes

echo "### 3/5 安装 ingress-nginx -> infra 节点 (Deployment + topologySpread + NodePort 31000 + externalTrafficPolicy: Local + internalTrafficPolicy: Local)"
kubectl create ns ingress-nginx --dry-run=client -o yaml | kubectl apply -f - >/dev/null
# chart 4.15.1 没有 internalTrafficPolicy 这个 value，用 post-renderer 注入，保证 upgrade 幂等
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx -f "$ROOT/ingress-nginx-values.yaml" \
  --post-renderer "$ROOT/scripts/post-render-itp.py" --wait --timeout 8m >/dev/null
kubectl -n ingress-nginx get pods -o wide
kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o custom-columns='NAME:.metadata.name,TYPE:.spec.type,ETP:.spec.externalTrafficPolicy,ITP:.spec.internalTrafficPolicy,NODEPORTS:.spec.ports[*].nodePort'

echo "### 4/5 部署 demo 业务 + Ingress 规则（只跑 worker 节点）"
kubectl apply -f "$ROOT/manifests/demo-app.yaml" >/dev/null
kubectl -n demo rollout status deploy/whoami --timeout=3m >/dev/null

echo "### 5/5 启动集群外 nginx (upstream -> infra 节点 NodePort 31000)"
"$ROOT/scripts/external-nginx.sh"

cat <<'EOF'

=== 完成 ===
链路:  curl http://127.0.0.1:8080/  ->  nginx-external(容器, kind 网络)
       -> 172.18.0.x:31000 (infra 节点 NodePort)
       -> ingress-nginx pod (infra 节点)
       -> whoami pod (worker 节点)

验证:
  curl -H 'Host: demo.local'   http://127.0.0.1:8080/
  curl -H 'Host: api.demo.local' http://127.0.0.1:8080/v1
  curl http://127.0.0.1:31000/ -H 'Host: demo.local'   # 直连 NodePort（走 control-plane 端口映射）
EOF
