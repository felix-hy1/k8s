#!/usr/bin/env bash
# 安装 kubectl 与 kind(Linux amd64;arm 机器请自行替换下载地址)
set -euo pipefail

echo "==> 安装 kubectl..."
STABLE=$(curl -L -s https://dl.k8s.io/release/stable.txt)
curl -sLo /tmp/kubectl "https://dl.k8s.io/release/${STABLE}/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 /tmp/kubectl /usr/local/bin/kubectl

echo "==> 安装 kind(v0.24.0,可到 https://github.com/kubernetes-sigs/kind/releases 查最新版)..."
curl -sLo /tmp/kind "https://kind.sigs.k8s.io/dl/v0.24.0/kind-linux-amd64"
chmod +x /tmp/kind
sudo mv /tmp/kind /usr/local/bin/kind

echo "==> 配置 kubectl 自动补全与别名..."
grep -q 'kubectl completion bash' ~/.bashrc || echo 'source <(kubectl completion bash)' >> ~/.bashrc
grep -q 'alias k=kubectl' ~/.bashrc || echo 'alias k=kubectl' >> ~/.bashrc

kubectl version --client
kind version
echo "✅ kubectl 与 kind 安装完成"
