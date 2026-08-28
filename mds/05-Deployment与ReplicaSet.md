# 第 05 章 Deployment 与 ReplicaSet(无状态工作负载)

> 📁 本章实验资源(yaml / 脚本 / sql)位于 `D:\k8s\05-Deployment与ReplicaSet\`,本文档位于 `D:\k8s\mds\`。

## 学习目标

1. 理解 Deployment → ReplicaSet → Pod 三层关系
2. 掌握滚动更新原理与 maxSurge/maxUnavailable 调参
3. 熟练使用 rollout 系列命令:观察、暂停、恢复、回滚

## 5.1 核心概念

### 三层关系

```
Deployment(版本管理/发布策略)
   └── ReplicaSet(副本数量控制,每个版本一个 RS)
          └── Pod × N(真正干活的)
```

- 你几乎永远不直接创建 ReplicaSet;Deployment 每次改 Pod 模板都会**生成新 RS**,旧 RS 保留(缩为 0)用于回滚
- 只有 `spec.template` 变化才触发滚动; replicas 变化只扩缩容

### 滚动更新参数(strategy.rollingUpdate)

| 参数 | 含义 | 默认 | 特殊值 |
|------|------|------|--------|
| maxSurge | 最多可超出期望副本数 | 25% | 滚动期间最多 `replicas+maxSurge` 个 Pod |
| maxUnavailable | 最多可不可用副本数 | 25% | 设 0 = 全程不损容量(需资源充足) |

两种策略:`RollingUpdate`(默认)/ `Recreate`(先全杀再建,会有停机窗口)。

### 回滚与历史

- `revisionHistoryLimit`(默认 10):保留几个旧 RS
- 回滚 = 把旧 RS 扩回来、新 RS 缩回去
- 发布时加注解 `kubernetes.io/change-cause` 会在 rollout history 里显示说明

---

## 实验列表

### 实验 1:基本发布与滚动更新观察

```bash
cd /mnt/d/k8s/05-Deployment与ReplicaSet/manifests
kubectl apply -f lab01-rolling.yaml --record=false
kubectl get rs -n deploy-lab          # 1 个 RS,3 副本

# 改版本观察滚动全过程(开两个终端,一个 -w 盯着)
kubectl set image deployment/web nginx=nginx:1.28 -n deploy-lab
kubectl rollout status deployment/web -n deploy-lab
kubectl get rs -n deploy-lab          # 出现新旧两个 RS:新=3 旧=0
```

### 实验 2:两种策略对比

```bash
kubectl apply -f lab02-strategy.yaml -n deploy-lab   # 文件里自建 ns,改为先 apply -f lab02(内含ns)
kubectl get pods -n strategy-lab --show-labels
# 更新两个 deployment 的镜像,对比滚动行为:
kubectl set image deployment/roll-web nginx=nginx:1.28 -n strategy-lab
kubectl set image deployment/recreate-web nginx=nginx:1.28 -n strategy-lab
kubectl get pods -n strategy-lab -w   # recreate:先全部 Terminating,再创建(服务中断)
```

### 实验 3:暂停、恢复、回滚

```bash
kubectl apply -f lab03-rollout.yaml
kubectl annotate deployment app kubernetes.io/change-cause="init 1.27" -n deploy-lab --overwrite

# 多次变更:先暂停 → 连续改两处 → 一次性恢复(避免触发多轮滚动)
kubectl rollout pause deployment app -n deploy-lab
kubectl set image deployment/app nginx=nginx:1.28 -n deploy-lab
kubectl set resources deployment/app -c nginx --limits=memory=256Mi -n deploy-lab
kubectl rollout resume deployment app -n deploy-lab

# 回滚演练
kubectl rollout history deployment/app -n deploy-lab
kubectl rollout undo deployment/app -n deploy-lab                  # 回上个版本
kubectl rollout undo deployment/app --to-revision=1 -n deploy-lab  # 回指定版本

# 重启所有 Pod(改配置/挂掉节点后常用,触发的是重启而非更新)
kubectl rollout restart deployment/app -n deploy-lab
```

### 缩放

```bash
kubectl scale deployment app --replicas=5 -n deploy-lab
# 自动扩缩容(HPA)见第 15 章
```

### 清理

```bash
kubectl delete ns deploy-lab strategy-lab
```

## 常见问题

| 问题 | 答案 |
|------|------|
| 滚动更新卡住一半? | `rollout status` 看卡点;多半新 Pod 起不来(镜像错/探针太严/资源不足) |
| 为什么改了 image 不更新? | 用了 `latest` + `imagePullPolicy: IfNotPresent`;固定 tag 才是正解 |
| 回滚能回"字段"吗? | 回滚的是整个 Pod 模板版本,不只是镜像 |

## 练习任务

1. [ ] 把 maxUnavailable 设为 0、maxSurge 设为 1,更新时用 `kubectl get pods -w` 验证容量无损
2. [ ] 人为写错镜像 tag,观察 `rollout status` 卡住,然后 `rollout undo` 恢复
3. [ ] 用 `kubectl get deployment app -n deploy-lab -o yaml` 找到 annotations 里的 rollback 记录

## 参考

- https://kubernetes.io/zh-cn/docs/concepts/workloads/controllers/deployment/
