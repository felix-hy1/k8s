# 第 07 章 DaemonSet、Job 与 CronJob(特种工作负载)

> 📁 本章实验资源(yaml / 脚本 / sql)位于 `D:\k8s\07-DaemonSet-Job-CronJob\`,本文档位于 `D:\k8s\mds\`。

## 学习目标

1. 理解三种"特种"工作负载的适用场景
2. 掌握 Job 的并行度、失败重试与清理策略
3. 会写 CronJob 定时任务并理解其并发策略

## 7.1 三者定位

| 类型 | 语义 | 典型场景 |
|------|------|----------|
| DaemonSet | **每个节点跑一个**(有节点加入自动铺开) | 日志采集、监控 Agent、网络插件(kube-proxy 就是 DS) |
| Job | **跑完即退**的一次性任务 | 数据批处理、离线计算、数据迁移 |
| CronJob | **按 cron 表达式周期性创建 Job** | 定时备份、报表、清理 |

### Job 关键参数

| 参数 | 含义 |
|------|------|
| completions | 最终要成功完成几个 Pod(默认 1) |
| parallelism | 同时并行几个 Pod(默认 1) |
| backoffLimit | 累计失败重试上限,超过则 Job 标记 Failed(默认 6) |
| activeDeadlineSeconds | 任务总时长上限,超时强杀 |
| ttlSecondsAfterFinished | 完成后多久自动清理 Job 对象(推荐设置,避免垃圾堆积) |

注意:Job 的 Pod 模板必须显式 `restartPolicy: Never` 或 `OnFailure`(不能是 Always)。

### CronJob 关键字段

- `schedule`:5 段 cron(分 时 日 月 周),**集群时区**(kind 默认 UTC,输出时间差 8 小时不要慌)
- `concurrencyPolicy`:`Allow`(默认)/ `Forbid`(上轮没跑完就不开新的)/ `Replace`(杀掉旧的换新的)
- `startingDeadlineSeconds`:错过调度窗口多久就算失败

---

## 实验列表

### 实验 1:DaemonSet 节点守护进程

```bash
cd /mnt/d/k8s/07-DaemonSet-Job-CronJob/manifests
kubectl apply -f lab01-daemonset.yaml
kubectl get pods -n ds-lab -o wide       # 3 个节点各一个,包括控制面(靠 tolerations)
# 每个节点写入 hostPath 日志,验证:
docker exec k8s-learning-worker cat /tmp/node-heartbeat.log | tail -3
```

> 关键点:控制面节点默认带污点 `node-role.kubernetes.io/control-plane:NoSchedule`,
> DaemonSet 想在控制面运行必须加 tolerations(见清单注释)。

### 实验 2:一次性 Job

```bash
kubectl apply -f lab02-job-basic.yaml
kubectl get jobs -n ds-lab
kubectl logs -n ds-lab job/pi -c pi        # 输出 2000 位圆周率
kubectl get pods -n ds-lab                 # 状态 Completed,不会重启
```

### 实验 3:并行与失败重试

```bash
kubectl apply -f lab03-job-parallel.yaml
kubectl get pods -n ds-lab -w     # 观察并行 2 个一批,共完成 6 个

# 失败重试:bad-job 故意 exit 1,看 backoffLimit 生效
kubectl get job bad-job -n ds-lab -o jsonpath='{.status.failed}{"\n"}'
kubectl describe job bad-job -n ds-lab | tail -5    # Events 显示重试记录
```

### 实验 4:CronJob 定时任务

```bash
kubectl apply -f lab04-cronjob.yaml
kubectl get cronjob -n ds-lab
kubectl get jobs -n ds-lab -w         # 每分钟生成一个 Job(UTC 时间)
kubectl logs -n ds-lab $(kubectl get pods -n ds-lab -l job-name=heartbeat-28600000 -o name | head -1) 2>/dev/null || \
kubectl get pods -n ds-lab --sort-by=.metadata.creationTimestamp | tail -3
# 停止:
kubectl patch cronjob heartbeat -n ds-lab -p '{"spec":{"suspend":true}}'
```

### 清理

```bash
kubectl delete ns ds-lab
```

## 常见问题

| 问题 | 答案 |
|------|------|
| Job 的 Pod 一直不退出? | 程序没结束;用 activeDeadlineSeconds 兜底 |
| CronJob 时间不对? | 集群是 UTC;可设置 `timeZone: Asia/Shanghai`(1.27+ 支持) |
| DaemonSet 怎么滚动更新? | 和 Deployment 类似的 RollingUpdate,默认先杀旧的再铺新的 |
| Completed Pod 堆积? | Job 设置 ttlSecondsAfterFinished 自动回收 |

## 练习任务

1. [ ] 写一个 CronJob:每天凌晨 2 点(北京时间)跑一个 busybox,echo 日期到日志
2. [ ] 把实验 3 的 parallelism 改成 6,观察创建速度变化
3. [ ] `kubectl explain job.spec` 逐条阅读参数

## 参考

- https://kubernetes.io/zh-cn/docs/concepts/workloads/controllers/daemonset/
- https://kubernetes.io/zh-cn/docs/concepts/workloads/controllers/job/
