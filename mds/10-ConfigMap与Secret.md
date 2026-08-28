# 第 10 章 ConfigMap 与 Secret(配置与代码分离)

> 📁 本章实验资源(yaml / 脚本 / sql)位于 `D:\k8s\10-ConfigMap与Secret\`,本文档位于 `D:\k8s\mds\`。

## 学习目标

1. 掌握 ConfigMap/Secret 的创建与三种注入方式(env 单值 / envFrom / Volume 挂载)
2. 理解 ConfigMap 热更新的边界(卷挂载会更新,env 和 subPath 不会)
3. 分清 Secret 的常用类型与"base64 不是加密"的安全真相

## 10.1 核心概念

| | ConfigMap | Secret |
|---|-----------|--------|
| 存什么 | 非敏感配置(文本) | 密码、token、证书、镜像仓库凭证 |
| 值限制 | 总量 ≤ 1Mi(大文件要拆分) | 单条 ≤ 1Mi |
| 值编码 | 明文 | base64(只编码,**不加密**) |
| 典型来源 | 字面量、配置文件、目录 | 字面量、文件、`kubectl create tls` 等 |

### 三种注入方式

1. **环境变量**:单个 `valueFrom` 或整表 `envFrom` —— 简单,但**不会热更新**
2. **Volume 挂载**:每键一个文件 —— **自动热更新**(约 1 分钟内同步),程序需自行 reload
3. **subPath 挂载单个文件**:路径固定(方便挂到已有目录),但**不热更新**

### Secret 常用类型

| type | 用途 |
|------|------|
| Opaque | 万能类型(任意键值) |
| kubernetes.io/dockerconfigjson | 镜像拉取凭证(imagePullSecrets) |
| kubernetes.io/tls | TLS 证书+私钥(Ingress 用,见第 09 章) |
| kubernetes.io/basic-auth | 用户名密码 |

> 安全提示:etcd 里的 Secret 应开启静态加密(EncryptionConfiguration);RBAC 控制谁能读;Pod 里避免 env 注入敏感信息(容易被 exec/日志泄漏),优先卷挂载。

---

## 实验列表

### 实验 1:环境变量注入

```bash
cd /mnt/d/k8s/10-ConfigMap与Secret/manifests
kubectl apply -f lab01-configmap-env.yaml
kubectl exec -it env-demo -n cfg-lab -- env | sort | grep -E 'APP|LOG'
# 结论:改 ConfigMap 后 env 不会变(kubectl edit 试一下)
```

### 实验 2:配置文件挂载 + 热更新(重点)

```bash
# 用 files/ 目录生成 ConfigMap(注意 from-file 的键名就是文件名):
kubectl create configmap app-conf -n cfg-lab \
  --from-file=/mnt/d/k8s/10-ConfigMap与Secret/files/nginx.conf --from-file=/mnt/d/k8s/10-ConfigMap与Secret/files/app.properties \
  --from-file=/mnt/d/k8s/10-ConfigMap与Secret/files/ui-config.json --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f lab02-configmap-volume.yaml
kubectl exec -it conf-demo -n cfg-lab -- cat /etc/app/app.properties

# 热更新实验:改 ConfigMap 里的一个值
kubectl edit configmap app-conf -n cfg-lab     # 把 timeout=30 改成 300
sleep 60 && kubectl exec -it conf-demo -n cfg-lab -- cat /etc/app/app.properties
# 文件内容变了!但 nginx 不会自动 reload —— 程序要自己感知(或用 reloader 之类工具)
```

### 实验 3:Secret 的类型与使用

```bash
kubectl apply -f lab03-secret-types.yaml
# Opaque:
kubectl exec -it secret-demo -n cfg-lab -- sh -c 'cat /etc/secret/password; echo'
# 验证 base64 只是编码:
kubectl get secret db-cred -n cfg-lab -o jsonpath='{.data.password}' | base64 -d; echo

# docker-registry 类型(命令式创建,推私有仓库时配合 imagePullSecrets):
kubectl create secret docker-registry my-registry \
  --docker-server=registry.example.com \
  --docker-username=admin --docker-password=admin123 -n cfg-lab --dry-run=client -o yaml | kubectl apply -f -
```

### 清理

```bash
kubectl delete ns cfg-lab
```

## 配套文件(files/ 目录)

| 文件 | 用途 |
|------|------|
| `nginx.conf` | 完整 nginx 配置(挂载替换默认配置的示例) |
| `app.properties` | 键值配置(热更新实验主角) |
| `ui-config.json` | JSON 配置(多格式混合) |

## 常见问题

| 问题 | 答案 |
|------|------|
| 挂载的配置文件是只读的吗? | 是;要写就挂 emptyDir 叠加目录 |
| Pod 起不来报 `CreateContainerConfigError`? | 引用了不存在的 ConfigMap/Secret 或 key 名写错 |
| 怎么知道哪个 Pod 用了我的 ConfigMap? | `kubectl describe configmap xx` 看 Annotations(仅 kubectl edit 产生的会记录) |
| subPath 是什么? | 只挂配置里的某一个文件到指定路径;代价是失去热更新 |

## 练习任务

1. [ ] 用 `kubectl create configmap --from-literal` 三种姿势各建一个 CM 并 diff 产物
2. [ ] 把 nginx.conf 挂成 `/etc/nginx/nginx.conf`(subPath 方式),验证改 CM 不生效
3. [ ] 给 lab03 的 Pod 加 `imagePullSecrets`(用实验 3 建的 my-registry)

## 参考

- https://kubernetes.io/zh-cn/docs/concepts/configuration/configmap/
- https://kubernetes.io/zh-cn/docs/concepts/configuration/secret/
