# 05 Deployment 与 ReplicaSet(知识笔记)

> 约定:YAML 示例出自 `~/k8s-lab/05-Deployment与ReplicaSet/manifests/lab01~lab03`,编号与章节对应。

## 一、Deployment 的定位

### 1.1 解决什么问题(无状态工作负载的标准控制器)
裸 Pod(第 04 章 lab01)有三个致命缺陷,Deployment 逐一解决:

| 裸 Pod 的缺陷 | Deployment 的机制 |
|--------------|-------------------|
| 删了没人重建 | 控制器持续调谐:少于期望副本数就补 |
| 节点挂了不迁移 | 控制器在别的节点重建 |
| 升级要人肉操作 | 滚动更新 + 一键回滚 |

- Deployment 面向**无状态**应用:每个副本等价、无身份、数据不进 Pod(数据放 PVC/外部存储,第 11 章)
- 有状态应用用 StatefulSet(第 06 章),批处理用 Job(第 07 章)——同一套"控制器"思想的不同变体

### 1.2 三层关系(必须刻进脑子)
```
Deployment(版本管理与发布策略)
   └── ReplicaSet × N(每个版本一个 RS,管副本数)
          └── Pod × M(真正跑容器)
```
- Deployment 不管 Pod,只管"哪个版本的模板 + 用哪个 RS 实现它"
- ReplicaSet 不管版本,只管"我要的副本数够不够"
- Pod 归 RS 管(ownerReferences 指向 RS,第 03 章见过 `shop-568c68d7b7-4t98c` 的 ownerRef)
- 所以 Deployment 是"门面",RS 是"执行者",Pod 是"工人"

### 1.3 为什么不直接用 ReplicaSet
- RS 只能保证副本数,不能做版本演进:想换镜像,RS 只能原地改模板——改了之后所有 Pod 是同一个模板,回滚无从谈起
- Deployment 在 RS 之上加了两层能力:**版本化**(每个模板哈希对应一个 RS)+ **发布策略**(滚动/重建/暂停/回滚)
- 生产实践中 RS 只作为 Deployment 的内部实现出现,不直接创建

## 二、Deployment 对象结构(lab01-rolling.yaml 全解)

### 2.0 配置全文(带注解)
```yaml
apiVersion: apps/v1                     # Deployment 在 apps 组
kind: Deployment
metadata:
  name: web
  namespace: deploy-lab
  labels:
    app: web                            # Deployment 对象自身的标签(不是 Pod 的)
spec:
  replicas: 3                           # 期望副本数
  revisionHistoryLimit: 5               # 保留 5 个历史版本(旧 RS)
  selector:
    matchLabels:
      app: web                          # 认领自己的 Pod
  strategy:
    type: RollingUpdate                 # 发布策略:滚动更新(默认)
    rollingUpdate:
      maxSurge: 1                       # 滚动期间最多多出 1 个 Pod
      maxUnavailable: 1                 # 滚动期间最多不可用 1 个
  template:
    metadata:
      labels:
        app: web                        # Pod 标签,必须与 selector 匹配
    spec:
      containers:
        - name: nginx
          image: nginx:1.27             # 改这行 = 触发滚动更新
          ports: [ { containerPort: 80 } ]
          readinessProbe:               # 关键:新 Pod 就绪才算"发布成功"
            httpGet: { path: /, port: 80 }
            initialDelaySeconds: 2
            periodSeconds: 3
          resources:
            requests: { cpu: 50m, memory: 64Mi }
            limits: { cpu: 100m, memory: 128Mi }
```

### 2.1 spec 四要素
| 字段 | 作用 | 变更后果 |
|------|------|----------|
| replicas | 期望副本数 | 只扩缩容,不滚动 |
| selector.matchLabels | 认领 Pod 的标签 | **创建后不可改**(改了部署直接拒绝) |
| template | Pod 模板(模具) | **改 template = 触发滚动更新** |
| strategy | 发布策略与参数 | 只影响"怎么换",不影响内容 |

- 一句话记忆:**replicas 管数量,selector 管归属,template 管内容,strategy 管过程**
- 只有 template 变化才产生新 RS;replicas/strategy 变化不滚动

### 2.2 selector 与标签三件套(易混点)
| 位置 | 标签 | 作用 |
|------|------|------|
| metadata.labels | app: web | 给 Deployment 对象打标,`kubectl get deploy -l app=web` 筛选用 |
| spec.selector.matchLabels | app: web | Deployment 认领 Pod 的依据,一旦创建不可变 |
| template.metadata.labels | app: web | 新 Pod 出厂标签,必须与 selector 匹配 |

- 三条铁律:
  1. selector 必须写,且必须匹配 template 标签,否则 Deployment 拒绝创建
  2. selector 创建后**不可修改**(K8s 会直接拒绝,防止"改认领导致 Pod 失管")
  3. template 标签与 selector 不符 → 新 Pod 不归它管,造成"孤儿 Pod"

### 2.3 revisionHistoryLimit
- 保留多少个旧版本的 RS(每个版本一个 RS,缩到 0 副本也保留对象)
- 默认 10;保留的意义:回滚到任意历史版本;代价:etcd 里多存对象
- 调小(如 3)可省 etcd 空间,但只能回滚最近 3 个版本

## 三、ReplicaSet 机制

### 3.1 RS 的调谐职责
- 只做一件事:让**带自己标签**的 Pod 数量等于 spec.replicas
- 实现:RS 控制器 list-watch 自己名下的 Pod → 少了创建、多了删除
- 创建 Pod 时用 `generateName: <rs名>-` 前缀,apiserver 补随机后缀(第 03 章命名规律的机制来源)

### 3.2 pod-template-hash(RS 的指纹)
- RS 创建时,系统给 template 的 labels 打上 `pod-template-hash: <哈希>`,这个哈希由**模板内容**计算而来
- 同一模板永远同哈希 → 同哈希的 Pod 归同一 RS;模板一变哈希就变 → 自然产生新 RS
- 哈希让"版本"有了可计算的机器身份:Deployment 控制器靠它判断"这个 RS 对应哪个版本"

### 3.3 RS 之间的扩缩(滚动更新的最小单位)
```
旧 RS(nginx:1.27)  replicas=3  ← 缩
新 RS(nginx:1.28)  replicas=0  ← 扩
```
- 滚动更新 = 新 RS 逐渐扩、旧 RS 逐渐缩,两者在中间时刻**并存**
- 回滚 = 反方向再来一次(旧 RS 扩回来)
- 这就是"回滚快"的原因:Pod 模板、镜像都还按哈希存在,只是把 RS 的 replicas 数字换回来

## 四、滚动更新(核心中的核心)

### 4.1 触发与判断
- 触发:template 的任何字段变化(镜像、环境变量、探针、资源……)
- 判断:Deployment 控制器对比 template 哈希,变了就创建新 RS
- **不触发**:改 replicas、改 strategy、改标签(非 template 的)
- 更新是"新建 RS 从 0 扩"而非"改旧 RS",所以历史可回溯

### 4.2 滚动过程(lab01 现场还原)
```
初始:  旧RS=3/3,新RS=0/0
步骤1: 新RS=1/1(旧RS=3)
步骤2: 新RS=1/1 就绪后 → 旧RS=2
步骤3: 新RS=2/2 → 旧RS=1
步骤4: 新RS=3/3 → 旧RS=0(缩为 0 但对象保留,等回滚)
```
- 每一步"扩新→等就绪→缩旧"由 Deployment 控制器驱动
- **readinessProbe 是发布节奏的闸门**:新 Pod 不就绪,控制器不继续缩旧,发布卡住
- 发布卡住时 `kubectl rollout status` 会一直等待,直到超时或成功

### 4.3 maxSurge / maxUnavailable 的数学(必须会算)
| 参数 | 含义 | 默认 | 取值 |
|------|------|------|------|
| maxSurge | 可超出期望副本数的量 | 25% | 百分比按 replicas 换算后**向上取整** |
| maxUnavailable | 可低于期望副本数的量 | 25% | 百分比按 replicas 换算后**向下取整** |

- 约束:滚动任意时刻,`可用副本 ≥ replicas - maxUnavailable`,`总副本 ≤ replicas + maxSurge`
- replicas=3、maxSurge=1、maxUnavailable=1 → 滚动全程可用数 ≥2、总数 ≤4
- **容量无损配置**:maxUnavailable=0 → 全程可用数 = replicas,代价是需要多出 maxSurge 的资源
- 百分比换算示例:replicas=10、maxSurge=25% → 2.5 向上取整=3;maxUnavailable=25% → 2.5 向下取整=2

### 4.4 两种策略对比(lab02-strategy.yaml)
```yaml
# 滚动更新(默认):逐步替换,服务不中断
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxSurge: 1
    maxUnavailable: 0        # 全程保持全部副本可用

# 重建:先杀光旧的再建新的,有明确停机窗口
strategy:
  type: Recreate
```
| 策略 | 过程 | 停机 | 适用 |
|------|------|------|------|
| RollingUpdate | 新旧并存逐步切换 | 无(靠探针闸门) | 默认,几乎所有在线服务 |
| Recreate | 先全删再全建 | 有 | 必须单实例独占的应用(如独占文件锁)、RWO 卷单挂载场景 |

- Recreate 与 RWO 卷:两个 Pod 同时挂同一 RWO PVC 会冲突,所以先删后建(第 06 章 MySQL 的 Deployment 也用了 Recreate)

## 五、版本历史与回滚

### 5.1 revision 机制
- 每次滚动(新 RS 创建)记为一次 revision:1、2、3……
- revision 记录在 Deployment 的 annotations:`deployment.kubernetes.io/revision`
- 历史列表 = 保留下来的旧 RS 集合(revisionHistoryLimit 控制数量)

### 5.2 rollout undo 的原理
```
kubectl rollout undo deployment/web
 → 找到上一个 revision 对应的旧 RS
 → 把旧 RS 的 replicas 从 0 扩回期望值
 → 把新 RS 缩到 0
```
- **不是"撤销操作",是"把期望模板切回旧版本"**——所以:
  - 可以回滚到任意历史版本(`--to-revision=N`)
  - 回滚本身也会产生新 revision(本质是一次反向的滚动)
- `kubectl rollout history deployment/web` 列出所有 revision

### 5.3 change-cause 注解(发布说明)
```yaml
metadata:
  annotations:
    kubernetes.io/change-cause: "初始版本 nginx:1.27"
```
- 手动添加或 `kubectl annotate deployment web kubernetes.io/change-cause="..." --overwrite`
- 作用:rollout history 里显示"这个版本是干嘛的",不写则显示 <none>
- 团队协作中这是版本说明的载体,生产建议每次发布必填

### 5.4 暂停/恢复(分批发布/金丝雀的前置)
```
kubectl rollout pause deployment/app    # 暂停:template 改了也不滚动
kubectl set image ...                   # 连续改多处,不触发滚动
kubectl rollout resume deployment/app   # 恢复:一次性应用所有累积变更
```
- 暂停期间对 template 的修改**累积**,resume 时一起生效
- 用途:复杂变更想"改完一处看一处"、多字段变更想合并成一次发布
- 注意:pause 状态下 rollout status 会一直等,记得 resume

### 5.5 回滚的边界
- 只能回滚 **template 相关**内容(版本由 RS 承载)
- replicas 不是版本的一部分:回滚不会改副本数
- 删除的 revision(revisionHistoryLimit 淘汰掉)无法回滚——所以调小 limit 前想清楚

## 六、扩缩容与自愈

### 6.1 扩缩容语义
```yaml
spec:
  replicas: 5    # 改这里,控制器增删 Pod,不产生新 RS、不滚动
```
- `kubectl scale deployment web --replicas=5` 等价于改 replicas
- 缩容时删哪些 Pod:RS 优先删**后创建**的(稳定序号原则,先删新补的)
- 与 HPA 的关系:HPA(第 15 章)就是自动改 replicas,所以 HPA 接管后手动 scale 会被覆盖

### 6.2 自愈场景(调谐的实践)
| 故障 | 控制器动作 |
|------|-----------|
| 删了一个 Pod | RS 补一个同模板新 Pod |
| 节点 NotReady | Pod 被驱逐后,RS 在别的节点重建 |
| 滚动中旧 Pod 挂掉 | 缩旧逻辑继续,发布不中断 |
| 新版本起不来(探针不过) | 新 RS 永远就绪不了 → 发布卡住 → 需要回滚或修模板 |

## 七、与"调谐循环"的串接(第 02 章知识复用)

### 7.1 一次 apply 后的完整链路
```
1. kubectl apply → apiserver 落库 Deployment
2. Deployment 控制器 watch 到 → 对比模板哈希,创建/更新 RS
3. RS 控制器 watch 到 RS → 按 replicas 创建 Pod(generateName 前缀)
4. scheduler 给无主 Pod 选节点 → 写 nodeName
5. kubelet 起容器 → 探针通过 → Pod Ready
6. EndpointSlice 控制器把就绪 Pod 加进 Service 后端(若存在)
7. Deployment 控制器看到新 RS 就绪数达标 → 继续缩旧 RS(滚动推进)
```
- 三个控制器各管一层(Deployment→RS→Pod),互不越权,靠 watch + 状态回填协作

### 7.2 status 字段(观察发布的仪表盘)
```
status.replicas          实际 Pod 总数
status.updatedReplicas   新模板 Pod 数(滚动进度)
status.readyReplicas     就绪 Pod 数
status.availableReplicas 可服务 Pod 数
status.observedGeneration 控制器已处理的 spec 代数
```
- `kubectl rollout status` 的底层就是轮询这些字段
- generation vs observedGeneration:observed < generation 说明控制器还没处理完最新 spec

## 八、常见问题与设计原则

### 8.1 经典坑
| 坑 | 原因 | 对策 |
|----|------|------|
| 改了 selector 被拒绝 | selector 创建后不可变 | 想换标签就新建 Deployment,迁移流量 |
| 镜像用 latest 不更新 | latest + IfNotPresent 不重新拉取 | 固定 tag;真要用 latest 设 imagePullPolicy: Always |
| 发布卡住一半 | 新 Pod 起不来(镜像错/探针严/资源不足) | `rollout status` 看卡点,`describe` 新 RS 的 Pod |
| 回滚后 behavior 奇怪 | 混用命令式操作导致账本失真 | 一切改 template 走 apply(第 03 章三方合并) |
| 频繁小改动产生大量 RS | 每改一次模板 = 一次新 RS | 暂停发布合并变更,或规划好变更批次 |

### 8.2 设计原则
1. 探针是发布质量的第一道闸门,readiness 必须真实反映"能不能接流量"
2. 生产用 maxUnavailable=0 保容量,但要保证 maxSurge 有资源冗余
3. 每条发布记 change-cause,回滚可溯源
4. 上线窗口期用 rollout pause 做分批验证
5. Deployment 不管存储:有状态数据必须外置(PVC/外部 DB),否则 Pod 重建即丢

## 九、状态观察要点(知识性)
- `kubectl get deployment web -o yaml` 看 status 四指标,判断滚动进度
- `kubectl get rs` 看新旧 RS 的 DESIRED/CURRENT/READY,一眼看出滚动到哪
- `kubectl rollout status/history/undo/pause/resume` 是发布控制的标准面
- 观察时序:先看 RS 列表(新旧并存=滚动中),再看 status.updatedReplicas 是否收敛到期望值
