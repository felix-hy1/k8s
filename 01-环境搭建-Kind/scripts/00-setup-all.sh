#!/usr/bin/env bash
# 一键安装:docker + kubectl + kind,并创建学习集群
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> [1/3] 安装 Docker..."
bash "$DIR/01-install-docker.sh"

echo "==> [2/3] 安装 kubectl 与 kind..."
bash "$DIR/02-install-kubectl-kind.sh"

echo "==> [3/3] 创建学习集群..."
bash "$DIR/03-create-cluster.sh"

echo ""
echo "✅ 全部完成!别忘了重新登录一次 WSL 使 docker 组生效。"
