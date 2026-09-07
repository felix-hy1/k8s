# 14 RBAC 与安全(知识笔记)

> 约定:YAML 示例出自 `~/k8s-lab/14-RBAC与安全/manifests/lab01~lab04`,编号与章节对应。

## 一、安全总览:三道关卡与多层防线

### 1.1 请求的三道关卡(第 02 章链路的落地)
```
kubectl/客户端 → ① 认证(Authentication):我是谁?
              → ② 授权(Authorization):我能对什么资源做什么动作?   ← RBAC
              → ③ 准入(Admission):对象合规吗?改/验后才落库          ← PSA
```
- 401 = 认证失败(不知道你是谁);403 = 认证通过但授权拒绝
- 本章 lab01~03 管关卡②,lab04 管关卡③

### 1.2 多层安全拼图
| 层 | 管什么 | 章节 |
|----|--------|------|
| API 层(RBAC) | 谁能对什么资源做什么动作 | 本章 |
| 准入层(PSA) | 创建的对象是否合规 | 本章 |
| 进程层(SecurityContext) | 容器进程的身份与特权 | 04 章 lab07 |
| 网络层(NetworkPolicy) | Pod 之间能不能通信 | 13 章 |

## 二、认证:我是谁

### 2.1 两种主体
| | User(人/客户端) | ServiceAccount(Pod/程序) |
|---|---|---|
| 凭证 | 客户端证书(CN=用户名) | Token |
| 存放 | kubeconfig | 自动挂载进容器 |
| 级别 | 集群级概念 | **命名空间级对象** |

### 2.2 ServiceAccount 机制(lab01 注解)
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: pod-reader
  namespace: rbac-lab        # SA 是 ns 级对象
---
apiVersion: v1
kind: Pod
metadata:
  name: sa-default-pod
spec:
  serviceAccountName: pod-reader    # 给 Pod 发"工卡"
  containers: [...]
---
apiVersion: v1
kind: Pod
metadata:
  name: sa-no-mount
spec:
  automountServiceAccountToken: false   # 不需要访问 apiserver → 不挂 Token
```
- `serviceAccountName`:指定 Pod 身份;不写则用该 ns 的 default SA(**每个 Pod 天生有身份**)
- 指定 SA 后 kubelet 自动挂载三个文件:
  ```
  /var/run/secrets/kubernetes.io/serviceaccount/
    ├── token      ← 访问 apiserver 的 JWT 凭证
    ├── ca.crt     ← 验证 apiserver 身份
    └── namespace  ← 当前 ns 名
  ```
- **有身份 ≠ 有权限**:SA 创建时零权限,403(而非 401)证明"认出了你但没授权"
- `automountServiceAccountToken: false`:Pod 级关闭(优先级高于 SA 级);不需要 apiserver 的应用应关闭,**收敛攻击面**(最小权限原则)

### 2.3 Token 机制演进
| 时期 | 机制 | 特点 |
|------|------|------|
| ≤1.23 | SA 自动生成永久 Secret | 永不过期,泄漏即永久失守 |
| **1.24+** | **投影 Token**:kubelet 定期申请短期 JWT(默认 1h 自动续期) | 过期作废、可轮转 |
- Token 内编码身份 `system:serviceaccount:<ns>:<sa名>` 与过期时间
- `kubectl create token -n <ns> <sa> --duration=24h` 可手动签发(见第四节)

### 2.4 Pod 内直连 apiserver 的姿势(机制走通)
```bash
TOKEN=$(cat /var/run/secrets/.../token)
wget --header="Authorization: Bearer $TOKEN" \
  https://kubernetes.default.svc/api/v1/namespaces/rbac-lab/pods
# apiserver 在集群内的固定 Service DNS:kubernetes.default.svc
```

## 三、RBAC 授权模型(核心)

### 3.1 心智模型:职位说明书 + 任命书
```
Role(职位说明书)      定义权限(不关心给谁)
RoleBinding(任命书)   subjects(发给谁)+ roleRef(引用哪份说明书)
```
- 职责分离:一份 Role 可被多个 Binding 复用;权限永远定义在集群侧

### 3.2 Role 规则三要素(lab02 注解)
```yaml
apiVersion: rbac.authorization.k8s.io/v1   # RBAC 有自己的 API 组
kind: Role
metadata:
  name: pod-reader
  namespace: rbac-lab       # ns 级对象:权限仅在本 ns 生效
rules:                      # 每条 = apiGroups × resources × verbs
  - apiGroups: [""]                   # "" = 核心组(pod/service/cm/secret...)
    resources: ["pods", "pods/log"]   # 资源 + 子资源
    verbs: ["get", "list", "watch"]   # 只读三连
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list"]
```
- **apiGroups 对照**:核心组 `""` / apps / batch / networking.k8s.io…;一条规则只能同组,多组写多条
- **子资源**(高频坑):`pods/log`(kubectl logs)、`pods/exec`(进容器)、`deployments/scale`、`nodes/metrics`(top node)——只给 pods 不给 pods/log,能 list 不能看日志
- **verbs**:get(查单个)/list(列一批)/watch(订阅)/create/delete/update/patch/`*`;get 与 list 是不同动词
- 多条规则**叠加生效**(任一允许即允许)

### 3.3 RoleBinding(lab02 注解)
```yaml
kind: RoleBinding
metadata:
  name: pod-reader-binding
  namespace: rbac-lab             # 与 Role 同 ns
subjects:                         # 发给谁(列表,可多主体)
  - kind: ServiceAccount          # 三类主体之一
    name: pod-reader
    namespace: rbac-lab           # 引用 SA 必须带 ns(SA 是 ns 级)
roleRef:                          # 引用哪份说明书
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
```
- subjects 三类:
  | kind | 是谁 | 凭证 |
  |------|------|------|
  | ServiceAccount | Pod/程序 | Token |
  | User | 真人 | 证书 CN |
  | Group | 一批用户 | 证书 O / 内置组 |
- **roleRef 创建后不可改**(要换 Role 只能删 Binding 重建)——防误操作悄悄换权

### 3.4 ClusterRole / ClusterRoleBinding(lab03 注解)
```yaml
kind: ClusterRole
metadata:
  name: node-viewer          # ← 没有 namespace(集群级对象)
rules:
  - apiGroups: [""]
    resources: ["nodes", "nodes/metrics"]   # Node 是集群级资源,Role 里写会直接报错
    verbs: ["get", "list", "watch"]
---
kind: ClusterRoleBinding
metadata:
  name: node-viewer-binding  # ← 同样没有 namespace
subjects: [...]
roleRef: { kind: ClusterRole, name: node-viewer }
```
- 与 Role/RoleBinding **模型完全相同,只去掉 ns 边界**
- 为什么需要:Node/PV/StorageClass/Namespace 本身等集群级资源,Role 授权无效
- SA 仍是 ns 级对象(身份住在 ns,权限范围可以全域)——"住在哪"与"权限范围"是两回事

### 3.5 四件套组合矩阵(2×2,只有两种合法)
| Binding↓ \ Role→ | Role | ClusterRole |
|---|---|---|
| RoleBinding(ns 级) | ✅ ns 内授权(标准) | ✅ **把集群级说明书裁剪到本 ns** |
| ClusterRoleBinding(全域) | ❌ 非法 | ✅ 全域授权 |

- **裁剪技巧**(高频):内置 view/edit/admin 都是 ClusterRole;想给某人"只看某 ns",用 RoleBinding(限定 ns)引用 view 即可——**说明书全域复用,任命书的范围决定生效范围**

### 3.6 验证姿势(零成本,必会)
```bash
# --as 扮演身份验证:
kubectl get pods -n rbac-lab --as=system:serviceaccount:rbac-lab:pod-reader
# SA 全局身份格式:system:serviceaccount:<ns>:<sa名>(固定前缀)

# auth can-i 直接问 apiserver:
kubectl auth can-i delete pods -n rbac-lab --as=system:serviceaccount:rbac-lab:pod-reader
# yes / no
```

## 四、受限 kubeconfig 交付(lab04 脚本原理)

### 4.1 解决什么问题
- 管理员 kubeconfig 绝不外发;给外部人员的应是**独立 kubeconfig 文件 + 受限身份的短期 Token**

### 4.2 脚本三步(gen-user-kubeconfig.sh)
```bash
SERVER=$(kubectl config view --minify ... 'server')        # ① 抄公共信息:apiserver 地址
CA=$(... 'certificate-authority-data')                     #    + CA 证书(无 CA 私钥,不泄密)
TOKEN=$(kubectl create token -n rbac-lab pod-reader --duration=24h)   # ② 签发 24h 短期 Token
cat > pod-reader.kubeconfig <<EOF                          # ③ 拼最小 kubeconfig
clusters:  [{ cluster: { server, ca } }]
contexts:  [{ context: { cluster, user, namespace: rbac-lab } }]
users:     [{ user: { token } }]
EOF
```
- 产物结构与管理员 kubeconfig 完全同构(第 03 章:clusters/users/contexts 三段正交),差异只在 users 段装的是受限 SA Token

### 4.3 关键认知
- **kubeconfig 文件本身不含权限**,只携带身份;权限永远在集群侧 RBAC
- 给对方加/收权限 → 改集群里的 Role/Binding,不用重发文件
- 凭证作废 → 等 Token 过期 / 删 SA

## 五、Pod 安全准入 PSA(lab04 实验注解)

### 5.1 机制
- 内置准入控制器(替代已废弃的 PSP):给 **Namespace 贴标签**,强制该 ns 内 Pod 达到安全等级
- 违规 Pod 在 **apply 时被准入拒绝**(Forbidden from server),根本不会创建

### 5.2 三个等级
| 等级 | 要求 |
|------|------|
| privileged | 无限制 |
| baseline | 禁:privileged、hostNetwork/hostPID、危险 capabilities、hostPath… |
| **restricted** | baseline 全禁 + **必须**:非 root、禁提权、drop ALL、seccomp |

### 5.3 三种模式(可叠加)
```yaml
metadata:
  labels:
    pod-security.kubernetes.io/enforce: restricted   # 执法:违规直接拒绝
    pod-security.kubernetes.io/audit: restricted     # 存档:记违规事件
    pod-security.kubernetes.io/warn: restricted      # 提醒:返回警告但不拦
```
- 生产渐进姿势:先 warn/audit 观察存量 → 修完违规 → 切 enforce 强制

### 5.4 restricted 标准答卷(lab04 合规 Pod 注解)
```yaml
spec:
  securityContext:                    # Pod 级
    runAsNonRoot: true                # ①声明非 root
    runAsUser: 1000                   # ②具体 uid
    seccompProfile: { type: RuntimeDefault }   # ③系统调用过滤
  containers:
    - securityContext:
        allowPrivilegeEscalation: false   # ④禁 setuid 提权
        capabilities: { drop: ["ALL"] }   # ⑤清空特权位
```
- **= 第 04 章 lab07 手工配的安全上下文**;当时是"最佳实践",PSA 把它变成"及格线"
- `privileged: true` 是最危险开关(restricted/baseline 都禁),几乎等于交出宿主机 root
- 镜像也要配合(nginx:alpine 支持非 root;普通 nginx 配非 root 起不来)

### 5.5 与三道关卡的关系
```
认证(Token 有效)→ 授权(RBAC 允许 create pods)→ 准入(PSA 检查对象合规)→ 落库
  401 拒绝            403 Forbidden                Forbidden(违反 restricted)
```
- RBAC 拒绝与 PSA 拒绝都显示 Forbidden,但发生在不同关卡

## 六、验证与排错速查
| 现象 | 原因/动作 |
|------|-----------|
| 403 但自认有权限 | `--as` 身份串写错(前缀/ns/名任一不对) |
| 能 get 单个不能列 | verbs 只给了 get 没 list |
| 能看 Pod 不能看日志 | 少 `pods/log` 子资源 |
| Role 写 nodes 报错 | 集群级资源必须 ClusterRole |
| 改 Binding 的 roleRef 不生效 | roleRef 不可变,删了重建 |
| apply Pod 报 "violates PodSecurity" | ns 的 enforce 标签拦截,按 5.4 补字段或调等级 |
| 快速自检 | `kubectl auth can-i <verb> <res> --as=<身份>` |
