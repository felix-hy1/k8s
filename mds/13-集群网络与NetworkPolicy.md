# 第 13 章 集群网络:DNS 与 NetworkPolicy

> 📁 本章实验资源(yaml / 脚本 / sql)位于 `D:\k8s\13-集群网络与NetworkPolicy\`,本文档位于 `D:\k8s\mds\`。

## 学习目标

1. 理解 K8s 网络模型(每 Pod 一 IP、三张网)与 CNI 的角色
2. 熟练使用集群 DNS(CoreDNS):FQDN 规则与排错
3. 用 NetworkPolicy 实现"默认拒绝、按需放行"的零信任安全

## 13.1 核心概念

### K8s 网络模型(4 条军规)

1. 每个 Pod 一个独立 IP,集群内**直通**(无 NAT)
2. 节点上的代理(kube-proxy)不得影响 Pod 间通信
3. Pod → 节点、节点 → Pod 均可达
4. Service 提供稳定的 VIP/DNS

### 三张网

| 网络 | 网段(kind 默认) | 承载 |
|------|------------------|------|
| Node 网络 | docker bridge(172.18.0.0/16) | kind"节点容器"互通 |
| Service 网络 | 10.96.0.0/16 | VIP(iptables 规则) |
| Pod 网络 | 10.244.0.0/16 | CNI 分配给 Pod |

### CNI 与 NetworkPolicy 支持

- kind 默认 CNI 是 **kindnet:轻量但"不支持 NetworkPolicy"**
- 本章实验需另建一套带 **Calico** 的集群(manifests 里已备好配置)

### 集群 DNS 规则(必须背下来)

```
<service>.<namespace>.svc.cluster.local      # 同 ns 可用短名 <service>
<pod-ip-横线>.<namespace>.pod.cluster.local  # Pod 的 PTR/直连名
# StatefulSet 专属(第 06 章用过):
<pod-name>.<headless-svc>.<namespace>.svc.cluster.local
```

### NetworkPolicy 语义

- **默认全部放行**;一旦某 Pod 被**任一 Ingress 策略**选中,其余入口流量全部拒绝(白名单制)
- 策略是**叠加的**:多条策略任一允许即允许;`policyTypes: [Ingress, Egress]` 分别管理进出
- 需要支持 NetworkPolicy 的 CNI 才能真正生效(Calico/Cilium/flannel❌)

---

## 实验列表

### 步骤 0:创建带 Calico 的实验集群

```bash
cd /mnt/d/k8s/13-集群网络与NetworkPolicy/manifests
kind create cluster --config kind-cluster-calico.yaml --wait 60s   # 节点会 NotReady,正常!
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.2/manifests/calico.yaml
kubectl -n kube-system wait --for=condition=ready pod -l k8s-app=calico-node --timeout=300s
kubectl config use-context kind-netpol-lab
kubectl get nodes        # 全部 Ready
```

### 实验 1:DNS 排查工具箱

```bash
kubectl apply -f lab01-dns-test.yaml
kubectl exec -it dnsutils -n net-lab -- nslookup kubernetes           # 能解析=CoreDNS 正常
kubectl exec -it dnsutils -n net-lab -- cat /etc/resolv.conf          # 看 ndots:5(为何要 FQDN 点号结尾)
# 常见排查三连:
kubectl get pods -n kube-system -l k8s-app=kube-dns                   # CoreDNS 活着吗
kubectl exec -it dnsutils -n net-lab -- nslookup web.net-lab          # 短名
kubectl exec -it dnsutils -n net-lab -- nslookup web.net-lab.svc.cluster.local.
```

### 实验 2:部署前后端应用(网络策略的实验对象)

```bash
kubectl apply -f lab02-netpol-apps.yaml
# 验证初始状态(无策略=全通):
kubectl exec -it client -n net-lab -- wget -qO- http://backend.net-lab:8080 | head -1
kubectl exec -it frontend-<tab补全> -n net-lab -- wget -qO- http://backend.net-lab:8080 | head -1
```

### 实验 3:默认拒绝(零信任起点)

```bash
kubectl apply -f lab03-default-deny.yaml
kubectl exec -it client -n net-lab -- wget -qO- --timeout=3 http://backend.net-lab:8080
# 全部超时!DNS 解析仍正常(UDP 53 未被限制)
```

### 实验 4:按标签精确放行

```bash
kubectl apply -f lab04-allow-selective.yaml
# frontend(带 app=frontend 标签)→ 通
kubectl exec -it $(kubectl get pod -l app=frontend -n net-lab -o jsonpath='{.items[0].metadata.name}') -n net-lab -- \
  wget -qO- --timeout=3 http://backend.net-lab:8080 | head -1
# client(不带)→ 依旧拒绝
kubectl exec -it client -n net-lab -- wget -qO- --timeout=3 http://backend.net-lab:8080
```

### 收尾:切回学习集群

```bash
kubectl config use-context kind-k8s-learning
kind delete cluster --name netpol-lab     # 网络实验做完即删,省内存
```

## 常见问题

| 问题 | 答案 |
|------|------|
| Service 名解析失败? | 链路:Pod resolv.conf → CoreDNS → Service;逐层查 nslookup |
| 策略没生效? | CNI 不支持(如 kindnet);或策略没"选中"目标 Pod(podSelector 不匹配) |
| 想拒绝出网(连外网)怎么做? | Egress 策略:只放行 DNS + 指定网段 |
| Pod 能 ping 通 VIP 吗? | Service VIP 只在规则里存在,不响应 ICMP(设计如此) |

## 练习任务

1. [ ] 写一条 Egress 策略:允许 backend 只访问 DNS(UDP/TCP 53),其余出网全拒
2. [ ] 用 `calicoctl`(或 kubectl)查看 Calico 为 backend 生成的实际规则
3. [ ] 在 default ns 建同名 policy,验证"全 ns 零信任"的做法(空白 podSelector)

## 参考

- https://kubernetes.io/zh-cn/docs/concepts/services-networking/dns-pod-service/
- https://kubernetes.io/zh-cn/docs/concepts/services-networking/network-policies/
