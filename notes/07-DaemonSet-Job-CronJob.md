# 07 DaemonSet、Job 与 CronJob(知识笔记)

> 约定:YAML 示例出自 `~/k8s-lab/07-DaemonSet-Job-CronJob/manifests/lab01~lab04`,编号与章节对应。

## 一、特种工作负载总览

### 1.1 三种工作负载的定位
| 类型 | 语义 | 创建者 | 典型场景 |
|------|------|--------|----------|
| DaemonSet | **每个节点恰好一个** | 节点加入自动铺开 | 日志采集、监控 Agent、网络插件 |
| Job | **跑完即退**的一次性任务 | 人工/其他控制器触发 | 批处理、数据迁移、离线计算 |
| CronJob | 按 cron 表达式**周期性创建 Job** | 定时触发 | 备份、报表、清理、心跳 |

### 1.2 与第 05 章的统一视角
- 所有工作负载控制器(Deployment/StatefulSet/DaemonSet/Job/CronJob)都是第 02 章"控制器模式"的具体实现:**list-watch 自己关心的对象 → 对比期望与实际 → 调谐**
- 差别只在"期望状态"的定义方式:
  - Deployment:期望 replicas 个副本(随机身份)
  - StatefulSet:期望 N 个有序副本(稳定身份)
  - DaemonSet:期望"每个节点一个"(拓扑驱动)
  - Job:期望"累计成功 completions 个"(终态驱动)
  - CronJob:期望"每到 cron 时间点就创建一个 Job"(时间驱动)

## 二、DaemonSet(lab01 全解)

### 2.0 配置全文(带注解)
```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-heartbeat
  namespace: ds-lab
  labels: { app: node-heartbeat }
spec:
  selector:
    matchLabels: { app: node-heartbeat }
  template:
    metadata:
      labels: { app: node-heartbeat }
    spec:
      tolerations:                     # 控制面污点的豁免凭证
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
        - key: node-role.kubernetes.io/master
          operator: Exists
          effect: NoSchedule
      containers:
        - name: heartbeat
          image: busybox:1.36
          command: ["sh", "-c", "while true; do echo \"$(hostname) $(date)\" >> /var/heartbeat/node-heartbeat.log; sleep 10; done"]
          resources:
            requests: { cpu: 10m, memory: 16Mi }
            limits: { cpu: 50m, memory: 32Mi }
          volumeMounts:
            - name: heartbeat-dir
              mountPath: /var/heartbeat
      volumes:
        - name: heartbeat-dir
          hostPath:                    # 直接写节点文件系统
            path: /tmp
            type: DirectoryOrCreate
```

### 2.1 与 Deployment 的结构差异
- **没有 replicas 字段**:副本数不由你指定,由"集群里有多少节点"决定
- 也没有 maxSurge/maxUnavailable(更新策略不同,见 2.5)
- selector + template 结构与 Deployment 相同,selector 创建后同样不可变

### 2.2 调度机制(核心特性)
- DaemonSet 控制器 watch **节点列表**,为**每个节点**创建一个 Pod
- 节点新增 → 自动铺开新 Pod;节点删除 → 自动回收该 Pod
- Pod 的调度不由 scheduler 决定,由 DaemonSet 控制器直接指定 nodeName(绕开调度器)
- 验证:本实验 3 节点集群 → 3 个 `node-heartbeat` Pod,每个节点一个

### 2.3 控制面污点与 tolerations(关键知识)
- 控制面节点默认带污点 `node-role.kubernetes.io/control-plane:NoSchedule`,普通 Pod 不会被调度上去(第 12 章详讲)
- 想让 DaemonSet 也覆盖控制面,必须在 template 里写 **tolerations(容忍)**
- 本实验两个容忍段的意义:
  ```yaml
  - key: node-role.kubernetes.io/control-plane   # 新版污点名
    operator: Exists        # Exists = 不关心 value 是什么,只要 key 存在
    effect: NoSchedule
  - key: node-role.kubernetes.io/master           # 旧版本污点名,兼容保留
    operator: Exists
    effect: NoSchedule
  ```
- 等价理解:"这两条污点我豁免,允许把我调度到控制面节点"
- 生产参考:kube-proxy、flannel 等系统级 DaemonSet 都带类似容忍,才能覆盖所有节点

### 2.4 hostPath 卷(访问节点文件系统)
```yaml
      volumes:
        - name: heartbeat-dir
          hostPath:
            path: /tmp                    # 节点(节点容器)上的路径
            type: DirectoryOrCreate       # 不存在则创建
```
- hostPath = 直接挂节点目录,绕过 Pod 的文件系统隔离
- 语义:所有节点上的 DaemonSet Pod 都能读写同一个"节点本地路径"(每节点各自一份)
- 用途:日志采集(读 /var/log)、监控(读 /proc)、配置下发(写 /etc)
- **风险**:生产慎用——Pod 能写宿主目录 = 逃逸面扩大;且调度到别的节点时路径含义随节点变化

### 2.5 更新策略
| 策略 | 行为 | 适用 |
|------|------|------|
| RollingUpdate(默认) | 逐个更新:先删旧再建新(每节点) | 无状态 Agent |
| OnDelete | 只在手动删除 Pod 后才重建新模板 | 需要人工确认的节点级变更 |

- 与 Deployment 不同:DaemonSet 滚动更新是"**先删旧的再建新的**"(节点上不能新旧并存,因为很多节点级资源不允许多实例),没有 maxSurge

### 2.6 典型场景
| 场景 | 为什么用 DaemonSet |
|------|---------------------|
| 日志采集(fluentd/filebeat) | 每节点一个,采集节点上所有 Pod 的日志 |
| 监控 Agent(node-exporter) | 每节点一个,暴露节点指标 |
| 网络插件(calico/flannel) | 每节点一个,配置节点网络 |
| kube-proxy(系统自带) | 每节点一个,维护 iptables 规则 |

## 三、Job(lab02/lab03 全解)

### 3.0 lab02 配置(基础形态)
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: pi
  namespace: ds-lab
spec:
  template:
    metadata: { labels: { job: pi } }
    spec:
      restartPolicy: Never              # Job 必须 Never/OnFailure
      containers:
        - name: pi
          image: perl:5.40-slim
          command: ["perl", "-Mbignum=bpi", "-wle", "print bpi(2000)"]
```

### 3.1 语义:跑完即退
- 与 Deployment(常驻)相反,Job 的目标是**让所有 Pod 成功退出**
- 成功退出(exit 0)→ Pod Succeeded → Job 计数 +1
- 全部完成后 Job 状态 Complete,Pod 不再重启、不再补建

### 3.2 restartPolicy 约束
- Job 的 Pod 模板**必须** `Never` 或 `OnFailure`(控制器自己负责重试,不需要 kubelet 重启)
- 两者重试主体不同:
  | restartPolicy | 失败后谁重试 | 机制 |
  |---------------|-------------|------|
  | OnFailure | kubelet | 同一容器原地重启 |
  | Never | Job 控制器 | 创建新 Pod,旧 Pod 保留为 Failed 记录 |

### 3.3 Job 的三种形态
| 形态 | 配置 | 行为 |
|------|------|------|
| 非并行 | 都不设(=1) | 一个 Pod 跑完算完成 |
| **固定完成数** | completions=N, parallelism=M | 总共成功 N 个,同时最多 M 个 |
| 工作队列 | 都不设 + 外部队列 | 谁空闲谁领任务,Pod 数动态 |

### 3.4 lab03 并行 Job(核心参数)
```yaml
spec:
  completions: 6          # 总共需要成功 6 个 Pod
  parallelism: 2          # 同时最多运行 2 个
  backoffLimit: 4         # 失败累计上限
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: work
          image: busybox:1.36
          command: ["sh", "-c", "echo task-${JOB_COMPLETION_INDEX} done; sleep 5"]
          env:
            - name: JOB_COMPLETION_INDEX
              valueFrom:
                fieldRef:
                  fieldPath: metadata.annotations['batch.kubernetes.io/job-completion-index']
```
- 运行形态:控制器保持并发数=parallelism,完成一个补一个,直到 completions 全部成功

### 3.5 JOB_COMPLETION_INDEX(数据分片的钥匙)
- Job 控制器给每个 Pod 打 0..N-1 的序号,存于 annotation
- 通过 Downward API(fieldRef)注入环境变量
- 用途:每个 Pod 按编号处理自己的数据分片(ETL 按文件、迁移按表、渲染按批次)

### 3.6 失败重试机制(lab03 bad-job)
```yaml
spec:
  backoffLimit: 3              # 累计失败 3 次后 Job 标记 Failed
  activeDeadlineSeconds: 120   # 整个 Job 总运行时长上限
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: fail
          image: busybox:1.36
          command: ["sh", "-c", "echo 'I will fail'; exit 1"]
```
| 参数 | 限制维度 | 超了怎样 |
|------|----------|----------|
| backoffLimit | 失败次数(默认 6) | Job 标记 Failed,停止重试 |
| activeDeadlineSeconds | 总墙钟时长 | Job 标记 Failed,终止运行中的 Pod |

- 失败重试之间有**指数退避**(10s→20s→40s...),防风暴
- Never 模式下 backoffLimit 数的是"失败 Pod 数",失败 Pod 保留为记录(可逐个看日志)
- 双保险设计:任务既不成功也不失败(卡死)时,时间预算兜底

### 3.7 ttlSecondsAfterFinished(垃圾回收)
```yaml
spec:
  ttlSecondsAfterFinished: 120    # 完成后 120s 自动删除 Job 及其 Pod
```
- Job 完成(Complete 或 Failed)后,到点自动清理,避免堆积
- 生产建议必配;不配则 Job 对象永久保留

## 四、CronJob(lab04 全解)

### 4.0 配置全文(带注解)
```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: heartbeat
  namespace: ds-lab
spec:
  schedule: "*/1 * * * *"        # cron 表达式:每分钟
  # timeZone: "Asia/Shanghai"    # v1.27+:显式指定时区
  concurrencyPolicy: Forbid      # 上一轮没跑完则跳过本轮
  successfulJobsHistoryLimit: 3  # 保留 3 个成功 Job
  failedJobsHistoryLimit: 1      # 保留 1 个失败 Job
  jobTemplate:
    spec:
      ttlSecondsAfterFinished: 300
      template:
        spec:
          restartPolicy: Never
          containers:
            - name: heartbeat
              image: busybox:1.36
              command: ["sh", "-c", "date; echo 'heartbeat tick'"]
```

### 4.1 三层嵌套结构(核心心智)
```
CronJob                     ← 定时器:到点"开一次工"
  └── Job(每轮新建)          ← 模板实例化产物(3.4 的知识全部适用)
        └── Pod              ← Job 再创建 Pod
```
- `jobTemplate` = Job 的定义模板,CronJob 每轮按它创建新 Job
- `jobTemplate.spec` = Job 的 spec(可写 completions/parallelism/backoffLimit...)
- `jobTemplate.spec.template` = Pod 模板
- 新 Job 命名:`<cronjob名>-<调度时间戳>`

### 4.2 schedule:cron 表达式
```
* * * * *
│ │ │ │ └── 星期(0-6,0=周日)
│ │ │ └──── 月(1-12)
│ │ └────── 日(1-31)
│ └──────── 时(0-23)
└────────── 分(0-59)
```
- **没有秒字段**;`*/1 * * * *` = 每分钟(步长写法)
- 常见:`*/5` 每5分;`0 2 * * *` 每天2点;`0 0 * * 1-5` 工作日零点

### 4.3 timeZone 与时区陷阱
- 默认按**集群时区**(kind=UTC)计算,与北京时间差 8 小时
- v1.27+ 支持 `timeZone: "Asia/Shanghai"` 显式指定
- 生产教训:跨时区团队部署定时任务不指定时区,"凌晨备份"可能变成"上午备份"

### 4.4 concurrencyPolicy(并发策略)
| 策略 | 行为 | 适用 |
|------|------|------|
| Allow(默认) | 允许叠加运行 | 可并发任务 |
| Forbid | 上一轮 Job 未 Complete 则跳过本轮 | 心跳/唯一性任务(本实验) |
| Replace | 杀掉上一轮,开新的 | 只想要最新结果 |

- 判定依据:上一轮创建的 **Job 是否完成**,而非调度时刻是否在跑

### 4.5 历史保留(HistoryLimit)
- `successfulJobsHistoryLimit` / `failedJobsHistoryLimit`:保留最近 N 个 Job
- 意义:查历史轮次日志(`kubectl logs job/<名>`);超限自动删除
- 生产建议:成功保留 1-3,失败多留

### 4.6 suspend(暂停开关)
- `spec.suspend: true`:停止触发(已排程的下一轮也不执行),Job 定时器冻结
- 运维场景:维护窗口、事故熔断
- 观察:`kubectl get cronjob` 的 SCHEDULE 列显示 Suspended

## 五、三个控制器的调谐对照

| 控制器 | watch 什么 | 期望状态 | 调谐动作 |
|--------|-----------|----------|----------|
| DaemonSet | 节点 + 自己的 Pod | 每节点一个 | 节点增删时创建/回收 Pod |
| Job | 自己的 Pod | 累计成功 = completions | 失败重试、成功计数、超限放弃 |
| CronJob | 时间 + 自己的 Job | 每轮恰好一个 Job | 到点创建、并发控制、历史清理 |

- 三者互不越权:Job 不管节点、DaemonSet 不管完成数、CronJob 不管 Pod
- 观察状态:`kubectl get ds/job/cronjob -o yaml` 的 status 字段各自记录期望 vs 实际
