# 10 ConfigMap 与 Secret(知识笔记)

> 约定:YAML 示例出自 `~/k8s-lab/10-ConfigMap与Secret/manifests/lab01~lab03` 与 `files/`(nginx.conf / app.properties / ui-config.json),编号与章节对应。

## 一、定位与数据模型

### 1.1 配置与代码分离(两兄弟的存在理由)
- 写死配置的两大问题:换环境(dev/test/prod)必须重新打镜像;密码进代码,泄露就得发版
- 12-Factor 原则:**一次构建,多处部署,配置由部署环境注入**
- K8s 的落地:ConfigMap / Secret = **存放配置的两类命名空间级仓库**,Pod 不自带配置,启动时从仓库"取货"
- 镜像是"程序+运行时",配置是"环境差异"——两者正交,自然该分开管理

### 1.2 两兄弟的分工(差异全在治理,不在技术)
| | ConfigMap | Secret |
|---|-----------|--------|
| 存什么 | 非敏感文本:URL、日志级别、nginx.conf | 密码、token、证书、镜像仓库凭证 |
| 值形态 | 明文 | base64 编码(**编码≠加密**) |
| 明文写字段 | `data` | `stringData`(apiserver 自动编码进 `data`) |
| 单值引用 | `configMapKeyRef: { name, key }` | `secretKeyRef: { name, key }` |
| 卷数据源 | `configMap: { name }` | `secret: { secretName }`(字段名不对称,历史坑) |
| 卷权限习惯 | defaultMode 0644 | defaultMode 0400(收紧) |
| 治理手段 | 普通资源 | etcd 静态加密、RBAC 单独限权、审计敏感 |

- 结构和用法几乎克隆,分类的意义在**治理**:声明"这是敏感的",才能对它单独设防

### 1.3 数据模型硬约束
- `data` 的**值必须是字符串**:数字也要带引号(`"100"`),YAML 整数会被 API 校验拒绝;容器里取到的也永远是字符串,类型转换是应用的事
- 容量:ConfigMap 总量 ≤ 1Mi,Secret 单条 ≤ 1Mi;大文件要拆分
- **命名空间级资源**:Pod 只能引用同 namespace 的 ConfigMap/Secret——跨 ns 引用直接"找不到"(高频坑)
- key 命名:可用字母数字、`-`、`_`、`.`;`--from-file` 时**文件名即 key**

### 1.4 仓库本体(lab01 的 app-settings 注解)
```yaml
apiVersion: v1            # 核心组 v1(ConfigMap/Secret 都在核心组)
kind: ConfigMap           # 仓库对象
metadata:
  name: app-settings      # "取货地址",Pod 引用靠这个名字
  namespace: cfg-lab      # 命名空间级:只能被同 ns 的 Pod 引用
data:                     # 仓库的全部内容就是键值对,没有别的花样
  APP_NAME: "order-service"   # 键名即未来的变量名/文件名
  LOG_LEVEL: "debug"          # 值全部是字符串
  MAX_CONN: "100"             # 语义上是数字也必须加引号
```
- ConfigMap 对象没有 spec/status 之分——它就是一份纯数据,无状态、无可调谐逻辑

## 二、创建方式全景

### 2.1 三种来源与键名规则
| 方式 | 键名 | 值 | 适用 |
|------|------|-----|------|
| `--from-literal=k=v` | k | v | 少量散装键值 |
| `--from-file=文件` | **文件名** | 文件全文 | 配置文件整套入库 |
| `--from-env-file=文件` | 文件内每行的 key | 每行的 value | 按 `K=V` 格式逐行拆成多个键 |

- `--from-file` 的规则决定挂载形态:**文件名即键名 → 挂载后每键一文件 → 文件名还原**——配置文件"进仓库再出来"名字不变

### 2.2 lab02 前置:files/ 目录整体入库
```bash
# 命令(生成后管道 apply,不落盘):
kubectl create configmap app-conf -n cfg-lab \
  --from-file=nginx.conf --from-file=app.properties --from-file=ui-config.json \
  --dry-run=client -o yaml | kubectl apply -f -
```
```yaml
# 产物形态(注解):
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-conf
  namespace: cfg-lab
data:
  nginx.conf: |            # 键 = 文件名;| 为 YAML 多行块字面量
    worker_processes 1;    # 值 = 文件全文(原样保留换行)
    ...
  app.properties: |        # 热更新实验主角:timeout=30
    app.name=order-service
    log.level=info
    timeout=30
  ui-config.json: |        # JSON 也只是"一坨文本",CM 不解析内容
    {"theme": "dark", ...}
```
- ConfigMap **不理解内容格式**(properties/JSON/conf 都是一坨字符串),解析永远是应用的事

### 2.3 `--dry-run=client -o yaml` 套路
- 命令式生成 + 声明式管理:命令只负责"翻译"出 YAML,入库走 apply
- 对 create configmap / secret / deployment / job 全部通用;`client` = 不发给服务器,纯本地模拟

## 三、注入方式一:环境变量(lab01)

### 3.1 单值注入:valueFrom.configMapKeyRef
```yaml
spec:
  containers:
    - name: busybox
      image: busybox:1.36
      env:
        - name: APP_NAME              # 容器里的变量名
          valueFrom:                  # valueFrom 是"插座":插什么 ref 从哪取电
            configMapKeyRef:
              name: app-settings      # 去哪个仓库(同 ns)
              key: APP_NAME           # 取哪个键
```
- **name 与 key 可以不同名**——`- name: APP` + `key: APP_NAME` 即一层改名
- 插座家族对照:第 04 章 `fieldRef`(Pod 自身元数据,Downward API)、本章 `configMapKeyRef` / `secretKeyRef`(配置仓库)

### 3.2 整表注入:envFrom + prefix
```yaml
      envFrom:
        - configMapRef:               # 把仓库所有键值对整箱倒进 env
            name: app-settings
          prefix: CFG_                # 每个变量加前缀 → CFG_APP_NAME/CFG_LOG_LEVEL/CFG_MAX_CONN
```
- prefix 的两个理由:
  - 一个 Pod 可 envFrom **多个** ConfigMap/Secret,撞名会互相覆盖,前缀隔离
  - 防污染通用变量名空间——万一仓库里有 `PATH=...`,不带前缀整表倒入容器直接残废(真实事故高发点)
- env(单值)与 envFrom(整表)可并存:lab01 里 APP_NAME 同时以 `APP_NAME`(单取)和 `CFG_APP_NAME`(整箱)出现,即两种方式的对照设计

### 3.3 env 是"出生快照"(不热更新的机制根源)
- 环境变量是 kubelet 在**容器创建那一刻**写进进程的;运行中的进程,外部没有任何手段改它的 env(操作系统层面不存在这个机制)
- 推论:改 ConfigMap 后,env 注入的变量**纹丝不动**;只有删 Pod 重建(按新快照)才拿到新值
- "改了配置但应用没反应"排查第一问:**注入方式是 env 还是卷?**

### 3.4 引用不存在的仓库/key
- 现象:Pod 卡 `CreateContainerConfigError`,describe Events 可见 "configmap xxx not found"
- 容错开关:
```yaml
        - name: OPT_DB
          valueFrom:
            configMapKeyRef:
              name: app-settings
              key: NOT_EXIST          # 引用的 key 可能不存在
              optional: true          # 缺失也不阻塞启动,变量为空(envFrom 同有此字段)
```
- 取舍:配置强依赖 → 不加 optional,启动即失败(快速暴露);弱依赖 → optional 兜底

## 四、注入方式二:Volume 挂载(lab02 主角)

### 4.1 每键一文件的投影模型
```yaml
spec:
  containers:
    - name: app
      image: busybox:1.36
      volumeMounts:
        - name: conf                  # 引用 spec.volumes 里定义的卷
          mountPath: /etc/app         # 仓库投影到这个目录
          readOnly: true              # 双保险:ConfigMap 卷本来就强制只读
  volumes:
    - name: conf
      configMap:                      # 第三种卷类型(对照 04 章 emptyDir/hostPath)
        name: app-conf                # 数据源仓库
        defaultMode: 0644             # 投影文件的权限位
```
- 挂载后形态:**每个 key 变成一个文件**,键名即文件名:
```
/etc/app/
├── app.properties     ← key "app.properties" 的内容
├── nginx.conf         ← key "nginx.conf" 的内容
└── ui-config.json     ← key "ui-config.json" 的内容
```
- env vs 卷的形态差异:env 把键值变**变量**,卷把键值变**文件**——几乎所有程序都习惯读配置文件(而非反复重读 env),这是卷能热更新的先天条件
- `readOnly: true` 是显式声明;即使不写,ConfigMap 卷也只读——投影是仓库的视图,容器改了投影,下次热更新直接覆盖,写权限毫无意义

### 4.2 items:筛选与改名
```yaml
  volumes:
    - name: conf
      configMap:
        name: app-conf
        items:                        # 默认全部键都投影;items 只暴露列出的键
          - key: app.properties       # 仓库里的键名
            path: application.properties   # 投影成的文件名(改名层)
          - key: ui-config.json
            path: ui-config.json
            mode: 0640                # 单文件可覆盖 defaultMode
```
- 两个用途:**只挂部分键**(大仓库挑着用)、**改文件名**(配合应用期望的配置文件名)
- 注意 items 会**关闭"默认全量投影"**:列了几个挂几个

### 4.3 热更新机制:符号链接原子切换
```
容器内 /etc/app/ 的真实结构(ls -la 可见):
  app.properties  -> ..data/app.properties     # 表层:指向 ..data 的链接
  nginx.conf      -> ..data/nginx.conf
  ..data          -> ..2026_09_04_10_30_00.123   # 底层:指向时间戳目录的链接
  ..2026_09_04_10_30_00.123/                    # 实际文件住在这里
```
- 更新时序:
```
edit ConfigMap → apiserver 更新对象
  → kubelet 通过 watch 感知(秒级)
  → 下个同步周期(约 1 分钟内)生成新时间戳目录 ..10_35_00.456/
  → 把 ..data 指向新目录(符号链接切换是原子的)
  → 旧目录延迟回收
```
- **原子性是设计核心**:读者任意时刻看到的是"全旧"或"全新",绝不会读到写了一半的文件
- 同步延迟来源:kubelet 的 configMap 卷刷新周期,不是 watch 慢

### 4.4 文件变 ≠ 应用生效(热更新的最后一公里)
- K8s 的责任止步于"磁盘上的文件换了";应用(如 nginx)**启动时读一次配置**,进程内存里还是旧的
- 生效手段:应用自己监听文件变化 reload / reloader 之类 sidecar 检测变化触发滚动重启 / 手动 rollout restart
- 记忆:**热更新到文件为止,"嚼不嚼"看应用**

## 五、注入方式三:subPath(lab02 对照组)

### 5.1 目录遮挡问题(为什么需要 subPath)
- 普通卷挂载到目录会**整个盖住**该目录原有内容:把卷挂到 `/etc/nginx`,原生的 mime.types、fastcgi_params 全被藏起来,nginx 直接残废
- subPath = **只盖一个文件**,目录里其他内容原封不动——"替换容器内单个配置文件"的标准姿势:
```yaml
      volumeMounts:
        - name: conf
          mountPath: /etc/app/app.properties   # 挂到"文件路径"而非目录
          subPath: app.properties              # 只取仓库的这个键
  volumes:
    - name: conf
      configMap: { name: app-conf }
```
- 典型场景:用 ConfigMap 里的 nginx.conf 替换容器的 `/etc/nginx/nginx.conf`

### 5.2 为什么 subPath 失去热更新
- 目录挂载的热更新机关是"**整目录**符号链接切换"(4.3 的 ..data 机制)
- subPath 是把**挂载那一刻的那个具体文件**直接绑定进容器的路径——机关只作用于目录层,覆盖不到被单独绑定的文件
- 于是:改 ConfigMap 后,subPath 挂的文件**永远停在出生时的内容**
- 本质:用"放弃热更新"换"只盖一个文件"

### 5.3 三种注入方式终局对照
| | env(valueFrom/envFrom) | 卷·目录挂载 | 卷·subPath |
|---|---|---|---|
| 容器内形态 | 环境变量 | 目录下每键一文件 | 单个文件 |
| 热更新 | ❌ 永不(出生快照) | ✅ 约 1 分钟(到文件) | ❌ 永不(文件被冻结) |
| 典型用途 | 简单开关、地址、整表配置 | 整套配置文件、需热更 | 盖住容器内单个文件 |
| 深层原因 | 进程 env 外部不可改 | 目录级符号链接切换 | 单文件绑定绕过了机关 |

## 六、Secret 专题(lab03)

### 6.1 type 家族
| type | 内容结构 | 用途 |
|------|----------|------|
| Opaque | 任意键值(万能) | 应用凭据、通用敏感配置 |
| kubernetes.io/dockerconfigjson | 固定 `.dockerconfigjson` 键 | 私有镜像仓库凭证(imagePullSecrets) |
| kubernetes.io/tls | 固定 `tls.crt` + `tls.key` | Ingress HTTPS、证书挂载 |
| kubernetes.io/basic-auth | 固定 `username` + `password` | HTTP Basic 认证 |
- Opaque 之外都是"K8s 认识其内部结构的专用信封",创建时校验键的合法性

### 6.2 stringData vs data(写明文还是写编码)
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-cred
  namespace: cfg-lab
type: Opaque              # 万能类型:K8s 不假设内部结构
stringData:               # 明文写入(手写 YAML 推荐)
  username: "app"
  password: "P@ssw0rd!"   # apiserver 收到后自动 base64 编码
```
| 字段 | 写什么 | 何时用 |
|------|--------|--------|
| `data` | 必须自己 base64 后填 | 命令式生成、脚本管道 |
| `stringData` | 直接明文,**只写不读** | 手写 YAML(可读性) |
- `get -o yaml` 时只剩 `data`(全 base64)——stringData 是纯便利性写入字段

### 6.3 base64 ≠ 加密(安全真相)
- base64 的设计目的:**让二进制(证书等)能塞进 JSON/YAML**,不是保密
- 一条命令还原:`kubectl get secret db-cred -o jsonpath='{.data.password}' | base64 -d`
- 真正的防护是三层:
  | 层 | 手段 |
  |----|------|
  | 存储层 | etcd 静态加密(EncryptionConfiguration,集群管理员配置) |
  | 访问层 | RBAC 单独控制"谁能 get 这个 Secret"(14 章) |
  | 使用层 | 注入纪律:凭据优先卷挂载,不走 env(见 6.5) |

### 6.4 注入:secretKeyRef 与 secret 卷(lab03 全解)
```yaml
spec:
  containers:
    - name: app
      image: busybox:1.36
      env:                                    # 方式一:env 注入(便捷但非推荐)
        - name: DB_USER
          valueFrom:
            secretKeyRef:                     # 与 configMapKeyRef 逐字段同构
              name: db-cred
              key: username
        - name: DB_PASS
          valueFrom: { secretKeyRef: { name: db-cred, key: password } }
      volumeMounts:
        - name: cred
          mountPath: /etc/secret              # 方式二:卷挂载(推荐)
          readOnly: true
  volumes:
    - name: cred
      secret:
        secretName: db-cred                   # 注意:secretName(不是 name!),历史遗留不对称
        defaultMode: 0400                     # 仅属主可读——敏感数据的待遇
```
- 两处与 ConfigMap 卷的差异,都是安全设计:`secretName` 字段名、`0400` 权限(对照 CM 的 0644)
- 挂载后:`/etc/secret/username`、`/etc/secret/password` 每键一文件,规则与 CM 完全一致
- 细节:**写入的值不带结尾换行**——`cat` 后提示符黏在内容后面是正常现象,不是乱码
- Secret 卷同样支持热更新(默认策略)+ items 筛选 + subPath(同样失去热更新)——机制全套同 CM

### 6.5 env vs 卷注入 Secret 的安全权衡
- env 注入的泄漏暗道:`kubectl exec env` 全打印 / `/proc/1/environ` / 崩溃堆栈与转储 / 应用启动日志
- 卷文件只对"主动读了它的进程"可见,叠加 0400 权限,暗道全堵死
- 惯例:**普通配置走 env 无妨,凭据一律走卷**

### 6.6 docker-registry 类型与 imagePullSecrets
```bash
kubectl create secret docker-registry my-registry \
  --docker-server=registry.example.com \
  --docker-username=admin --docker-password=admin123 \
  -n cfg-lab --dry-run=client -o yaml | kubectl apply -f -
```
```yaml
# Pod 侧引用(注解):
spec:
  imagePullSecrets:                  # 挂在 Pod spec 上,不挂在容器上
    - name: my-registry              # 拉私有镜像时,节点替你向仓库出示这份凭证
```
- 解决的问题:私有仓库的镜像,节点 containerd 拉取时要认证——凭证以 Secret 存放,注入给 kubelet 用
- 更优做法:把 imagePullSecrets 挂在 ServiceAccount 上,整个 ns 的 Pod 自动继承(14 章)

### 6.7 tls 类型与 Ingress
```bash
kubectl create secret tls demo-tls --cert=tls.crt --key=tls.key
```
```yaml
# Ingress 侧引用(注解):
spec:
  tls:
    - hosts: [demo.example.com]      # 该域名的流量走 HTTPS
      secretName: demo-tls           # 固定读 tls.crt / tls.key 两个键
```
- tls 类型固定两把钥匙:`tls.crt`(证书)+ `tls.key`(私钥),创建时校验
- 与 09 章 Ingress 实验配套:证书的"存放"用 Secret,"使用"在 Ingress

## 七、故障与细节坑速查

| 现象/坑 | 根因 | 关联知识 |
|---------|------|----------|
| Pod 卡 `CreateContainerConfigError` | 引用的 ConfigMap/Secret 或 key 不存在 | 3.4;optional 可容错 |
| 改了 CM,应用没反应 | env 注入(快照)/ subPath(冻结)/ 卷但应用不 reload | 3.3、5.2、4.4 |
| 挂 /etc/nginx 后容器残废 | 目录遮挡盖住了原生文件 | 5.1;用 subPath |
| 跨 ns 引用报 not found | 两者都是命名空间级资源 | 1.3 |
| `MAX_CONN: 100` 提交被拒 | 值必须是字符串,要加引号 | 1.3 |
| cat 密码文件提示符黏住 | 写入值无结尾换行 | 6.4 |
| 想改挂载的配置文件 → 只读 | ConfigMap/Secret 卷强制只读;要写就叠 emptyDir | 4.1 |
| Secret 被人一条 base64 -d 看光 | 本就没加密;靠 etcd 加密 + RBAC + 注入纪律 | 6.3 |

- "改配置没生效"标准排查树:
```
确认注入方式
├─ env → 出生快照,必然不变;删 Pod 重建才生效
├─ subPath → 冻结文件,必然不变;同上
└─ 卷·目录
   ├─ cat 文件确认是否已变(约 1 分钟窗口)
   │  ├─ 没变 → 等 / 检查 CM 是否真改了(get 确认)
   │  └─ 变了 → 应用没 reload:重启应用 / reloader / 滚动重启
```

## 八、三种注入方式最小模板(速查)

```yaml
apiVersion: v1
kind: ConfigMap
metadata: { name: cm, namespace: ns1 }
data: { K1: "v1", K2: "v2" }        # 仓库:纯字符串键值对
---
apiVersion: v1
kind: Pod
metadata: { name: demo, namespace: ns1 }   # 必须与仓库同 ns
spec:
  containers:
    - name: app
      image: busybox:1.36
      env:
        - name: A                     # ① 单值:出生快照,不热更
          valueFrom: { configMapKeyRef: { name: cm, key: K1 } }
      envFrom:
        - configMapRef: { name: cm }  # ② 整表:键名即变量名
          prefix: P_                  #    加前缀防撞名/防污染
      volumeMounts:
        - { name: c, mountPath: /etc/c }        # ③ 目录:每键一文件,~1min 热更
        - { name: c, mountPath: /etc/c/K1, subPath: K1 }   # ④ subPath:单文件,不热更
  volumes:
    - name: c
      configMap: { name: cm, defaultMode: 0644 }
      # Secret 版对照:secret: { secretName: s1, defaultMode: 0400 }
```
- 四种取货方式一张图记住:**单件(valueFrom)/ 整箱(envFrom+prefix)/ 投影成目录(热更)/ 抠一个文件(subPath 冻结)**
