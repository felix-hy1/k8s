# 第 18 章 CRD 与 Operator(扩展 Kubernetes)

> 📁 本章实验资源(yaml / 脚本 / sql)位于 `D:\k8s\18-CRD与Operator\`,本文档位于 `D:\k8s\mds\`。

## 学习目标

1. 理解 CRD/CR:给 K8s 增加"自己的资源类型"
2. 理解自定义控制器的 Informer → WorkQueue → Reconcile 循环
3. 会声明和使用一个 Website CRD;了解 Operator 的生产开发路径

## 18.1 核心概念

### CRD 与 CR

- **CRD(CustomResourceDefinition)**:向 apiserver 注册新资源类型,立刻获得:REST API(`/apis/apps.example.com/v1/namespaces/*/websites`)、存储、RBAC、kubectl 支持
- **CR(Custom Resource)**:该类型的实例,可 `kubectl get/edit/apply`
- 没有 CRD,apiserver 不认识这个资源;**没有控制器,CR 就只是一条死数据**

### 自定义控制器(Operator 的引擎)

```
Informer(list-watch apiserver) ──变更事件──► WorkQueue ──► Reconcile(期望 vs 实际)
     ▲                                                        │
     └─────────────── 写回 status / 创建管理资源 ◄────────────┘
```

Reconcile 要点:**幂等、不看事件细节只看最终态、失败重试**。

### Operator = CRD + 控制器

把"运维专家知识"(部署、扩缩、备份、故障恢复)编码成控制器,典型:MySQL Operator、Redis Operator、Prometheus Operator(第 16 章的 ServiceMonitor/PrometheusRule 就是它的 CR!)。

生产开发三件套:
- **kubebuilder**:官方脚手架(Go)
- **Operator-SDK**:Red Hat 出品,支持 Go/Ansible/Helm
- 前置知识:Go + controller-runtime(本手册带你入门,深入见练习)

---

## 实验列表

### 实验 1:注册 Website CRD

```bash
cd /mnt/d/k8s/18-CRD与Operator/manifests
kubectl apply -f lab01-crd-website.yaml
kubectl get crd websites.apps.example.com
kubectl explain website.spec         # 自动生成了字段说明!
kubectl api-resources | grep website
```

### 实验 2:创建并操作 CR(无控制器)

```bash
kubectl apply -f lab02-website-cr.yaml
kubectl get websites -n crd-lab
kubectl get website my-site -n crd-lab -o yaml    # 只有 spec,没有 status(没控制器写)
kubectl get website my-site -n crd-lab -o jsonpath='{.spec}'
# CR 也能被 kubectl 常规操作:
kubectl edit website my-site -n crd-lab           # 改 replicas 试试(没人响应它)
```

> 对照:第 06 章的 StatefulSet 之所以"活",就是因为 kube-controller-manager 里有它的控制器。
> 这里的 Website 不会真的创建 Pod —— 这正是下一步 Operator 要补上的部分。

### 实验 3:看一个 Operator 的 RBAC 长什么样

```bash
kubectl apply -f lab03-operator-rbac.yaml   # 只是权限声明(没有控制器进程,不产生副作用)
kubectl describe clusterrole website-operator-role | less
# 一个 Website 控制器至少要:读写 websites(CR)+ 管理 pods/services
```

### 实验 4(选做):体验真正的社区 Operator

```bash
# 以 etcd-operator 思路演示官方文档例子(可跳过)
# 真实可装的例子见第 16 章:prometheus-operator 的 CR 已在用
kubectl get servicemonitors -A       # Prometheus Operator 的 CR,现成的"CRD 在工作"证据
```

### 清理

```bash
kubectl delete ns crd-lab
kubectl delete crd websites.apps.example.com
kubectl delete clusterrole website-operator-role clusterrolebinding website-operator-binding --ignore-not-found
```

## 自己动手写控制器(kubebuilder 起点)

```bash
# 环境:Go 1.22+(WSL 内安装:sudo apt install -y golang-go 或官方 tar 包)
go install sigs.k8s.io/kubebuilder/v4@latest
mkdir website-operator && cd website-operator && git init
kubebuilder init --domain example.com --repo github.com/you/website-operator
kubebuilder create api --group apps --version v1 --kind Website
# 生成的 internal/controller/website_controller.go 里实现 Reconcile:
#   依据 Website.spec 创建/对齐 Deployment + Service,并回写 status
make manifests          # 生成 CRD yaml
make install run        # 装 CRD 并本地跑控制器
```

## 常见问题

| 问题 | 答案 |
|------|------|
| CRD 和 CM 差在哪? | CM 是配置数据;CRD 是"新的资源类型"(有 API、有状态机) |
| CRD 能存多少数据? | etcd 限制单对象 ~1.5MB,大字段放外部存储 |
| 删除 CRD 会怎样? | 该类型所有 CR 级联删除(数据没了,慎操作) |
| Operator 与 Helm 区别? | Helm 负责"装",Operator 负责"装+日常运维(自愈/备份/扩缩)" |

## 练习任务

1. [ ] 给 Website CRD 加字段 `size`(string),并给 replicas 配 minimum=1/maximum=20
2. [ ] `kubectl get --raw /apis/apps.example.com/v1/namespaces/crd-lab/websites | jq` 直连 REST API
3. [ ] (进阶)用 kubebuilder 把 Reconcile 写出来:按 Website 创建同名 Deployment

## 参考

- https://kubernetes.io/zh-cn/docs/concepts/extend-kubernetes/api-extension/custom-resources/
- https://book.kubebuilder.io/
