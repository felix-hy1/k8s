#!/usr/bin/env bash
# 创建 k8s-learning 学习集群并验证
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> 创建集群(1~3 分钟)..."
kind create cluster --config "$DIR/../manifests/kind-cluster.yaml" --wait 120s

echo "==> 切换默认 context..."
kubectl config use-context kind-k8s-learning

echo "==> 集群信息..."
kubectl cluster-info
kubectl get nodes -o wide

echo "✅ 集群就绪!节点名固定为:"
echo "   k8s-learning-control-plane / k8s-learning-worker / k8s-learning-worker2"
