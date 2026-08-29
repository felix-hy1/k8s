#!/usr/bin/env bash
# 宿主机拉取镜像 → 注入 kind 学习集群所有节点
#
# 为什么要这个脚本(本机网络环境的已知限制):
#   1. kind 节点内的 containerd 被烙了代理 127.0.0.1:7890,但节点是独立容器,
#      127.0.0.1 指向节点自己,Clash 不在里面 → 节点直接拉镜像必失败
#   2. 宿主机 dockerd 配了可用代理(见附录A案例一),可以正常 docker pull
#   3. 因此正确姿势:宿主机拉 → 导入节点本地镜像库,节点拉镜像时直接命中本地
#
# 用法: bash load-image.sh nginx:1.27 [mysql:8.0 ...]
# 提示:Pod 若已处于 ImagePullBackOff,注入后删掉 Pod 让它重拉即可
set -euo pipefail
CLUSTER="k8s-learning"
NODES=("${CLUSTER}-control-plane" "${CLUSTER}-worker" "${CLUSTER}-worker2")

if [ "$#" -eq 0 ]; then
  echo "用法: $0 <镜像1> [镜像2 ...]" >&2
  exit 1
fi

for img in "$@"; do
  echo "==> 宿主机拉取 $img ..."
  docker pull "$img"

  for node in "${NODES[@]}"; do
    echo "==> 注入 $node ..."
    # 单架构导出,规避 docker save 多平台清单与节点 containerd 的导入兼容问题
    docker save --platform linux/amd64 "$img" | docker exec -i "$node" ctr -n k8s.io images import -
  done

  echo "✅ $img 已注入全部节点"
done
