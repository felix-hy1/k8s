# 第 15 章 资源管理与自动扩缩容(HPA)

> 📁 本章实验资源(yaml / 脚本 / sql)位于 `D:\k8s\15-资源管理与HPA\`,本文档位于 `D:\k8s\mds\`。

## 学习目标

1. 安装 metrics-server,让 `kubectl top` 可用
2. 亲手复现 CPU 节流(throttling)与 OOMKilled
3. 用 LimitRange / ResourceQuota 治理命名空间
4. 部署 HPA 并完成一次压测扩缩容闭环

## 15.1 核心概念

### requests 与 limits(复习+深化)

- `requests`:调度依据(占坑);`limits`:运行上限(CPU 被节流,内存被 OOMKill)
- CPU:`1` = 1 核,`500m` = 0.5 核;内存:`Mi`(2^20)/`Gi`(2^30)
- CPU 超限 → **不杀进程,只是变慢**;内存超限 → **内核 OOM Killer 直接杀**

### 治理三件套

| 对象 | 作用 |
|------|------|
| QoS(第 04 章) | 单 Pod 级:驱逐优先级 |
| LimitRange | ns 级:给"没写资源的 Pod"设默认值 + 上下限 |
| ResourceQuota | ns 级:整个命名空间的资源总配额 + 对象数量限额 |

### HPA(autoscaling/v2)

```
指标采集(metrics-server/自定义指标) → HPA 控制器算期望副本数 → 改 Deployment.replicas
期望副本 = ceil(当前副本 × 当前指标值 / 目标值)
```

- 缩容有**稳定窗口**(默认 5 分钟),防止抖动
- `behavior` 字段可精细控制扩缩速率

---

## 实验列表

### 步骤 0:安装 metrics-server(kind 必须加免 TLS 参数)

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl patch deployment metrics-server -n kube-system --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
kubectl -n kube-system wait --for=condition=available deployment/metrics-server --timeout=180s
kubectl top nodes && kubectl top pods -A | head -5
```

### 实验 1:CPU 节流 vs OOMKill

```bash
cd /mnt/d/k8s/15-资源管理与HPA/manifests
kubectl apply -f lab01-qos-stress.yaml
kubectl top pods -n res-lab
# cpu-burn:CPU limit 100m,死循环 → 节流(状态正常但吞吐被限)
kubectl exec -it cpu-burn -n res-lab -- sh -c 'while :; do :; done' &  # 可选:直接打满
kubectl get pod cpu-burn -n res-lab -w
# mem-burn:内存 limit 100Mi,持续申请内存 → 观察 RESTARTS 与 Last State: OOMKilled
kubectl describe pod mem-burn -n res-lab | grep -A2 "Last State"
```

### 实验 2:LimitRange + ResourceQuota

```bash
kubectl apply -f lab02-limitrange-quota.yaml
# 没有 resources 的 Pod 会被注入默认值:
kubectl run no-res -n res-lab --image=nginx:1.27
kubectl get pod no-res -n res-lab -o jsonpath='{.spec.containers[0].resources}'; echo
# 超配额即拒绝(注意是 apiserver 直接报错,不是 Pending):
kubectl create deployment quota-hit -n res-lab --image=nginx:1.27
kubectl get resourcequota -n res-lab -o yaml | grep -A8 used
```

### 实验 3:HPA 压测闭环(经典 php-apache)

```bash
kubectl apply -f lab03-hpa.yaml
kubectl get hpa -n res-lab -w        # 另开一个终端盯着

# 起压(load-generator Pod 里死循环打请求):
kubectl exec -it load-generator -n res-lab -- sh \
  -c 'while true; do wget -q -O- http://php-apache; done'

# 观察:TARGETS 从 3%/50% 涨到 200%+ → REPLICAS 1→N(扩容)
# 停压后 ~5 分钟稳定窗口 → 副本缩回
kubectl get hpa php-apache -n res-lab
```

### 清理

```bash
kubectl delete ns res-lab
```

## 常见问题

| 问题 | 答案 |
|------|------|
| HPA 一直 `unknown`? | metrics-server 没就绪,或 Pod 没设 cpu requests(百分比没有分母) |
| 为什么 CPU 超限不报错? | 节流是"软"限制,设计如此;看指标:container_cpu_cfs_throttled_seconds |
| `kubectl top` 报 error? | metrics-server 没装/没加 --kubelet-insecure-tls(kind 特有) |
| HPA 与手动 scale 冲突? | HPA 会接管 replicas 字段,手动改会被覆盖 |

## 练习任务

1. [ ] 给 lab03 的 HPA 加 memory 指标(50%)并验证
2. [ ] 把稳定窗口改为 60s:`behavior.scaleDown.stabilizationWindowSeconds`
3. [ ] 用 `kubectl get hpa -o yaml` 查 currentMetrics 的实际值

## 参考

- https://kubernetes.io/zh-cn/docs/tasks/run-application/horizontal-pod-autoscale/
