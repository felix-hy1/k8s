#!/usr/bin/env bash
# 修复 kind 节点内 containerd 的死代理问题:
# 1) 给 containerd 配置 docker.io 镜像站(daocloud,节点内已验证可直连)
# 2) 清掉 containerd 服务继承的死代理环境变量(127.0.0.1:7890 在容器内不存在)
set -euo pipefail

for node in k8s-learning-control-plane k8s-learning-worker k8s-learning-worker2; do
  echo "======== 处理节点: $node ========"

  # 1) containerd 配置追加镜像站(仅当未配置过)
  docker exec "$node" sh -c '
    grep -q "docker.m.daocloud.io" /etc/containerd/config.toml 2>/dev/null || cat >> /etc/containerd/config.toml <<EOF

[plugins."io.containerd.grpc.v1.cri".registry.mirrors."docker.io"]
  endpoint = ["https://docker.m.daocloud.io", "https://docker.1ms.run"]
EOF
  '

  # 2) 清掉 containerd 服务环境里的死代理(drop-in 覆盖)
  docker exec "$node" sh -c '
    mkdir -p /etc/systemd/system/containerd.service.d
    cat > /etc/systemd/system/containerd.service.d/99-proxy-fix.conf <<EOF
[Service]
Environment=HTTP_PROXY=
Environment=HTTPS_PROXY=
Environment=http_proxy=
Environment=https_proxy=
Environment=NO_PROXY=localhost,127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.local,10.96.0.0/16,10.244.0.0/16,.svc,.svc.cluster.local,docker.m.daocloud.io,docker.1ms.run
EOF
    systemctl daemon-reload
  '

  # 3) 重启 containerd 使配置生效(容器进程不受影响,Pod 短暂 NotReady 后恢复)
  docker exec "$node" sh -c 'systemctl restart containerd' || echo "⚠️ $node containerd 重启失败,请手动检查"

  echo "✅ $node 完成"
done

echo "======== 全部节点修复完成 ========"
