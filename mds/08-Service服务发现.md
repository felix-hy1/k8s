# 第 08 章 Service 服务发现(东西向流量)

> 📁 本章实验资源(yaml / 脚本 / sql)位于 `D:\k8s\08-Service服务发现\`,本文档位于 `D:\k8s\mds\`。

## 学习目标

1. 理解 Service 存在的意义(VIP → Pod 的负载均衡)与 kube-proxy 原理
2. 分清 port / targetPort / nodePort,掌握四种 Service 类型
3. 理解 Endpoints/EndpointSlice 与"无选择器 Service"
4. 在 kind 里用 MetalLB 玩转 LoadBalancer

## 8.1 为什么需要 Service

Pod 是易逝的:重建即换 IP、随时扩缩。Service 提供**稳定的虚拟 IP(VIP)+ DNS 名**,通过标签选择器把流量负载均衡到一组健康 Pod(靠 readinessProbe 判断健康)。

```
client → Service VIP(10.96.x.x)→ kube-proxy iptables/ipvs 规则 → Pod1 / Pod2 / Pod3
```

- DNS 名:`<service>.<namespace>.svc.cluster.local`(同 ns 可只用短名)
- 转发由**每个节点的 kube-proxy** 实现,不经过 apiserver,性能好

## 8.2 四种类型对比

| 类型 | 访问范围 | 原理 | 典型用途 |
|------|----------|------|----------|
| ClusterIP(默认) | 集群内 | 集群 VIP + iptables | 内部微服务互调 |
| NodePort | 集群外(节点 IP:30000-32767) | 每个节点开一个端口 → ClusterIP | 临时暴露、学习 |
| LoadBalancer | 公网 | 云厂商 LB → NodePort → ClusterIP;kind 用 MetalLB 模拟 | 生产入口 |
| ExternalName | 集群内访问外部 | 只返回 CNAME,无 VIP | 依赖外部服务的别名 |
| Headless(clusterIP: None) | 直接拿 Pod IP 列表 | 无 VIP,DNS 返回所有 Pod IP | StatefulSet、客户端自负载均衡 |

## 8.3 三个端口别搞混

```
外部 → nodePort(节点上开的端口,30000-32767)
        ↓
      port(Service 的 VIP 端口,DNS 访问用)
        ↓
      targetPort(容器端口,对应 containerPort)
```

---

## 实验列表

### 实验 0:部署演示应用(3 副本,页面自带 Pod 名)

```bash
cd /mnt/d/k8s/08-Service服务发现/manifests
kubectl apply -f lab00-demo-app.yaml
kubectl get pods -n svc-lab -o wide
```

### 实验 1:ClusterIP

```bash
kubectl apply -f lab01-clusterip.yaml
kubectl get svc -n svc-lab
# 集群内访问,反复 curl 观察负载均衡到不同 Pod:
kubectl run curl --rm -it --image=curlimages/curl:8.10.1 --restart=Never -n svc-lab -- \
  sh -c 'for i in 1 2 3 4 5 6; do curl -s web-svc.svc-lab; echo; done'
# 看 VIP 背后的 Endpoints:
kubectl get endpoints web-svc -n svc-lab
```

### 实验 2:NodePort

```bash
kubectl apply -f lab02-nodeport.yaml
kubectl get svc web-np -n svc-lab        # 记下 30xxx 端口
# 拿任意节点 IP(kind 节点是 WSL 里的 docker 容器,WSL 内可直接访问):
kubectl get nodes -o wide                # 取 INTERNAL-IP
curl http://<节点IP>:<30xxx端口>          # WSL 终端里执行
# 原理:三个节点都开了这个端口,打到谁都能转发到 Pod
```

### 实验 3:Headless 与 ExternalName

```bash
kubectl apply -f lab03-headless-externalname.yaml
# Headless:DNS 返回所有 Pod IP(而不是 VIP)
kubectl run dns --rm -it --image=busybox:1.36 --restart=Never -n svc-lab -- nslookup web-headless
# ExternalName:只是个别名(CNAME → baidu.com)
kubectl run curl --rm -it --image=curlimages/curl:8.10.1 --restart=Never -n svc-lab -- \
  curl -sI my-external.baidu.com | head -3
```

### 实验 4:无选择器 Service + 手动 Endpoints(代理外部服务)

```bash
kubectl apply -f lab04-manual-endpoints.yaml
# Service 名与 Endpoints 名必须一致;endpoints 指向"外部 IP"
# 这里演示把 WSL 宿主机(docker 网关 172.17.0.1 或 host.docker.internal)当作外部服务
kubectl describe svc external-db -n svc-lab
kubectl get endpoints external-db -n svc-lab
```

### 实验 5:MetalLB + LoadBalancer(kind 模拟云 LB)

```bash
# 1) 安装 MetalLB(组件就绪需 ~30s)
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.5/config/manifests/metallb-native.yaml
kubectl -n metallb-system wait --for=condition=ready pod -l app=metallb --timeout=180s

# 2) 找出 kind docker 网络的子网,生成地址池(把输出抄进 lab05 的 addresses)
SUBNET=$(docker network inspect kind -f '{{(index .IPAM.Config 0).Subnet}}')
echo "建议地址池: ${SUBNET%.*.*}.255.200-${SUBNET%.*.*}.255.250"

# 3) 修改 lab05-metallb-lb.yaml 里的 addresses 后 apply
kubectl apply -f lab05-metallb-lb.yaml
kubectl get svc web-lb -n svc-lab        # EXTERNAL-IP 从 <pending> 变成池内 IP
curl http://<EXTERNAL-IP>                # WSL 内访问
```

### 观察 kube-proxy 规则(进阶)

```bash
docker exec k8s-learning-worker iptables-save | grep "web-svc" | head -5
# 能看到 VIP 随机(概率)分发到各 Pod IP 的规则
```

### 清理

```bash
kubectl delete ns svc-lab
kubectl delete -f https://raw.githubusercontent.com/metallb/metallb/v0.14.5/config/manifests/metallb-native.yaml
```

## 常见问题

| 问题 | 答案 |
|------|------|
| Service 访问不通? | 排查链:Pod Ready?→ endpoints 有 IP?→ selector 标签匹配?→ targetPort 对? |
| endpoints 是空的? | selector 没匹配上任何 Pod,或 Pod readiness 未通过 |
| LB 一直 `<pending>`? | 没装 MetalLB 或地址池没配/配错子网 |
| sessionAffinity? | `service.spec.sessionAffinity: ClientIP` 可让同一客户端固定打到一个 Pod |

## 练习任务

1. [ ] 把实验 1 的某个 Pod readiness 弄失败(改探针),观察它被从 endpoints 摘除
2. [ ] 给 web-svc 加 `sessionAffinity: ClientIP`,连续 curl 验证结果固定
3. [ ] 思考:Headless Service 的 DNS 返回 IP 列表,谁来负载均衡?(答:客户端自己)

## 参考

- https://kubernetes.io/zh-cn/docs/concepts/services-networking/service/
