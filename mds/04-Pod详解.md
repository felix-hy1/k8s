# 第 04 章 Pod 详解(K8s 最小调度单元)

> 📁 本章实验资源(yaml / 脚本 / sql)位于 `D:\k8s\04-Pod详解\`,本文档位于 `D:\k8s\mds\`。

## 学习目标

1. 掌握 Pod 的完整字段结构与"共享"本质
2. 玩转多容器模式、初始化容器、三种探针、生命周期钩子
3. 理解 requests/limits 与 QoS 等级
4. 会排 Pod 常见故障(Pending / ImagePullBackOff / CrashLoopBackOff)

## 4.1 核心概念

### Pod 是什么

- **一组共享网络与存储的容器**,原子调度单位(一个 Pod 里的容器总在同一节点)
- 每个 Pod 一个独立 ClusterIP 空间内的 IP,容器间通过 `localhost` 互访
- Pod 是易逝的(Cattle 不是 Pet):挂了重建 IP 就变,所以永远不要直接依赖 Pod IP

### Pod 生命周期

```
Pending → ContainerCreating → Running ──(全部容器成功退出)──► Succeeded
              │                    │
              │                    ├─(容器失败,restartPolicy=Always)─► 重启(CrashLoopBackOff)
              └─(镜像/调度失败)──► Failed
```

- **Pod Conditions**:`PodScheduled / Initialized / ContainersReady / Ready`
- **restartPolicy**:`Always`(默认,控制器类要用)| `OnFailure` | `Never`(Job 用)

### 三种探针(面试高频)

| 探针 | 作用 | 失败后果 |
|------|------|----------|
| startupProbe | 应用启动慢,先等它成功才做后续检查 | 杀容器重启 |
| livenessProbe | 存活检查,"死透了没" | 杀容器重启 |
| readinessProbe | 就绪检查,"能不能接客" | 摘除 Service 端点,不重启 |

检查方式:`httpGet`(最常用)/ `exec` / `tcpSocket` / `grpc`。关键参数:`initialDelaySeconds`、`periodSeconds`、`timeoutSeconds`、`failureThreshold`、`successThreshold`。

### QoS 等级(由 requests/limits 推导)

| 等级 | 条件 | 节点资源紧张时 |
|------|------|----------------|
| Guaranteed | 每个容器 cpu/mem 都 requests=limits | 最后被驱逐 |
| Burstable | 有 requests 无 limits(或不相等) | 中间被驱逐 |
| BestEffort | 什么都不设 | 最先被驱逐 |

### 多容器设计模式

- **sidecar 边车**:主容器旁挂代理/日志收集(如 Istio envoy)
- **adapter 适配器**:转换输出格式
- **ambassador 大使**:代理外部连接

### Init 容器

- 在主容器前**按序执行**,全部成功才启动主容器
- 与主容器共享 Volume,但可拥有不同的镜像/安全上下文
- 常用于:等待依赖就绪、预处理数据、注册服务发现

---

## 实验列表(manifests/ 目录,按序执行)

| 实验 | 文件 | 内容 |
|------|------|------|
| 1 | `lab01-pod-basic.yaml` | 基本字段、env、imagePullPolicy |
| 2 | `lab02-multi-container.yaml` | 双容器 + emptyDir 共享(sidecar 模式) |
| 3 | `lab03-init-container.yaml` | 初始化容器按序执行 |
| 4 | `lab04-probes.yaml` | liveness/readiness + 故障演练 |
| 5 | `lab05-lifecycle.yaml` | postStart/preStop 钩子 |
| 6 | `lab06-resources-qos.yaml` | 三种 QoS 对照 |
| 7 | `lab07-securitycontext.yaml` | runAsUser/fsGroup/只读根文件系统 |

### 实验 1:基本 Pod

```bash
cd /mnt/d/k8s/04-Pod详解/manifests
kubectl apply -f lab01-pod-basic.yaml
kubectl get pods -n pod-lab -o wide
kubectl exec -it basic -n pod-lab -- env | grep MESSAGE   # 看注入的环境变量
```

### 实验 2:多容器共享

```bash
kubectl apply -f lab02-multi-container.yaml
kubectl logs web-with-sidecar -c log-writer -n pod-lab   # 主容器写日志
kubectl logs web-with-sidecar -c log-reader -n pod-lab   # 边车读共享目录
```

### 实验 3:Init 容器

```bash
kubectl apply -f lab03-init-container.yaml
kubectl get pods -n pod-lab -w        # 观察 Init:0/2 → Init:1/2 → PodInitializing → Running
kubectl describe pod init-demo -n pod-lab | grep -A5 Init
```

### 实验 4:探针(重点)

```bash
kubectl apply -f lab04-probes.yaml
kubectl get pods -n pod-lab
# healthy-pod:两个探针都通过
# broken-pod:liveness 探 81 端口(nginx 在 80)→ 反复重启 → CrashLoopBackOff
kubectl describe pod broken-pod -n pod-lab | grep -A3 Liveness
kubectl get pod broken-pod -n pod-lab -w    # RESTARTS 持续增加
```

### 实验 5:生命周期钩子

```bash
kubectl apply -f lab05-lifecycle.yaml
kubectl logs hook-demo -n pod-lab          # 看到 postStart 输出
kubectl delete pod hook-demo -n pod-lab --wait=false
kubectl logs hook-demo -n pod-lab -f       # 观察 preStop 的优雅退出输出
```

### 实验 6:QoS 等级

```bash
kubectl apply -f lab06-resources-qos.yaml
kubectl get pods -n pod-lab -o custom-columns='NAME:.metadata.name,QOS:.status.qosClass'
# 预期:guaranteed-pod/Guaranteed, burstable-pod/Burstable, besteffort-pod/BestEffort
```

### 实验 7:安全上下文

```bash
kubectl apply -f lab07-securitycontext.yaml
kubectl exec -it secure-pod -n pod-lab -- id      # uid=1000 gid=2000(groups 含 2000)
kubectl exec -it secure-pod -n pod-lab -- touch /etc/x   # 只读根文件系统 → Permission denied
```

### 清理

```bash
kubectl delete ns pod-lab
```

## 排错决策表

| 状态 | 含义 | 第一步 |
|------|------|--------|
| Pending | 调度失败(资源不够/亲和不匹配/污点) | `describe` 看 Events 最后几行 |
| ImagePullBackOff | 镜像拉不下来 | 检查镜像名/标签/网络/私有仓库凭证 |
| CrashLoopBackOff | 容器反复崩 | `logs --previous` 看崩溃前日志 |
| OOMKilled | 内存超 limit 被杀 | 调大 memory limit 或查泄漏 |
| Evicted | 节点资源紧张被驱逐 | `describe` 看 Reason,清理节点 |

## 练习任务

1. [ ] 手写一个带 liveness(httpGet /healthz)的 Pod,不许抄
2. [ ] 把实验 4 的 broken-pod 修好
3. [ ] 给实验 2 再加一个 sidecar:用 `busybox` 每秒把访问日志行数写到 stdout
4. [ ] 思考:readiness 失败和 liveness 失败,在 `kubectl get endpoints` 上分别有什么表现?动手验证

## 参考

- https://kubernetes.io/zh-cn/docs/concepts/workloads/pods/
- https://kubernetes.io/zh-cn/docs/concepts/workloads/pods/pod-lifecycle/
