#!/usr/bin/env bash
# 在 WSL2 Ubuntu 上安装 Docker Engine
set -euo pipefail

echo "==> 安装依赖..."
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg

echo "==> 添加 Docker 官方 apt 源..."
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

echo "==> 安装 Docker..."
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

echo "==> 配置国内镜像加速(可选,拉取 docker.io 镜像慢时打开)..."
# sudo tee /etc/docker/daemon.json <<'EOF'
# {
#   "registry-mirrors": ["https://docker.m.daocloud.io"]
# }
# EOF

echo "==> 启动 Docker..."
if command -v systemctl &>/dev/null && systemctl is-system-running &>/dev/null; then
  sudo systemctl enable --now docker
else
  sudo service docker start
fi

sudo usermod -aG docker "$USER"
echo "✅ Docker 安装完成。请重新打开 WSL 终端后执行: docker ps 验证"
