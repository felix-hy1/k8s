# 第 09 章 Ingress 入口流量(南北向七层)

> 📁 本章实验资源(yaml / 脚本 / sql)位于 `D:\k8s\09-Ingress入口流量\`,本文档位于 `D:\k8s\mds\`。

## 学习目标

1. 理解 Ingress 与 Service 的分工:四层转发 vs 七层路由
2. 安装 ingress-nginx(kind 专用清单)
3. 掌握按 Path 路由、按域名路由、TLS 三件套

## 9.1 核心概念

```
浏览器 → host: demo.local
          │
          ▼
Ingress Controller(ingress-nginx Pod,监听 80/443)
          │ 读取 Ingress 规则(host + path)
          ▼
   ┌──────┴──────┐
   ▼             ▼
Service app1   Service app2      ← Ingress 只认 Service
   └→ Pod×2      └→ Pod×2
```

- **Ingress**:一条 API 规则(七层路由表),本身不干活
- **Ingress Controller**:真正收流量的反向代理(nginx),watch Ingress 规则生成 nginx.conf
- 常见 Controller:ingress-nginx(官方 nginx 版)、Traefik、HAProxy、apisix 等
- 能力:域名/路径路由、TLS 终结、虚拟主机、限流、rewrite、灰度(按 header/cookie)等

## 9.2 与 Service 的关系

Ingress **不能替代 Service**:它把流量转给 Service 的 endpoints(实为直接到 Pod)。Service 通常是 ClusterIP 就够。

---

## 实验列表

### 步骤 1:安装 ingress-nginx(kind 版)

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
kubectl -n ingress-nginx wait --for=condition=ready pod -l app.kubernetes.io/component=controller --timeout=180s
# 因第 01 章的 extraPortMappings,现在 WSL/Windows 里 curl localhost 已经能打到控制器:
curl -s http://localhost   # 预期 404(还没配规则)
```

### 步骤 2:部署两个演示应用(app1 / app2)

```bash
cd /mnt/d/k8s/09-Ingress入口流量/manifests
kubectl apply -f lab01-demo-apps.yaml
```

### 实验 1:按路径路由

```bash
# 把域名写进本机 hosts(Windows 管理员记事本编辑,或 WSL 内):
echo "127.0.0.1 demo.local" | sudo tee -a /etc/hosts

kubectl apply -f lab02-path.yaml
kubectl get ingress -n ing-lab
# 浏览器或 curl 验证:
curl -s http://demo.local/app1/     # 返回 app1 页面
curl -s http://demo.local/app2/     # 返回 app2 页面
```

### 实验 2:按域名路由

```bash
echo "127.0.0.1 a.demo.local b.demo.local" | sudo tee -a /etc/hosts
kubectl apply -f lab03-host.yaml
curl -s -H "Host: a.demo.local" http://localhost/    # app1
curl -s -H "Host: b.demo.local" http://localhost/    # app2
# 浏览器访问 a.demo.local 也能区分
```

### 实验 3:TLS(自签证书)

```bash
bash /mnt/d/k8s/09-Ingress入口流量/scripts/gen-tls.sh demo.local          # 生成证书并创建 Secret tls demo-tls
kubectl apply -f lab04-tls.yaml
curl -sk https://demo.local/app1/              # -k 忽略自签告警
kubectl get secret demo-tls -n ing-lab -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -subject
```

### 常用注解(ingress-nginx)

```yaml
nginx.ingress.kubernetes.io/rewrite-target: /$2     # 重写路径
nginx.ingress.kubernetes.io/ssl-redirect: "true"    # 强制跳 HTTPS
nginx.ingress.kubernetes.io/canary: "true"          # 金丝雀灰度(配合 canary-weight)
nginx.ingress.kubernetes.io/limit-rps: "10"         # 限流
```

### 清理

```bash
kubectl delete ns ing-lab
kubectl delete -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
sudo sed -i '/demo.local/d' /etc/hosts
```

## 常见问题

| 问题 | 答案 |
|------|------|
| 404 Not Found? | 域名没匹配上(Host 头不对)或 path 写错;`kubectl describe ingress` 核对 |
| 503 Service Unavailable? | 后端 Service 没就绪/endpoints 为空 |
| localhost 打不通? | kind 集群没配 extraPortMappings,或 80 被别的进程占用 |
| pathType 区别? | Prefix(前缀匹配)、Exact(精确)、ImplementationSpecific |

## 练习任务

1. [ ] 加一条 rewrite 注解,把 `/old/(.*)` 重写到 `/$1`
2. [ ] 用 canary 注解把 20% 流量发给 app2(配两个 Ingress 同 host)
3. [ ] `kubectl exec` 进 controller Pod,看它生成的 nginx.conf:`kubectl exec -n ingress-nginx <controller-pod> -- cat /etc/nginx/nginx.conf | grep demo.local -A5`

## 参考

- https://kubernetes.io/zh-cn/docs/concepts/services-networking/ingress/
- kind+ingress 官方指南:https://kind.sigs.k8s.io/docs/user/ingress/
