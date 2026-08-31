# 03 kubectl 基础(知识笔记)

## 一、kubectl 的定位与架构

### 1.1 本质:无状态的 REST 客户端
- kubectl 不保存任何集群状态,它做的事只有一件:**把人的意图翻译成对 apiserver 的 HTTPS/REST 请求,再把结果渲染给人**
- 一切"集群在哪、我是谁"的信息都来自 kubeconfig;换一台机器,拷一份 kubeconfig 就是完全等价的客户端
- 推论:apiserver 不可达时,kubectl 的任何命令都失败——它不是"离线工具"

### 1.2 一条命令内部发生什么(概念流程)
```
kubectl get pods -n dev
  ① 解析 kubeconfig(找到 current-context:集群地址 + 凭证)
  ② 发现(Discovery):拉取/缓存 apiserver 的资源清单,把 "pods" 映射到 /api/v1/pods
  ③ 发起 REST:GET https://<apiserver>/api/v1/namespaces/dev/pods
  ④ 渲染:把返回的 JSON 按输出格式呈现
```
- 资源名→URL 的映射来自 apiserver 的 discovery API(所以 CRD 装上后 kubectl 立刻就能操作它)

### 1.3 kubeconfig 结构
```yaml
clusters:        # 去哪连
  - name: kind-k8s-learning
    cluster: { server: https://127.0.0.1:44851, certificate-authority-data: ... }
users:           # 以什么身份
  - name: kind-k8s-learning
    user: { client-certificate-data: ..., client-key-data: ... }
contexts:        # 组合:哪个集群 + 哪个身份 + 默认 ns
  - name: kind-k8s-learning
    context: { cluster: ..., user: ..., namespace: ... }
current-context: kind-k8s-learning
```
- 三段正交:集群(地址)、用户(身份)、上下文(绑定) → 一份文件可表达"多集群 × 多身份"任意组合
- 多配置合并:`KUBECONFIG=a:b:kubectl` 按 PATH 式合并;`--kubeconfig` 临时指定(交付受限账号的安全姿势)

## 二、命令体系

### 2.1 语法模型与缩写
```
kubectl <动词> <资源类型> [名字] [标志]
```
- 常用动词族:get/describe(读)、create/apply/edit/delete(写)、logs/exec/cp/port-forward(进入数据面)、scale/rollout(控制)、explain/api-resources(发现)
- 资源缩写:po=pods, deploy=deployments, svc=services, cm=configmaps, ns=namespaces, pvc, sa, ing, ds, sts, job…(get 后按 Tab 可见)

### 2.2 作用域规则
- `-n <ns>`:本次命令作用域;`-A`:全 ns(读操作常用)
- 都不写:用 current-context 的默认 ns(default)——漏写 ns 是新手"资源去哪了"的头号原因
- 永久设定默认 ns:`kubectl config set-context --current --namespace=xx`

### 2.3 指定目标对象的三种方式
| 方式 | 例子 | 适用 |
|------|------|------|
| 名字 | `kubectl delete pod web` | 单个对象 |
| 标签选择器 | `kubectl delete pod -l app=web` | 批量 |
| 清单文件 | `kubectl delete -f xx.yaml` | 与 apply 对称,不依赖名字 |

- 工作负载类型可代指 Pod:`kubectl logs deployment/web` 自动挑一个副本

## 三、命令式与声明式(kubectl 的两种灵魂)

### 3.0 声明式的实物:练习对象 Deployment(lab01-practice.yaml 注解)
```yaml
apiVersion: apps/v1              # apps 组:Deployment/ReplicaSet/StatefulSet 所在
kind: Deployment
metadata:
  name: shop
  namespace: kubectl-lab
  labels:
    app: shop                    # Deployment 对象自身的标签(非 Pod 的)
spec:
  replicas: 3                    # 期望副本数:少补多删
  selector:
    matchLabels:
      app: shop                  # 认领自己的 Pod(必须与 template 标签一致)
  template:                      # 内嵌 Pod 模板 = 新 Pod 的"模具"
    metadata:
      labels:
        app: shop                # 新 Pod 出厂标签,与 selector 对齐
    spec:
      containers:
        - name: nginx
          image: nginx:1.27      # 改这行 = 触发滚动更新
          ports:
            - containerPort: 80
          resources:
            requests: { cpu: 50m, memory: 64Mi }
            limits: { cpu: 100m, memory: 128Mi }   # requests≠limits → Burstable
```
- spec 三要素记忆:**replicas(要几个)+ selector(哪些是我的)+ template(长什么样)**
- 改 replicas → 扩缩容;改 template → 滚动更新;selector 基本不动

### 3.1 对比
| | 命令式(create/set/scale/rollout/edit) | 声明式(apply) |
|---|----------------------------------------|----------------|
| 语义 | "执行这个动作" | "让集群对齐这份文件" |
| 留痕 | 不留声明记录 | 记账到 last-applied 注解 |
| 重复执行 | 报错/副作用叠加 | 幂等收敛 |
| 多人协作 | 冲突无解 | 文件可进 git,可评审 |
| 适用 | 应急、临时、探索 | 正式环境、自动化 |

### 3.2 apply 的三方合并(核心原理)
**账本机制**:每次 `kubectl apply`,kubectl 把**整份文件内容**存进注解:
`kubectl.kubernetes.io/last-applied-configuration` —— 它是"上一次你声明过什么"的存证。

```yaml
# apply 后对象上自动出现的注解(账本):
metadata:
  annotations:
    kubectl.kubernetes.io/last-applied-configuration: |
      {"apiVersion":"apps/v1","kind":"Deployment","metadata":{...},
       "spec":{"replicas":3,"selector":{...},"template":{...}}}
# 查看: kubectl get deployment shop -n kubectl-lab -o yaml | grep -A2 last-applied
```

下次 apply 同一文件时执行**三方合并**:

```
      账本(上次声明)          新文件(本次声明)          集群现状(实际)
            └────── 你想改的差异 ──────┘                     │
            └────────── 事后漂移的差异 ──────────────────────┘
结果 = 现状 + 你的差异(覆盖),但保留"事后漂移"中你不再声明的部分?
```
精确规则(以字段为粒度):
| 情形 | 结果 |
|------|------|
| 账本=A,新文件=B,现状=A | 应用 B |
| 账本=A,新文件=A,现状=B | **保留 B**(视为他人有意修改,apply 不动它) |
| 账本=A,新文件=无此字段,现状=A | 删除该字段 |
| 字段从未进过账本(纯他人手改) | 不动(apply 的"不越权"原则) |

### 3.3 账本失真事故的推演(为什么警告)
```
1. apply 文件(镜像 1.26)      → 账本=1.26,现状=1.26
2. 命令式改动(rollout undo 等) → 现状=1.27,账本仍=1.26
3. 再次 apply 同一文件(1.26)   → 三方合并命中第二行规则:
                                   账本与文件相同 → "你这次没想改镜像"
                                   → 镜像停留在 1.27,apply 静默不生效!
```
- 这就是 `rollout undo` 时那条 Warning 的全部含义:回滚改了现状不记账本,账本可能失真,未来 apply 行为可能"反直觉"
- 处置原则:**让文件成为唯一事实源**;需要恢复一致时,直接 apply 与现状匹配的文件刷新账本

### 3.4 写入类命令全家对比
| 命令 | 行为 | 留账本? | 场景 |
|------|------|---------|------|
| create | 只建,存在即报错 | ❌ | 一次性创建 |
| apply | 建或三方合并更新 | ✅ | 默认选择 |
| edit | 直接改现状(无差异保护) | ❌ | 临时救急 |
| replace | 整体覆盖(缺字段会被抹掉) | ❌ | 脚本化完全替换 |
| set/scale/rollout | 改现状特定字段 | ❌ | 运维动作 |

### 3.5 Server-Side Apply 简介(演进方向)
- 旧 apply(客户端合并)的问题:账本体积大、合并逻辑在客户端、多工具写同一对象时互相"隐形覆盖"
- SSA(1.22+ 默认可用):把"谁拥有哪些字段"记到服务端(managedFields/fieldManager),按字段归属做合并与冲突检测
- 概念上仍是同一思想:**以声明为准 + 记录字段所有权**,只是账本从"整份 JSON 注解"进化为"服务端字段级登记"

## 四、信息获取的数据来源

### 4.1 命令→数据源映射
| 命令 | 数据路径 | 特点 |
|------|----------|------|
| get/describe | etcd(经 apiserver) | 对象定义 + status,有版本号 |
| logs | apiserver→kubelet(流式代理) | 实时不落 etcd;`--previous` 读上一实例 |
| exec/cp/port-forward | apiserver→kubelet(SPDY/WebSocket) | 同上,建立双向通道 |
| top | metrics-server(聚合 API) | 需单独安装 |
| api-resources/explain | apiserver discovery/OpenAPI | 集群自描述能力 |

### 4.2 Events 机制
- Events 本身是 etcd 里的对象(核心组),由各组件在关键动作时产生:调度结果、镜像拉取、探针失败、BackOff…
- `describe` 尾部的 Events 是排错第一现场;默认保留 1 小时(可配置),`--sort-by=.lastTimestamp` 排序
- 事件三要素:reason(机器可读的动作码)、message(人读描述)、involvedObject(发生在谁身上)

### 4.3 resourceVersion 与乐观并发
- 每个 etcd 修改产生全局递增 revision;对象携带 resourceVersion
- 任何更新请求必须基于"读到的版本"——若期间别人改过,apiserver 拒绝(409 Conflict)→ 客户端重读重试
- 这就是多人/多工具并发编辑对象不会互相覆盖丢失的机制基础

## 五、资源发现(集群自带说明书)

### 5.1 发现资源类型
- `kubectl api-resources`:列出全部资源(名字/缩写/是否 ns 级/所属组)——CRD 安装后立即出现在此
- `kubectl api-versions`:全部组/版本

### 5.2 explain:OpenAPI schema 的树状查询
- 原理:输出取自 apiserver 的 OpenAPI 定义 = 校验你 YAML 的同一份 schema → 与集群版本严格一致,且离线可查(有缓存)
- 用法是"逐层下钻":`explain pod` → `explain pod.spec` → `explain pod.spec.containers` → …每一层列出该层全部字段、类型与说明
- 类型记法:`<string>/<integer>/<boolean>` 标量;`<Object>` 需继续下钻;`<[]X>` 列表;`-required-` 必填
- `--recursive` 一次展开全部嵌套层级(输出巨大,常配合 grep 定位字段)

## 六、输出与字段提取

### 6.1 输出格式族
| 格式 | 用途 |
|------|------|
| 默认表格 | 浏览 |
| `-o wide` | 附加列(IP/节点/运行时) |
| `-o yaml` / `-o json` | 完整对象(spec+status+metadata 全量) |
| `-o name` | 仅"类型/名字" |
| `-o jsonpath=...` | 单点提取 |
| `-o custom-columns=...` | 自定义表格(适合巡检脚本) |
| `-o go-template=...` | 复杂逻辑渲染(进阶) |

### 6.2 jsonpath 细则
- 路径以 `.` 起:`{.status.podIP}`;数组遍历 `{.items[*].metadata.name}`
- 循环拼版:`{range .items[*]}{.metadata.name}{"\t"}{.nodeName}{"\n"}{end}`
- 键名含点号需转义:`{.metadata.annotations.kubectl\.kubernetes\.io/last-applied-configuration}`
- 过滤(较晦涩):`{.items[?(@.status.phase=="Running")].metadata.name}`

### 6.3 custom-columns
- `NAME:.metadata.name,NODE:.spec.nodeName` 语法,列名在前路径在后;比 jsonpath 易读,适合日常自用报表

## 七、变更安全机制

### 7.1 dry-run 的两个层级
| 模式 | 执行到哪一步 | 用途 |
|------|--------------|------|
| `--dry-run=client` | 本地渲染,不发请求 | 生成 YAML 模板 |
| `--dry-run=server` | 完整走 apiserver:认证/授权/准入/校验,但**不落库** | 上线前真实验证 |

```bash
# 命令式 → 声明式的标准转换(dry-run + -o yaml 即"生成模板"):
kubectl create deployment gen-web --image=nginx:1.27 --dry-run=client -o yaml
# 产物:
# apiVersion: apps/v1
# kind: Deployment
# metadata:
#   creationTimestamp: null      # ← 占位字段,apply 前应删掉
#   labels:
#     app: gen-web
#   name: gen-web
# spec:
#   replicas: 1
#   selector:
#     matchLabels: { app: gen-web }
#   template:
#     metadata:
#       labels: { app: gen-web }
#     spec:
#       containers:
#       - image: nginx:1.27
#         name: nginx
#         resources: {}
```
- 生成物再人工完善(删 creationTimestamp 占位、补 resources)→ 存文件 → apply

### 7.2 diff
- `kubectl diff -f xx.yaml`:以三方合并逻辑预演"apply 会改什么",退出码非 0 表示有差异 → 可做 CI 门禁

### 7.3 优雅终止全过程(删除一个 Pod 时)
```
kubectl delete pod
 → apiserver 给 Pod 打 deletionTimestamp(宽限期默认 30s,可配)
 → kubelet 收到:执行 preStop 钩子(同步,占宽限期时间)
            → 发 SIGTERM(容器主进程可处理收尾)
 → 宽限期到仍未退出 → SIGKILL 强杀
 → kubelet 上报 → 对象真正移除;EndpointSlice 同步摘除该 Pod
```
- Service 摘流与进程收尾的相对时序可能产生少量 502 → 这就是 preStop 常写 sleep 几秒的原因
- `--grace-period=0 --force`:跳过等待直接删记录,可能留下"僵尸容器",仅死锁时使用

### 7.4 删除级联与垃圾回收(GC)
- 对象父子关系记录在子对象 `metadata.ownerReferences`(如 Deployment→RS→Pod)
- 删除父对象时三种策略:
  | 策略 | 行为 |
  |------|------|
  | background(默认) | 先删父,后台 GC 清子 |
  | foreground | 先等子全部清完才删父(父带 finalizer 阻塞) |
  | orphan | 断开归属,子对象保留 |
- finalizer 概念:对象上的"完成前锁",必须清空才能真删——PVC 删除卡 Terminating 常见原因即"还有 Pod 在用"的 finalizer

## 八、多集群/多环境的日常纪律

- 动手前确认目标:`kubectl config current-context`(current-context 是全局共享状态,任何终端/脚本切换会影响所有裸命令)
- 临时跨集群:命令级 `--context`;长期:分环境 kubeconfig 文件
- 默认 ns 与默认集群都属"全局状态",自动化脚本必须显式指定两者,不依赖隐式默认
