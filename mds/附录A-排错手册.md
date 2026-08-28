# 附录 A:K8s 排错手册(Troubleshooting)

> 通用三板斧:`kubectl describe` 看 Events → `kubectl logs --previous` 看崩溃前日志 → `kubectl get events --sort-by=.lastTimestamp` 看全局事件。

## A.1 Pod 状态速查表

| 状态 | 含义 | 排查命令 |
|------|------|----------|
| Pending | 没被调度(资源/亲和/污点/PVC) | `describe pod` 尾部 Events |
| ContainerCreating | 拉镜像/挂卷中 | 卡住超 1 分钟 → describe 看挂卷或网络 |
| ImagePullBackOff | 镜像拉取失败 | 核对镜像名/tag/仓库凭证 |
| CrashLoopBackOff | 容器反复崩溃 | `logs --previous` |
| OOMKilled | 内存超限被内核杀 | `describe` Last State;调大 limit |
| Evicted | 节点资源紧张被驱逐 | `describe` Reason;DiskPressure/MemoryPressure |
| Terminating 卡住 | finalizer 阻塞 / kubelet 失联 | `get -o yaml` 看 metadata.finalizers |

## A.2 常见故障与处置

### 1. ImagePullBackOff
```bash
kubectl describe pod xx | grep -A3 Events
# 检查项:
#   镜像名拼写、tag 是否存在
#   私有仓库:imagePullSecrets 是否配置
#   kind/WSL:docker info 确认网络与 mirror
```

### 2. CrashLoopBackOff
```bash
kubectl logs xx --previous | tail -50    # 上一世日志(关键!)
kubectl get pod xx -o jsonpath='{.status.lastState.terminated.exitCode}'
# 常见:配置错误(env/CM/Secret 缺失)、探针太严、权限(文件不可写)、依赖连不上
```

### 3. Service 访问不通(四步定位)
```bash
# ① endpoints 有吗?
kubectl get ep svc名
#   空 → selector 与 Pod label 不匹配,或 readiness 没过
# ② Pod 内直连 targetPort 通吗?
kubectl exec pod -- curl localhost:8080
# ③ Service 名解析吗?
kubectl run t --rm -it --image=busybox --restart=Never -- nslookup svc名
# ④ 集群外暴露方式对吗?(NodePort 端口/Ingress host/防火墙)
```

### 4. DNS 解析失败
```bash
kubectl -n kube-system get pods -l k8s-app=kube-dns        # CoreDNS 活着?
kubectl exec -it pod -- cat /etc/resolv.conf               # nameserver 10.96.0.10?
# ndots:5 陷阱:域名不足 5 段会先走 search 域,外部域名尽量加结尾点号
nslookup www.baidu.com.
```

### 5. PVC 一直 Pending
```bash
kubectl describe pvc xx      # 看 Events
# 静态供给:没有匹配的 PV(容量/模式/storageClassName)
# 动态供给:SC 的 provisioner 是否就绪(kind: local-path-provisioner 在 kube-system)
```

### 6. Ingress 404 / 503
```bash
# 404:host/path 不匹配 → curl -H "Host: xx" 验证;describe ingress 核对
# 503:后端没 Ready → get ep;controller 日志: kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller
```

### 7. HPA 一直 unknown
```bash
kubectl top nodes    # metrics-server 正常?
# Pod 必须有 cpu requests(百分比分母);检查 metrics-server 的 --kubelet-insecure-tls(kind)
```

### 8. Node NotReady
```bash
kubectl describe node xx | tail -15     # kubelet 停?网络分区?
docker ps | grep worker                 # kind:节点容器还在吗
journalctl -u kubelet                   # 真实集群看 kubelet 日志
```

### 9. RBAC 403
```bash
kubectl auth can-i delete pods -n xx --as=system:serviceaccount:ns:sa   # 快速验证
# 看 Role verbs/resources 是否覆盖;RoleBinding 的 subjects 命名空间要写对
```

### 10. kubectl 连不上集群
```bash
kubectl config get-contexts && kubectl config use-context kind-k8s-learning
# kind 重建后旧 context 失效:~/.kube/config 会被 kind 自动维护
docker ps | grep k8s-learning-control-plane   # 控制面活着吗
```

## A.3 kind 专属问题

| 症状 | 解法 |
|------|------|
| 建集群卡 `Configuring node` | WSL 内存不足:`wsl --shutdown`,`.wslconfig` 限内存 6GB/swap 2GB |
| localhost:80 不通 | 建集群用了无 extraPortMappings 的配置;重建用第 01 章模板 |
| NodePort 从 Windows 不通 | 在 WSL 内 curl 节点 IP:端口;Windows→WSL 只转发 localhost |
| 拉镜像慢/失败 | docker daemon.json 加 registry-mirrors 后重启 docker |

## A.4 健康检查清单(巡检模板)

```bash
kubectl get nodes                                  # 全 Ready
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
kubectl get hpa -A                                 # 指标正常
kubectl top nodes                                  # 资源水位
kubectl get events -A --sort-by=.lastTimestamp | tail -20
```
