# 04 Pod 详解(知识笔记)

> 约定:本文所有 YAML 示例均出自实验文件 `~/k8s-lab/04/manifests/lab01~lab07`,编号与章节对应,可边看笔记边打开对应文件对照。

## 一、Pod 的本质

### 1.1 最小调度单元与共享模型
- Pod 是 K8s 的**原子调度单位**:调度、创建、销毁、迁移都以 Pod 为整体,不会出现"一个 Pod 的容器分在两个节点"
- 同 Pod 内的容器共享三样东西:
  | 共享 | 机制 | 表现 |
  |------|------|------|
  | 网络 | 同一 network namespace | 同 IP、同端口空间,互访用 localhost |
  | 存储 | 挂载同一 Volume(如 emptyDir) | 一个写、一个读 |
  | 生命周期 | 同生共死 | 一起被创建、一起被终止 |
- 容器是**资源隔离**的边界,Pod 是**共享协作**的边界——两种边界用两层表达,这就是 Pod 存在的设计原因

### 1.2 最小 Pod 骨架(所有 Pod YAML 的模板)
```yaml
apiVersion: v1          # 核心组 v1(Pod 所在)
kind: Pod               # 对象类型
metadata:
  name: my-pod          # Pod 名,命名空间内唯一
  namespace: default    # 不写默认落 default
spec:
  containers:           # 必填,至少一个
    - name: app
      image: nginx:1.27
```
- 整个文件四段:apiVersion(到哪找 kind)/ kind(建什么)/ metadata(名字与标签)/ spec(期望状态)
- 裸 Pod 没有控制器字段(无 replicas):删了没人重建

### 1.3 Pod 的易逝性(核心心智)
- Pod 是"Cattle 不是 Pet":重建即换 IP、名字也会变(控制器管理的 Pod)
- 结论:业务代码**永远不要依赖 Pod IP/名字**,要依赖 Service/DNS(第 08 章)

## 二、Pod 对象结构(对照 lab01-pod-basic.yaml)

### 2.1 完整配置逐段注解
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: basic
  namespace: pod-lab            # 归属命名空间(不写=default)
  labels:
    app: basic                  # 标签:Service/调度的选择基础
spec:
  restartPolicy: Always         # Always|OnFailure|Never,默认 Always
  containers:
    - name: nginx               # 容器名,同 Pod 内唯一
      image: nginx:1.27         # 仓库/名称:tag(固定 tag 而非 latest)
      imagePullPolicy: IfNotPresent   # Always|IfNotPresent|Never
      ports:
        - name: http            # 端口命名,后续 targetPort 可按名引用
          containerPort: 80     # 声明性信息:不写也能访问
      env:
        - name: MESSAGE
          value: "hello k8s"    # 方式一:字面量
        - name: POD_NAME        # 方式二:Downward API(注入自身元数据)
          valueFrom:
            fieldRef: { fieldPath: metadata.name }
        - name: NODE_NAME
          valueFrom:
            fieldRef: { fieldPath: spec.nodeName }
```

### 2.2 关键字段要点
| 字段 | 要点 |
|------|------|
| metadata.labels | 写错 = Service 选不到 Pod = 后端全空(第 08 章头号坑) |
| restartPolicy | 见第三节生命周期 |
| imagePullPolicy | tag 为 `latest` 或缺失时**隐式 Always**;"改了镜像不更新"的坑源 |
| ports.name | 具名端口,便于 targetPort/service 按名引用 |
| env.valueFrom.fieldRef | Downward API 白名单:只能取 Pod 自身元数据,拿不到别的对象(那是 ConfigMap/Secret 的职责) |

## 三、Pod 生命周期

### 3.1 phase 与 conditions
| phase | 含义 |
|-------|------|
| Pending | 已接受,未调度完成或镜像未就绪 |
| Running | 至少一个容器在运行 |
| Succeeded | 所有容器成功退出(Job 型) |
| Failed | 有容器非零退出 |
| Unknown | apiserver 联系不上 kubelet |

- **PodConditions**(细节):PodScheduled / Initialized / ContainersReady / Ready
- phase 是"概要",conditions 是"可追溯原因",排错以 conditions + Events 为准

### 3.2 restartPolicy 三值(配置即语义)
```yaml
spec:
  restartPolicy: Always    # 常驻服务:任何退出都重启(默认)
  # restartPolicy: OnFailure  # 批处理:仅非零退出重启
  # restartPolicy: Never     # Job 等:永不重启
```
- Job 的模板**必须** Never 或 OnFailure(控制器自己负责重试)

### 3.3 状态流转
```
Pending → ContainerCreating → Running → Succeeded(全部成功退出)
                                  └→ 容器失败 + Always → 重启(退避)→ CrashLoopBackOff
```

### 3.4 常见异常状态速查(lab04 现场全见过)
| 状态 | 本质 | 排查入口 |
|------|------|----------|
| Pending | 调度失败:资源/亲和/污点/PVC | describe 尾部 Events |
| ImagePullBackOff | 镜像拉取失败 | describe Events + 镜像名/凭证/网络 |
| CrashLoopBackOff | 反复崩溃+指数退避(10s→20s→…→5min) | `logs --previous` |
| OOMKilled | 内存超 limits 被内核杀 | describe Last State + exitCode 137 |
| Evicted | 节点压力被驱逐 | describe Reason |

- **exitCode 137** = 128+9(SIGKILL):被系统杀死(OOM/驱逐/强杀),区别于应用自己 exit 1

## 四、容器协同模式

### 4.1 多容器共享数据(lab02-multi-container.yaml 注解)
```yaml
spec:
  volumes:
    - name: shared-logs
      emptyDir: {}                    # Pod 级卷:生命周期同 Pod
  containers:
    - name: log-writer                # 主容器:写日志进共享卷
      image: nginx:1.27
      volumeMounts:
        - { name: shared-logs, mountPath: /var/log/nginx }
    - name: log-reader                # 边车(sidecar):读共享卷转发到 stdout
      image: busybox:1.36
      command: ["sh", "-c", "while true; do cat /data/nginx/access.log 2>/dev/null | tail -3; sleep 2; done"]
      volumeMounts:
        - { name: shared-logs, mountPath: /data/nginx, readOnly: true }
```
- **卷的两种角色**:`spec.volumes` 定义卷(材料),`containers[].volumeMounts` 挂载(各容器按需挂)
- 同一卷可被多个容器以不同路径、不同权限(主读写/边车只读)挂载
- 设计模式:sidecar(日志采集/代理)/ adapter(格式转换)/ ambassador(外部连接代理)

### 4.2 initContainers(lab03-init-container.yaml 注解)
```yaml
spec:
  volumes:
    - name: workdir
      emptyDir: {}
  initContainers:                     # 主容器之前,严格串行
    - name: step1-download
      image: busybox:1.36
      command: ["sh", "-c", "echo 'data' > /work/index.html"]   # 准备数据
      volumeMounts: [ { name: workdir, mountPath: /work } ]
    - name: step2-wait-db             # 模拟等待依赖就绪
      image: busybox:1.36
      command: ["sh", "-c", "echo waiting; sleep 10"]
  containers:                         # 全部 init 成功后才会创建
    - name: nginx
      image: nginx:1.27
      volumeMounts: [ { name: workdir, mountPath: /usr/share/nginx/html } ]  # 继承 init 成果
```
- **机制要点**:
  - 严格按 YAML 顺序;step1 成功(exit 0)才跑 step2
  - 失败:Pod 按 restartPolicy 重启,**只重跑失败的那个**,已成功的不重复
  - 状态显示:`Init:0/2 → Init:1/2 → PodInitializing → Running`
  - 共享网络与卷;独立镜像/命令;不支持探针(目标是跑完退出)
- 与 postStart 的本质区别:init **串行且保证完成**;postStart 异步不保证(见第六节)
- 用途:准备数据/文件(下载、渲染、生成证书)、等待依赖就绪(循环 nslookup/curl)
- K8s 1.28+:initContainers 配 `restartPolicy: Always` 即"原生 sidecar"(先启动且长期存活)

## 五、探针(lab04-probes.yaml 全解)

### 5.1 三种探针职责
| 探针 | 问的问题 | 失败后果 |
|------|----------|----------|
| livenessProbe | 还活着吗 | 杀容器重启(restartCount++) |
| readinessProbe | 能接客吗 | 从 Service 后端摘除,不重启 |
| startupProbe | 启动完了吗 | 期间屏蔽前两者;超限重启 |

- 执行者:节点上的 **kubelet**,直接探测容器 IP,不经过 Service/DNS

### 5.2 配置逐字段注解(healthy-pod)
```yaml
spec:
  containers:
    - name: nginx
      image: nginx:1.27
      readinessProbe:                       # 管"流量"
        httpGet: { path: /, port: 80 }      # 检查方式:HTTP GET
        initialDelaySeconds: 3              # 启动 3s 后首次探测
        periodSeconds: 5                    # 每 5s 一次
      livenessProbe:                        # 管"生死"
        httpGet: { path: /, port: 80 }
        initialDelaySeconds: 5
        periodSeconds: 10
        failureThreshold: 3                 # 连续失败 3 次才判死(≈30s)
```
**时间线**:t=3s readiness 首探 → t=5s liveness 首探 → 之后每 10s 一次;连续 3 次失败(最坏 ~30s)重启。设计意图:readiness 先于 liveness 确认"能服务",liveness 故意宽容(偶发 GC 不误杀)。

### 5.3 四种检查方式
| 方式 | 判定 | 测不出 |
|------|------|--------|
| httpGet | 2xx/3xx=成功,4xx/5xx=失败 | 业务健康(除非有专门端点) |
| exec | 容器内命令 exit 0=成功 | 过重命令拖垮应用 |
| tcpSocket | TCP 握手成功 | 进程僵死但端口监听 |
| grpc | 标准 gRPC 健康协议 | 非 gRPC 应用 |

### 5.4 参数五件套
| 参数 | 含义 | 默认 |
|------|------|------|
| initialDelaySeconds | 启动后等待多久首探 | 0 |
| periodSeconds | 探测间隔 | 10 |
| timeoutSeconds | 单次超时(超时算失败) | 1 |
| failureThreshold | **连续**失败 N 次判失败(中途成功清零重计) | 3 |
| successThreshold | 恢复需连续成功 N 次(liveness/startup 强制 1) | 1 |

- **判死时长公式**:`periodSeconds × failureThreshold`

### 5.5 故障组(broken-pod)的崩溃推演
```yaml
      livenessProbe:
        httpGet: { path: /, port: 81 }   # 错误端口,注定失败
        periodSeconds: 5
        failureThreshold: 2
```
```
t≈5s 第1次失败 → t≈10s 第2次连续失败 → kubelet 杀容器(SIGKILL,exit 137)
→ restartPolicy Always 重启 → 又失败 → RESTARTS++
→ 进入 CrashLoopBackOff(退避 10s→20s→40s→…封顶5min)
```
- 标准排错三连:describe 看 Liveness 事件与 exitCode / `logs --previous` / `get -w` 看 RESTARTS

### 5.6 startupProbe 的门闩机制(slow-start-pod)
```yaml
      startupProbe:                        # 启动预算 = period×threshold
        httpGet: { path: /, port: 80 }
        periodSeconds: 3
        failureThreshold: 30               # 容忍 90s 启动
      livenessProbe:
        httpGet: { path: /, port: 80 }
        periodSeconds: 10
```
```
启动 → startup 开始探测
  ├─ 未成功期间:liveness/readiness 完全屏蔽
  ├─ 预算内成功一次 → startup 永久退场,其余接管
  └─ 预算耗尽仍失败 → 杀容器重来
```
- 解决慢启动(Java/推理服务):替代"给 liveness 设巨大 initialDelay"的固定等待写法

### 5.7 探针与 Service 联动(摘流机制)
```
readiness 连续失败 → Pod Ready=False → EndpointSlice 摘除该 Pod IP
→ kube-proxy 更新规则 → 流量不再进入 → 恢复后重新加回
```
- 容器全程不重启——"摘流"与"重启"是两种失败处理,必须分开声明
- 设计原则:liveness 不得依赖外部服务(DB 抖→全量重启风暴);readiness 可以依赖;慢启动加 startup

## 六、生命周期钩子(lab05-lifecycle.yaml 全解)

### 6.1 配置逐字段注解
```yaml
spec:
  terminationGracePeriodSeconds: 30     # 优雅退出总预算(默认 30s,含 preStop)
  containers:
    - name: busybox
      command: ["sh", "-c", "echo 'main started'; sleep 3600"]
      lifecycle:
        postStart:                      # 容器创建后立即执行
          exec:
            command: ["sh", "-c", "echo 'postStart run' >> /tmp/hook.log"]
        preStop:                        # 收到终止指令后、SIGTERM 前执行
          exec:
            command: ["sh", "-c", "echo 'draining...' >> /tmp/hook.log; sleep 5"]
```

### 6.2 postStart 四特性
- **异步**:与主进程 ENTRYPOINT 并行,**不保证先完成**——准备主程序启动就要用的文件应交给 init 容器
- **失败后果**:postStart 失败 → 容器被杀并 restartPolicy 重启
- 不被保证:容器早死则钩子可能未执行完
- 典型:建目录、设权限、写配置、预热缓存

### 6.3 preStop 与终止预算
- **同步**:kubelet 等 preStop 跑完才发 SIGTERM
- **占用预算**:preStop 时间从 terminationGracePeriodSeconds 里扣;超预算 → 直接 SIGKILL
- 失败不阻止终止(只给机会,不保证成功)
- 完整时序:
```
删除请求 → deletionTimestamp(预算倒计时)
  → preStop 执行 → SIGTERM → 应用收尾 → 到期未死 → SIGKILL
```

### 6.4 优雅下线经典问题(preStop sleep 的意义)
```
删除时若立即 SIGTERM:规则更新有传播延迟 → 新流量仍打进来 → 502
preStop sleep 数秒:给"摘流量"(Endpoints/iptables 更新)留窗口 → 进程再死无新流量
```
- 生产姿势:**preStop sleep + 应用处理 SIGTERM 优雅收尾**;应用收尾慢调大 grace,不硬砍 sleep
- preStop 触发场景不止 delete:滚动更新、节点驱逐、liveness 判死都会走同一套终止流程

## 七、requests/limits 与 QoS(lab06 三 Pod 对照)

### 7.1 完整配置对照(判定规则的直接素材)
```yaml
# guaranteed-pod:requests == limits(cpu 与内存全部相等)
resources:
  requests: { cpu: 100m, memory: 128Mi }
  limits:   { cpu: 100m, memory: 128Mi }
```
```yaml
# burstable-pod:有 requests,limits 更大 → 可突发
resources:
  requests: { cpu: 50m, memory: 64Mi }
  limits:   { cpu: 200m, memory: 256Mi }
```
```yaml
# besteffort-pod:什么都不写
# (无 resources 块)
```
- 查看等级:`kubectl get pods -n pod-lab -o custom-columns='NAME:.metadata.name,QOS:.status.qosClass'`

### 7.2 两套系统(调度承诺 vs 运行上限)
| | requests(预留) | limits(上限) |
|---|----------------|--------------|
| 服务对象 | scheduler | kubelet/运行时(cgroup) |
| 语义 | 至少需要这么多 | 最多允许这么多 |
| 后果 | 放不下就不调度(Pending) | CPU 超限节流;内存超限 OOM |

### 7.3 可压缩与不可压缩资源
| | CPU | 内存 |
|---|-----|------|
| 超限后果 | 节流(变慢,不杀) | OOMKilled(杀) |
| 原因 | 时间片可让出可补回 | 内存无法暂缓,只能杀 |
| 结论 | CPU limits 配错=慢 | 内存 limits 配错=死(红线) |

### 7.4 QoS 三等级判定规则
```
① 所有容器 requests==limits(cpu 与内存全部相等)→ Guaranteed
② 有 requests 但任一维度不相等/缺失            → Burstable
③ 没有任何容器写 requests/limits               → BestEffort
```
- 判据严格:**任一容器、任一维度**不满足即降级
- Guaranteed = 锁死资源(最可预测,不能突发);Burstable = 低保+可突发(生产最常见);BestEffort = 无承诺

### 7.5 QoS 决定"死亡顺位"
| 场景 | 顺序 |
|------|------|
| 节点内存压力驱逐 | BestEffort → Burstable → Guaranteed |
| 内核 OOM 打分(oom_score_adj) | BestEffort 最高分最先杀,Guaranteed 最低分最后杀 |

### 7.6 单位体系
- CPU:`1000m = 1 核`;内存:`1Mi = 2^20 字节`,`1Gi = 2^30`(区别于 MB/GB 的 10^6/10^9)

## 八、安全上下文(lab07-securitycontext.yaml 全解)

### 8.1 完整配置逐字段注解
```yaml
spec:
  securityContext:              # Pod 级:对所有容器生效
    runAsUser: 1000             # 进程 uid 换成非 root
    runAsGroup: 3000            # 进程主组 gid
    fsGroup: 2000               # 挂载卷属组递归设为 2000,并加入进程补充组
  containers:
    - name: app
      image: busybox:1.36
      command: ["sh", "-c", "id; sleep 3600"]
      securityContext:          # 容器级:覆盖 Pod 级同名设置
        allowPrivilegeEscalation: false   # 禁 setuid/setgid 提权
        capabilities:
          drop: ["ALL"]         # 清空全部 Linux 特权位
      volumeMounts:
        - { name: tmp, mountPath: /tmp }  # 可写目录(配合只读根文件系统)
  volumes:
    - name: tmp
      emptyDir: {}              # /tmp 落在内存盘
```

### 8.2 为什么需要
- 默认容器进程以 **root(uid 0)** 运行——被攻破后配合挂载卷/内核漏洞可逃逸到宿主机
- securityContext = 两级声明(Pod 级默认 + 容器级覆盖)

### 8.3 身份三件套机制
| 字段 | 机制 | 解决的问题 |
|------|------|-----------|
| runAsUser | 进程 uid 换非 root | root 拥有全部内核权限,普通用户缩小破坏面 |
| runAsGroup | 进程主组 gid | 与文件权限位配合 |
| fsGroup | **挂载卷属组递归设为此 gid + 加入补充组** | 非 root 写不了属主 root 的卷——fsGroup 打通写权限 |

### 8.4 权限两件套机制
| 字段 | 机制 |
|------|------|
| allowPrivilegeEscalation: false | 禁止 setuid/setgid 提权(镜像里 sudo/ping 等 setuid 程序失效) |
| capabilities.drop: ["ALL"] | 清空全部特权位,进程几乎零特权 |

### 8.5 Linux capabilities 背景
- Linux 把 root 的超级权限拆成约 40 个能力位:NET_BIND_SERVICE(绑 <1024 端口)、SETUID、NET_ADMIN、SYS_ADMIN(挂载/namespace,逃逸路径)、SYS_PTRACE…
- 容器运行时默认发约 14 个;`drop: ["ALL"]` 全清,需要再加(add)
- **连带效果**:清空后绑不了 80 → 实验用 busybox 而非 nginx;现实给 nginx `add: [NET_BIND_SERVICE]` 或镜像支持非 root

### 8.6 只读根文件系统与可写目录
- `readOnlyRootFilesystem: true` 时根目录全只读;需要写的地方(如 /tmp)用 emptyDir 挂载兜底
- 组合 = "只读系统 + 白名单可写点"的最小可写面

### 8.7 与 PSA 的关系
- 手工配齐 runAsNonRoot + 去 capabilities + 只读根 + seccomp ≈ restricted 级别
- 第 14 章 PSA 把整套做成 namespace 准入模板:贴标签强制,不合规拒绝 apply

## 九、Pod 排错动作(实验沉淀的标准姿势)

```bash
kubectl describe pod <名> -n <ns>       # ① Events + 退出码(第一现场)
kubectl logs <名> -n <ns> --previous    # ② 崩溃前日志(第二现场)
kubectl get pods -n <ns> -w             # ③ 动态观察 RESTARTS/状态流转
kubectl get pod <名> -n <ns> -o yaml    # ④ 完整对象(status 细节)
```
- 顺序:Events → 上世日志 → 当前日志 → 完整 yaml;对照 3.4 状态速查表定位类别后对症处理
