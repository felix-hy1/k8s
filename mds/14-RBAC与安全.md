# 第 14 章 RBAC 与安全(ServiceAccount、kubeconfig、Pod 安全)

> 📁 本章实验资源(yaml / 脚本 / sql)位于 `D:\k8s\14-RBAC与安全\`,本文档位于 `D:\k8s\mds\`。

## 学习目标

1. 理解 K8s 请求全链路:认证(Authentication)→ 授权(Authorization)→ 准入(Admission)
2. 熟练编写 Role/RoleBinding 与 ClusterRole/ClusterRoleBinding
3. 会用 ServiceAccount + Token 生成交付给开发者的受限 kubeconfig
4. 掌握 Pod 安全标准(privileged/baseline/restricted)与 SecurityContext 加固

## 14.1 核心概念

### 请求链路

```
kubectl/客户端 ──► 认证(我是谁:证书/Token/OIDC)
              ──► 授权(RBAC:我能做什么)
              ──► 准入(改/验对象:PodSecurity、Quota...)
              ──► apiserver 落库 etcd
```

### RBAC 四件套

| 对象 | 作用域 | 说明 |
|------|--------|------|
| Role | 单命名空间 | 定义"能对哪些资源做什么操作" |
| RoleBinding | 单命名空间 | 把 Role 绑给 user/group/ServiceAccount |
| ClusterRole | 集群级 | 可绑定集群资源(Node/PV),也可被 RoleBinding 引用(限定单 ns) |
| ClusterRoleBinding | 集群级 | 把 ClusterRole 绑给主体(全域生效) |

规则要素:`apiGroups`(如 `""`,`apps`,`batch`)+ `resources` + `verbs`(get/list/watch/create/update/patch/delete)。

### ServiceAccount(SA)

- Pod 的身份(每个 ns 有默认 SA,default),Pod 里的进程用它访问 apiserver
- 1.24+ 不再自动生成永久 Secret,改为**投影 Token**(短期、可刷新)
- `automountServiceAccountToken: false`:不用 apiserver 的 Pod 应关掉(攻击面收敛)

### Pod 安全标准(PSA)

| 级别 | 含义 |
|------|------|
| privileged | 不限制(运维工具用) |
| baseline | 禁 hostNetwork/hostPID/privileged 等危险项 |
| restricted | 最严:必须非 root、去掉 capabilities、seccomp 等 |

通过给 Namespace 打标签启用:`pod-security.kubernetes.io/enforce: <级别>`。

---

## 实验列表

### 实验 1:ServiceAccount 与"不自动挂载"

```bash
cd /mnt/d/k8s/14-RBAC与安全/manifests
kubectl apply -f lab01-serviceaccount.yaml
# 查看 Pod 里自动挂的 Token(默认行为):
kubectl exec -it sa-default-pod -n rbac-lab -- ls /var/run/secrets/kubernetes.io/serviceaccount
# 对照:sa-no-mount 里没有该目录
```

### 实验 2:Role + RoleBinding(命名空间内授权)

```bash
kubectl apply -f lab02-role-binding.yaml
# 用 --as 模拟用户验证权限(不用真的发证书,超好用):
kubectl get pods -n rbac-lab --as=system:serviceaccount:rbac-lab:pod-reader     # ✅ 允许
kubectl delete pod sa-default-pod -n rbac-lab --as=system:serviceaccount:rbac-lab:pod-reader   # ❌ Forbidden
kubectl get deploy -n rbac-lab --as=system:serviceaccount:rbac-lab:pod-reader   # ❌ Forbidden
# 也可以绑给"真人用户"(证书 CN)或 group,主体三类:user / group / ServiceAccount
```

### 实验 3:ClusterRole(集群级授权)

```bash
kubectl apply -f lab03-clusterrole.yaml
kubectl get nodes --as=system:serviceaccount:rbac-lab:node-viewer               # ✅
kubectl get pods -A --as=system:serviceaccount:rbac-lab:node-viewer             # ❌
# 内置 ClusterRole 复用:view/edit/admin(cluster-admin 是超管,别乱绑)
kubectl get clusterrole view -o yaml | head -20
```

### 实验 4:交付受限 kubeconfig(模拟给外包同学开只读账号)

```bash
bash /mnt/d/k8s/14-RBAC与安全/scripts/gen-user-kubeconfig.sh rbac-lab pod-reader
# 生成的 pod-reader.kubeconfig 只能看 rbac-lab 的 pods
kubectl --kubeconfig pod-reader.kubeconfig get pods -n rbac-lab     # ✅
kubectl --kubeconfig pod-reader.kubeconfig delete pod sa-default-pod -n rbac-lab  # ❌
rm pod-reader.kubeconfig
```

### 实验 5:Pod 安全准入(PSA)

```bash
kubectl apply -f lab04-pod-security-admission.yaml
# restricted ns 会拒绝不合规 Pod:Forbidden ... violates restricted
# baseline ns 会拒绝 privileged: true 的 Pod
```

### 清理

```bash
kubectl delete ns rbac-lab secure-ns
kubectl delete clusterrole node-viewer clusterrolebinding node-viewer-binding
```

## 常见问题

| 问题 | 答案 |
|------|------|
| `--as` 是什么? | 模拟身份调 apiserver(需 impersonate 权限,集群管理员天然有),验证 RBAC 神器 |
| RoleBinding 能绑 ClusterRole 吗? | 能!常用法:把集群级定义的 view 绑到单 ns 使用 |
| Token 会过期吗? | SA 投影 Token 默认 1h 自动续;`kubectl create token` 可指定时长 |
| Pod 访问 apiserver 403? | 检查:用的哪个 SA → 绑定了什么 Role → verbs 是否够 |

## 练习任务

1. [ ] 建一个 `deployment-manager` Role(对 deployments 全权限),绑给新 SA 并验证
2. [ ] 用 `kubectl auth can-i --as=system:serviceaccount:rbac-lab:pod-reader list pods -n rbac-lab` 快速自检
3. [ ] 给 secure-ns 的 restricted 标签换成 audit 模式(`warn`/`audit`),观察放行但告警

## 参考

- https://kubernetes.io/zh-cn/docs/reference/access-authn-authz/rbac/
- https://kubernetes.io/zh-cn/docs/concepts/security/pod-security-standards/
