# 08 Service 服务发现(知识笔记)

> 约定:YAML 示例出自 `~/k8s-lab/08-Service服务发现/manifests/lab00~lab05`;lab05(LoadBalancer)按学习决策只收概念级,不含 MetalLB 配置细节。

## 一、Service 解决什么问题

### 1.1 Pod 的易逝性与寻址矛盾
- Pod 重建即换 IP(10.244.1.10 → 10.244.2.15),名字也变(控制器管理的 Pod)
- 多副本场景:3 个 nginx Pod,客户端记 3 个 IP?IP 还天天变?
- 本质矛盾:**后端是易变的,但客户端需要稳定的访问目标**

### 1.2 Service 的三要素(核心心智)
```
客户端 → Service = 稳定入口(VIP + DNS 名)
                + 健康感知(Endpoints 只含就绪 Pod)
                + 内核转发(kube-proxy 在每节点写规则,随机分发)
```
- 后端怎么生生死死,客户端只认 Service 名字,与后端解耦

## 二、核心机制

### 2.1 VIP 的本质
- VIP(如 10.96.169.204)**不属于任何网卡**,只存在于 iptables/ipvs 规则里
- 推论:**ping VIP 不通是设计行为**(VIP 不响应 ICMP),但 TCP 访问通
- DNS 名格式:`<service>.<namespace>.svc.cluster.local`(同 ns 可用短名)

### 2.2 selector → Endpoints 联动
```
Service(selector: app=web)
  → 系统自动维护 Endpoints 对象(与 Service 同名)
  → 内容 = 所有带该标签且 readiness 通过 的 Pod IP:targetPort
```
- Deployment 扩容 → Endpoints 自动加;Pod 挂了重建换 IP → 自动更新
- **readiness 是进入 Endpoints 的门槛**(第 04 章探针联动):
  - readiness 失败 → 从 Endpoints 摘除 → 摘流(不重启)
  - 恢复 → 重新加入

### 2.3 kube-proxy 转发
- 每个节点都跑 kube-proxy,list-watch Service/Endpoints 变化,在**本节点内核**写转发规则
- 流量路径(容器视角):
```
Pod 内 curl web-svc
  → CoreDNS 解析 → VIP
  → 本节点 iptables 规则命中(KUBE-SERVICES 链)
  → DNAT:目标改写为某 Pod IP:targetPort(随机选择)
  → 直达该 Pod
```
- 转发在**内核态**完成,无中央代理进程 → 高并发能力

### 2.4 iptables vs ipvs 两种模式
| | iptables(默认) | ipvs |
|---|---|---|
| 规则形态 | 线性规则链 | 哈希表 |
| 查找复杂度 | O(n)(Service×Pod 规则全量遍历) | O(1) |
| 调度算法 | 随机概率 | rr/lc/sh 等多种 |
| 适用 | 中小集群 | 大规模( Service 数千+) |
- kind 默认 iptables;生产大集群开 ipvs

## 三、对象结构(lab01 ClusterIP 全解)

### 3.0 配置全文(带注解)
```yaml
apiVersion: v1
kind: Service
metadata:
  name: web-svc
  namespace: svc-lab
spec:
  type: ClusterIP            # 默认值,可省略;集群内可达的 VIP
  selector:
    app: web                 # 圈定后端 Pod 的标签(lab00 的 Deployment 配套)
  ports:
    - name: http             # 端口名(多端口时必填,便于区分)
      port: 80               # VIP 上的端口(客户端访问用)
      targetPort: 80         # 容器端口(= containerPort)
```

### 3.1 三层端口(必考)
```
外部流量 → nodePort(节点端口,30000-32767,NodePort 类型才有)
             ↓
           port(VIP 端口,DNS 访问用)
             ↓
           targetPort(容器端口,进程监听的)
```
| 字段 | 是谁的 | 说明 |
|------|--------|------|
| nodePort | 节点 | 每个节点都开;不写自动分配 |
| port | Service VIP | 客户端敲的门;"营业端口" |
| targetPort | 容器 | 最终送达的门;可写端口名(容器改端口 Service 不用改) |
- port ≠ targetPort 是常见手法:`port: 8080, targetPort: 80` → 客户端敲 8080,落到容器 80
- `curl http://xxx` 不写端口 = HTTP 协议默认 80(不是 Service 补的);敲错端口(如 9999)→ 无规则匹配 → 超时

### 3.2 lab00 演示应用的设计(为什么用 whoami)
```yaml
# Deployment web(replicas: 3)
  containers:
    - image: traefik/whoami:v1.10    # 返回 Hostname 等请求信息
  readinessProbe:
    httpGet: { path: /, port: 80 }   # 就绪才进 Endpoints
```
- whoami 页面自带 Pod 主机名 → 负载均衡"肉眼可见"(每次 curl 返回不同 Hostname)
- readiness 保证"启动中/僵死"的 Pod 不被分配流量
- Service 的 selector 与 Deployment 的 template 标签**必须对上**,否则 Endpoints 空(头号坑)

## 四、Service 类型全景

### 4.1 ClusterIP(lab01)
- 默认类型;集群内 VIP + DNS + 负载均衡
- 内部微服务互调的标准形态

### 4.2 NodePort(lab02)
```yaml
spec:
  type: NodePort
  ports:
    - port: 80
      targetPort: 80
      nodePort: 30080        # 不写自动分配 30000-32767
```
- **ClusterIP 的超集**:VIP 能力保留,额外在每个节点开高位端口
- "每个节点"含义:三节点全开 30080;**Pod 不在的节点也能转发**(流量经集群网络转给 Pod)
- `kubectl get svc` 的 PORT(S) 列:`80:30080/TCP`(两层端口一眼可辨)
- 定位:临时暴露/调试;生产作 LB 底层通道

### 4.3 LoadBalancer(lab05,概念级)
- 语义:向**外部系统**(云厂商/MetalLB)申请一个独立外部 IP
- 云上:云控制器自动创建 SLB/ELB 并回填 EXTERNAL-IP,**无需配置 LB 细节**
- kind 里没云厂商 → EXTERNAL-IP 永远 `<pending>`;MetalLB 只是"扮演云厂商"的软件
- **分层套娃**:LoadBalancer → NodePort → ClusterIP(get svc 输出里 LB 依然带高位端口)
- 局限:一个 Service 一个 LB 太贵 → 生产入口主流是 Ingress(第 09 章)

### 4.4 类型分层叠加关系
```
ClusterIP(基座)
   + nodePort → NodePort
   + 外部 IP  → LoadBalancer
```
- 改 type 不会丢下层能力,只往上叠

### 4.5 Headless(lab03 上)
```yaml
spec:
  clusterIP: None       # ← 唯一区别:不分配 VIP
  selector: { app: web }
```
- DNS 行为:直接返回**所有 Pod IP 列表**(不是 VIP);无 kube-proxy 参与,客户端自选后端
- 每个 Pod 一条专属 DNS:`<pod名>.<svc>.<ns>.svc.cluster.local`(StatefulSet 稳定标识的载体,第 06 章)
- 依然有健康感知(有 selector 就有 Endpoints,readiness 失败照样摘)
- 定位:**ClusterIP 提供"匿名性"(随便找一个),Headless 提供"身份"(找到特定的一个)**;gRPC 长连接/主从互认场景

### 4.6 ExternalName(lab03 下)
```yaml
spec:
  type: ExternalName
  externalName: www.baidu.com
```
- 无 VIP、无 selector、无 Endpoints、无代理——**只是集群 DNS 里的一条 CNAME 别名**
- 流量路径:Pod 拿到 CNAME → 解析真实域名 → **直连外部**(不经过 K8s)
- 用途:给外部服务起个"集群内名字"、迁移期统一连接串

### 4.7 五形态对比总表
| | ClusterIP | NodePort | LoadBalancer | Headless | ExternalName |
|---|---|---|---|---|---|
| VIP | ✅ | ✅ | ✅(+外部IP) | ❌ | ❌ |
| selector/Endpoints | ✅ | ✅ | ✅ | ✅(不经VIP) | ❌ |
| kube-proxy 转发 | ✅ | ✅ | ✅ | ❌(DNS直返) | ❌(纯别名) |
| 访问者 | 集群内 | 集群外 | 集群外 | 客户端自选Pod | 直连外部域名 |
| 一句话 | 匿名负载均衡 | 多开节点门 | 云厂商给门牌 | 暴露身份 | 外部服务贴牌 |

## 五、无 selector Service + 手动 Endpoints(lab04)

### 5.0 配置全文(带注解)
```yaml
# Service:有门面(VIP+DNS),不自动找后端
apiVersion: v1
kind: Service
metadata:
  name: external-db        # ← 与 Endpoints 同名是配对凭证
spec:
  # 没有 selector → 系统不生成 Endpoints
  ports:
    - port: 3306
      targetPort: 3306
---
# Endpoints:手写真实后端(外部 IP)
apiVersion: v1
kind: Endpoints
metadata:
  name: external-db        # ← 必须与 Service 完全同名 + 同 ns
  namespace: svc-lab
subsets:
  - addresses:
      - ip: 172.18.0.1     # 外部服务的真实 IP(任何可达地址)
    ports:
      - port: 3306         # 真实端口(Endpoints 里就叫 port,是终点)
```

### 5.1 配对机制
- Service 与 Endpoints 是**两个独立对象**,靠"同名 + 同命名空间"约定配对(不是字段引用)
- 配对后 kube-proxy 照常生成 VIP→后端 的 DNAT 规则(**真实转发**,区别于 ExternalName)
- 名字差一个字母 → VIP 后面空无一物 → 访问超时

### 5.2 与 ExternalName 对比
| | ExternalName | 无 selector Service |
|---|---|---|
| 机制 | DNS CNAME 别名 | VIP + kube-proxy 真转发 |
| 流量路径 | 直连外部(不经过 K8s) | Pod→VIP→DNAT→外部 IP |
| 目标是域名 | ✅ | ❌(Endpoints 只能写 IP) |
| 端口映射 | ❌ | ✅(port 可 ≠ 外部端口) |
| 多后端负载均衡 | ❌ | ✅(addresses 写多个) |

### 5.3 迁移利器(生产价值)
```
阶段1:Service external-db + 手动 Endpoints → 指向机房老库
阶段2:集群内部署新库,Service 加上 selector(一行改动)
应用连接串 external-db:3306 全程零改动
```

## 六、Endpoints 与 EndpointSlice

### 6.1 Endpoints 的本质
- 一个独立 API 对象(核心组),名字与 Service 相同,内容 = 后端地址列表
- 查看:`kubectl get endpoints <svc名>`;ENDPOINTS 列就是健康后端清单

### 6.2 健康感知链路(探针联动终点站)
```
readiness 连续失败 → Pod Ready=False → EndpointSlice/Endpoints 摘除
→ kube-proxy 更新各节点规则 → 流量不再进入 → 恢复后重新加回
```
- 排错第一问:**endpoints 是不是空的?**
  - 空 → selector 与 Pod 标签不匹配 / Pod readiness 未通过
  - 不空但访问不通 → 查端口(targetPort)/网络策略

### 6.3 EndpointSlice(新一代)
- 单个 Endpoints 对象存上千 IP 会成为性能瓶颈(etcd 单对象上限 + 全量推送)
- EndpointSlice 把后端**切片**(每片默认上限 100 个 IP),Service 由 `kubernetes.io/service-name` 标签关联
- K8s 1.21+ 双写维护,日常两者数据一致

## 七、排错与设计要点

### 7.1 排错链(四步定位)
```
① Pod Ready 吗?         kubectl get pods(看 READY 列)
② Endpoints 有 IP 吗?    kubectl get endpoints <svc>
③ 端口对吗?             describe svc(核对 port/targetPort 与进程监听)
④ 暴露方式对吗?          集群外访问 ClusterIP?nodePort 通不通?
```

### 7.2 设计要点
- 服务间调用一律用 Service 短名(`http://orders`),不写 Pod IP
- 同 ns 用短名,跨 ns 用 `<svc>.<ns>`
- 多端口 Service 必须给每个端口命名
- 外部入口优先 Ingress(第 09 章),NodePort/LB 按需
