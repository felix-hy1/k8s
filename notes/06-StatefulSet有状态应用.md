# 06 StatefulSet 有状态应用(知识笔记)

> 约定:YAML 示例出自 `~/k8s-lab/06-StatefulSet有状态应用/manifests/lab01~lab02`,编号与章节对应。

## 一、有状态 vs 无状态

### 1.1 两类应用的本质差异
| 维度 | 无状态(nginx/网关) | 有状态(数据库/MQ/分布式存储) |
|------|---------------------|------------------------------|
| 副本关系 | 完全等价,谁都是谁 | 各有身份(主/从、节点编号) |
| 数据 | 不落本地(在外部) | 每个实例有**独立的持久数据** |
| 启停顺序 | 无所谓 | 有所谓(先主后从、先建集群再加入) |
| 网络寻址 | 随便找一个 | **必须找到"那一个"**(连主库) |
| 存储共享 | 可共享 | **绝不能共享**(两实例写同一块盘=数据损坏) |

### 1.2 Deployment 做不到什么
- Pod 名随机后缀(每次重建变)→ 无法按名字寻址
- 所有副本共享同一份存储定义(或无存储)→ 无法"每人一块盘"
- 并行创建/删除 → 无法保证先后顺序
- 结论:有状态应用需要一套新的承诺,StatefulSet 应运而生

## 二、StatefulSet 的三大承诺(核心)

| 承诺 | 实现载体 | 表现 |
|------|----------|------|
| 稳定网络标识 | Headless Service + Pod 编号 | `web-0.web.<ns>.svc.cluster.local` 永不变 |
| 稳定存储 | volumeClaimTemplates | Pod 重建挂回原来的 PVC,数据还在 |
| 有序启停 | 控制器内置 | 创建 0→N,删除/更新 N→0 |

### 2.1 稳定网络标识
- Pod 名 = `<sts名>-<序号>`(web-0/web-1/web-2),重建后**名字不变**
- 配合 Headless Service,每个 Pod 有专属 DNS 名:
  ```
  web-0.web.sts-lab.svc.cluster.local   → web-0 的 IP
  web-1.web.sts-lab.svc.cluster.local   → web-1 的 IP
  web.sts-lab.svc.cluster.local         → 所有 Pod 的 IP 列表
  ```
- IP 仍会变(重建),但 **DNS 名不变**——客户端连"名字"不连"IP"
- 用途:数据库主从互认、集群成员发现,都靠这个名字

### 2.2 稳定存储
- 每个 Pod 独享一块 PVC,命名规则:`<模板名>-<Pod名>`
  ```
  volumeClaimTemplates 名为 www → www-web-0 / www-web-1 / www-web-2
  ```
- Pod 删除重建 → 调度回原节点(受 PV nodeAffinity 约束)→ 挂回原 PVC → **数据不丢**
- 注意:PVC 生命周期独立于 Pod——删 StatefulSet 默认**不删 PVC**(防止误删数据)

### 2.3 有序启停
- 创建:web-0 Ready 后才创建 web-1,依次到 N(实验观察:AGE 差 5 秒)
- 删除:逆序,web-N 先死,到 web-0
- 滚动更新:逆序逐个更新(每个 Ready 才下一个)
- 可改 `podManagementPolicy: Parallel` 放弃顺序换速度(默认 OrderedReady)

## 三、Headless Service(稳定标识的载体)

### 3.0 配置(lab01 注解)
```yaml
apiVersion: v1
kind: Service
metadata:
  name: web                # 必须与 StatefulSet 的 serviceName 一致
  namespace: sts-lab
spec:
  clusterIP: None          # ← Headless 标志:不分配 VIP
  selector:
    app: web-sts
  ports:
    - port: 80
      name: web
```

### 3.1 clusterIP: None 的语义
```
普通 Service:  client → VIP(10.96.x.x) → kube-proxy 转发 → 某个 Pod(负载均衡,匿名)
Headless:      client → DNS 直接返回 Pod IP 列表 → 客户端自己选目标(具名,可定向)
```
- 普通 Service 提供" anonymity"(随便找一个);Headless 提供"identity"(找到特定的那个)
- StatefulSet 必须配 Headless:`serviceName` 字段指向它,DNS 记录才按 Pod 展开

### 3.2 使用场景
| 场景 | 为什么用 Headless |
|------|-------------------|
| StatefulSet 稳定标识 | Pod 专属 DNS 名 |
| 客户端自负载均衡 | gRPC 长连接场景,客户端自己维护后端列表 |
| 直连特定实例 | 调试、主从指定连接 |

## 四、StatefulSet 对象结构(lab01 全解)

### 4.0 配置全文(带注解)
```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: web
  namespace: sts-lab
spec:
  serviceName: web           # 绑定 Headless Service(必填,决定 DNS 子域名)
  replicas: 3
  selector:
    matchLabels: { app: web-sts }
  template:
    metadata:
      labels: { app: web-sts }
    spec:
      terminationGracePeriodSeconds: 10    # 逆序删除时每个 Pod 的退出预算
      containers:
        - name: nginx
          image: nginx:1.27
          ports:
            - containerPort: 80
              name: web
          volumeMounts:
            - name: www                    # 引用名:找 volumeClaimTemplates 里的同名模板
              mountPath: /usr/share/nginx/html   # 目录:容器内挂载点
  volumeClaimTemplates:                    # 每个 Pod 独享一份
    - metadata:
        name: www                          # 模板名 → PVC 命名前缀
      spec:
        accessModes: ["ReadWriteOnce"]     # 单节点读写
        resources:
          requests:
            storage: 1Gi                   # 每块盘 1Gi
```

### 4.1 与 Deployment 的结构差异
| 字段 | Deployment | StatefulSet |
|------|------------|-------------|
| replicas | ✅ | ✅ |
| selector/template | ✅ | ✅ |
| strategy(发布策略) | ✅ RollingUpdate 参数 | 有但语义不同(逆序逐个,无 maxSurge) |
| serviceName | ❌ | ✅ **必填**(绑 Headless) |
| volumeClaimTemplates | ❌ | ✅ **独有** |
| Pod 名 | 随机后缀 | 有序编号 |

### 4.2 volumeMounts.name 的引用机制(易混点)
```yaml
volumeMounts:
  - name: www                       # ← 引用名(逻辑名),不是目录!
    mountPath: /usr/share/nginx/html # ← 这才是目录
```
- `name: www` 在 volumeClaimTemplates 里找同名模板,建立"挂载点↔盘"的配对
- 模板里都叫 www,但每个 Pod 实例化时绑到**自己的** PVC:
  ```
  web-0: volumeMounts(www) → www-web-0
  web-1: volumeMounts(www) → www-web-1
  ```
- **一份模板,三份独立存储**——引用名是模板内部的"插座编号"

### 4.3 PVC 与实验观察对应
```
kubectl get pvc -n sts-lab
www-web-0   Bound   pvc-dfb349a3-...   1Gi   RWO   standard
www-web-1   Bound   pvc-b62d9558-...   1Gi   RWO   standard
www-web-2   Bound   pvc-f4dd352e-...   1Gi   RWO   standard
```
- 三行 = 三块**独立的盘**;VOLUME 列是动态供给自动建的 PV 对象名(pvc-<uid>)

## 五、真实应用实战:MySQL(lab02 的增量)

### 5.0 lab01 → lab02 差异总览
| 维度 | lab01 | lab02 |
|------|-------|-------|
| 资源对象 | 3 个 | 7 个(+Secret +ConfigMap +客户端 Pod) |
| 副本 | 3 | 1(单实例;多副本需主从,生产用 Operator) |
| env | 无 | Secret 注入 MYSQL_ROOT_PASSWORD |
| 卷 | 1 个(PVC) | **2 个**(PVC + ConfigMap 卷) |
| 探针 | 无 | exec 型 readiness |
| resources | 无 | 有(内存敏感) |

### 5.1 Secret + env 注入
```yaml
# Secret:stringData 明文书写,apiserver 自动转 base64 存储
stringData:
  password: "Root@123456"
---
# StatefulSet 引用:
env:
  - name: MYSQL_ROOT_PASSWORD          # MySQL 镜像约定的环境变量
    valueFrom:
      secretKeyRef:
        name: mysql-root-password      # 引用哪个 Secret
        key: password                  # 取哪个键
```
- 密码不写死在 Pod 定义里 → `kubectl get pod -o yaml` 看不到明文
- MySQL 镜像约定:首次启动读此变量设置 root 密码

### 5.2 双卷来源(静态 vs 动态的对照)
```yaml
      volumes:                          # ← 静态:直接声明"卷的内容"
        - name: initdb
          configMap: { name: mysql-initdb }   # CM 每个 key 变一个文件
  volumeClaimTemplates:                 # ← 动态:申请一块持久盘
    - metadata: { name: data }
      spec: { ... storage: 5Gi }
```
| 卷 | 来源 | 内容性质 | 挂载点 | 读写 |
|----|------|----------|--------|------|
| initdb | ConfigMap | 死的文本(SQL 脚本) | /docker-entrypoint-initdb.d | 只读 |
| data | PVC 模板 | 活的、必须持久(数据库文件) | /var/lib/mysql | 读写 |

- 分工哲学:**配置用 ConfigMap(可版本化、可替换),数据用 PVC(必须持久)**

### 5.3 MySQL 镜像的初始化约定(灵魂机制)
```
mysql 容器启动 → 检查 /var/lib/mysql 是否为空?
   ├─ 空(首次) → 执行 /docker-entrypoint-initdb.d/*.sql(按文件名序)
   │             建库 → 建表 → 插数据 → 建账号
   └─ 非空(重启) → 跳过,直接启动
```
- **改了 init.sql 不会重新执行**——数据目录非空就跳过
- 想重跑初始化:删 PVC + 删 Pod(清空数据重来)
- ConfigMap 的 key 名(01-init.sql)即挂载后的文件名;`|` 字面块保留 SQL 换行

### 5.4 exec 型 readinessProbe
```yaml
readinessProbe:
  exec:
    command: ["sh", "-c", "mysqladmin ping -uroot -p\"$MYSQL_ROOT_PASSWORD\" --silent"]
  initialDelaySeconds: 20      # MySQL 初始化慢(设密码+跑SQL)
  periodSeconds: 5
```
- exec 型:容器内执行命令,exit 0 = 成功(MySQL 无 HTTP 端口)
- `$MYSQL_ROOT_PASSWORD` 在 sh -c 里展开 = 上面 Secret 注入的变量(两处联动)
- 意义:初始化未完成时不进 endpoints/DNS,客户端连不上"半成品"

### 5.5 客户端跳板 Pod
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: mysql-client
  namespace: mysql-ns
spec:
  restartPolicy: Never
  containers:
    - name: mysql
      image: mysql:8.0
      command: ["sh", "-c", "sleep 8h"]    # 挂着等你 exec 进去
```
- MySQL 只在集群内可达 → 用一个装了 mysql 客户端的 Pod 当跳板
- 连接地址用 lab01 学的稳定 DNS:`mysql-0.mysql.mysql-ns.svc.cluster.local`

## 六、存储落盘的完整链路(PVC 到真实磁盘)

### 6.1 四层链路
```
容器内 /usr/share/nginx/html         ← 应用看到的目录
  ↑ volumeMounts(name 引用)
PVC www-web-0(命名空间级申请)
  ↑ 绑定(Bound)
PV pvc-dfb349a3-...(集群级资源,hostPath 类型)
  ↑ hostPath.path
节点目录 /var/local-path-provisioner/pvc-..._sts-lab_www-web-0
  ↑ (kind 节点=容器)
WSL docker 存储层(节点容器可写层)
```
- 容器里写文件 = 实实在在落到节点目录(可用 docker exec + cat 验证)

### 6.2 谁决定落盘位置(分工表,重要)
| 层 | 决定什么 |
|----|----------|
| 你的 YAML | 容量、访问模式、storageClassName(不写=默认 SC) |
| StorageClass | 雇哪个供给器、回收策略、绑定时机 |
| **供给器(provisioner)** | **实际路径、放哪个节点**(真正的落盘决策者) |
| K8s 本体 | 只管 PVC↔PV 绑定机制、访问模式约束 |

- kind 默认 SC `standard` → provisioner `rancher.io/local-path`
- local-path 的自有逻辑:基础目录 `/var/local-path-provisioner/` + 命名 `pvc-<uid>_<ns>_<pvc名>`
- **修正认知**:不是"K8s 自己决定落盘",是"SC 雇的供给器决定,K8s 只管绑定"
- 想自己控制路径 → 静态供给:手工建 PV 写明 hostPath(第 11 章实验 2)

### 6.3 volumeBindingMode 两种模式
| 模式 | PV 创建时机 | 结果 |
|------|-------------|------|
| Immediate | PVC 一创建就供给(随机挑节点) | Pod 反过来被拽到 PV 所在节点 |
| **WaitForFirstConsumer**(kind 默认) | 等 Pod 调度完成后,在 **Pod 所在节点**供给 | 数据跟随 Pod(实验现象:web-0 的 PV 在 worker,web-1/2 在 worker2) |

### 6.4 nodeAffinity 拓扑锁定
```yaml
# 动态供给的 PV 自带:
nodeAffinity:
  - key: kubernetes.io/hostname
    values: [k8s-learning-worker]     # 数据只在这个节点
```
- local-path 是节点本地存储 → 数据绑定节点 → Pod 重建必须调度回原节点
- 网络存储(NFS/Ceph)无此限制 → 生产有状态应用常用网络存储获得调度自由

### 6.5 回收策略与数据安全
- 动态供给默认 `Delete`:PVC 删除 → PV + 数据一起删
- 删 StatefulSet **不删 PVC**(保护数据);想清数据须显式删 PVC
- 生产建议:重要数据 SC 配 Retain,或外接备份(mysqldump CronJob)

## 七、与 Deployment 全面对比(总结)

| 维度 | Deployment | StatefulSet |
|------|------------|-------------|
| 目标 | 无状态、等价副本 | 有状态、独立身份 |
| Pod 名 | 随机后缀 | 有序编号,稳定 |
| DNS | Service VIP(匿名) | Headless(具名,每 Pod 一条) |
| 存储 | 共享或无 | 每副本专属 PVC |
| 创建顺序 | 并行 | 串行(Ready 才下一个) |
| 删除/更新顺序 | 无序/滚动 | 逆序 |
| 滚动更新参数 | maxSurge/maxUnavailable | partition(灰度)/逐个 |
| 典型对象 | web/api 网关 | 数据库/MQ/ZooKeeper/Redis 集群 |

## 八、验证性知识(实验观察过的现象)
- Pod AGE 依次差 5 秒 = 有序创建的现场证据
- 删 web-1 → 重建后名字不变、PVC www-web-1 不变(稳定标识+存储)
- MySQL 删 Pod 重建后 `SELECT COUNT(*)` 数据还在(PVC 兜底)
- 三节点 `/var/local-path-provisioner/` 目录数分布 = WaitForFirstConsumer 的证据
