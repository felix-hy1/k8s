#!/usr/bin/env bash
# 实验 2 前置:在 kind "节点容器"里创建静态 PV 用到的目录
set -euo pipefail
for node in k8s-learning-worker k8s-learning-worker2 k8s-learning-control-plane; do
  docker exec "$node" mkdir -p /data/pv1 /data/pv2
  echo "✅ $node:/data/pv1 /data/pv2 已就绪"
done
echo "提示:哪个节点真的挂了 PV,可用下面命令反查:"
echo "  kubectl get pv pv-manual-1 -o jsonpath='{.spec.hostPath.path}{\"\\n\"}'"
