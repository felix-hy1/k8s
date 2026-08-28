# 第 01 章 环境搭建:WSL2 + Docker + kind 学习集群

> 📁 本章实验资源(yaml / 脚本 / sql)位于 `D:\k8s\01-环境搭建-Kind\`,本文档位于 `D:\k8s\mds\`。

## 学习目标

1. 在 Windows 的 WSL2(Ubuntu)中安装 Docker、kubectl、kind
2. 创建一个 **1 控制面 + 2 工作节点** 的多节点集群
3. 掌握集群的创建、验证、删除全流程

## 架构总览

```
Windows 11
└── WSL2 (Ubuntu)
    ├── Docker Engine(容器运行时)
    │   ├── 容器: k8s-learning-control-plane  ← 控制面节点
    │   ├── 容器: k8s-learning-worker        ← 工作节点 1
    │   └── 容器: k8s-learning-worker2       ← 工作节点 2
    └── kubectl → 通过 kubeconfig 连接控制面 6443 端口
```

kind(Kubernetes IN Docker)把每个"节点"做成一个 Docker 容器,再在里面跑 kubelet/kubeadm,是最贴近真实多节点体验的本地学习方案。

---

## 实验步骤

### 步骤 1:安装 WSL2 与 Ubuntu(仅首次)

以**管理员**身份打开 PowerShell:

```powershell
wsl --install -d Ubuntu
# 重启电脑后首次进入 Ubuntu,设置用户名和密码
wsl --set-default-version 2
wsl -l -v   # 确认 VERSION 列为 2
```

进入 WSL 后建议先换国内软件源(可选,加速 apt):

```bash
sudo sed -i 's@//.*archive.ubuntu.com@//mirrors.aliyun.com@g' /etc/apt/sources.list
sudo apt update && sudo apt -y upgrade
```

### 步骤 2:安装 Docker

```bash
bash /mnt/d/k8s/01-环境搭建-Kind/scripts/01-install-docker.sh
# 重新登录使 docker 组生效,然后验证:
docker version && docker ps
```

> WSL2 未启用 systemd 时脚本会用 `service docker start` 启动;
> Ubuntu 22.04+ 若 `/etc/wsl.conf` 中 `systemd=true`,则直接 `systemctl enable --now docker`。

### 步骤 3:安装 kubectl 与 kind

```bash
bash /mnt/d/k8s/01-环境搭建-Kind/scripts/02-install-kubectl-kind.sh
kubectl version --client
kind version
# 配置命令自动补全(写进 ~/.bashrc 永久生效)
echo 'source <(kubectl completion bash)' >> ~/.bashrc
echo 'alias k=kubectl' >> ~/.bashrc
source ~/.bashrc
```

### 步骤 4:创建集群

```bash
bash /mnt/d/k8s/01-环境搭建-Kind/scripts/03-create-cluster.sh
```

预期输出(约 1~3 分钟):

```
NAME                            STATUS   ROLES           AGE   VERSION
k8s-learning-control-plane      Ready    control-plane   30s   v1.30.x
k8s-learning-worker             Ready    <none>          25s   v1.30.x
k8s-learning-worker2            Ready    <none>          20s   v1.30.x
```

### 步骤 5:验证集群

```bash
kubectl cluster-info --context kind-k8s-learning
kubectl get nodes -o wide
kubectl get pods -A          # 能看到 coredns/kube-proxy 等系统 Pod
```

---

## 关键配置说明(kind-cluster.yaml)

| 配置 | 作用 |
|------|------|
| `nodes: 1 control-plane + 2 worker` | 模拟真实多节点,后续调度/网络实验需要 |
| `extraPortMappings: 80/443` | 把宿主机(WSL)80/443 映射到控制面容器,第 09 章 Ingress 可直接用浏览器访问 `http://localhost` |
| `node-labels: ingress-ready=true` | ingress-nginx 官方 kind 清单要求控制面带此标签 |
| `kubeadmConfigPatches` | 向 kubeadm 注入自定义参数 |

## 文件清单

| 文件 | 说明 |
|------|------|
| `manifests/kind-cluster.yaml` | 默认学习集群(3 节点 + 端口映射) |
| `manifests/kind-cluster-ha.yaml` | 进阶:3 控制面高可用集群(内存 ≥12GB 再玩) |
| `scripts/00-setup-all.sh` | 一键安装 + 建集群 |
| `scripts/01-install-docker.sh` | Docker Engine 安装 |
| `scripts/02-install-kubectl-kind.sh` | kubectl + kind 安装 |
| `scripts/03-create-cluster.sh` | 创建学习集群 |
| `scripts/04-delete-cluster.sh` | 删除集群 |

## 常见问题

| 现象 | 解决 |
|------|------|
| `kind create` 卡在 `Configuring node` | WSL 内存不足,`wsl --shutdown` 后在 `C:\Users\你\.wslconfig` 里限 6GB 内存+2GB swap |
| 拉镜像超时 | 在 `/etc/docker/daemon.json` 配置 registry-mirrors(脚本注释里有阿里云示例),`sudo service docker restart` |
| WSL 里 `docker ps` 报权限 | 忘记把用户加组,`sudo usermod -aG docker $USER` 后重开终端 |
| 想重置整个集群 | `bash scripts/04-delete-cluster.sh && bash scripts/03-create-cluster.sh` |

## 练习任务

1. [ ] 不看文档,独立完成:删集群 → 重建 → `kubectl get nodes` 全 Ready
2. [ ] `docker ps` 观察三个"节点"容器;`docker exec k8s-learning-worker ps aux` 看节点内进程
3. [ ] (进阶)用 `kind-cluster-ha.yaml` 建 HA 集群观察 3 个控制面,玩完删除
