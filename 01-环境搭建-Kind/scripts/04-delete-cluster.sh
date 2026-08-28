#!/usr/bin/env bash
# 删除学习集群
set -euo pipefail
kind delete cluster --name k8s-learning
echo "✅ 已删除。重建执行: bash 03-create-cluster.sh"
