# 13 集群网络与 NetworkPolicy(知识笔记)

> 约定:YAML 示例出自 `~/k8s-lab/13-集群网络与NetworkPolicy/manifests/lab01~lab04` 与 `kind-cluster-calico.yaml`,编号与章节对应;本章难点不在 YAML 长度,在"看不见的路径推演"。

## 一、K8s 网络模型与 CNI

### 1.1 四条军规与"大平层"心智
- K8s 网络模型:
  1. 每个 Pod 一个独立 IP,集群内**直通、无 NAT**
  2. kube-proxy 不得影响 Pod 间通信
  3. Pod ↔ 节点互达
  4. Service 提供稳定 VIP/DNS
- 心智模型:**整个集群是一间大平层**——所有 Pod(不管在哪个节点)像插在同一个交换机上,Pod A 直接喊 Pod B 的 IP 就通
- 这是 K8s 与传统虚拟化网络最大的不同,也是 Service/DNS/策略一切设计的地基

### 1.2 三张网(kind 默认)
| 网络 | 网段 | 承载 |
|------|------|------|
| Node 网络 | docker bridge 172.18.0.0/16 | kind"节点容器"互通 |
| Service 网络 | 10.96.0.0/16 | VIP(只存在于 iptables 规则里,**不响应 ping**) |
| Pod 网络 | 10.244.0.0/16 | CNI 分配给每个 Pod |

- Service VIP ping 不通 ≠ 服务不通:VIP 不是一块真网卡,只是转发规则——经典误诊点

### 1.3 CNI:布线工 + 策略执行者
- 大平层要有人布线:Pod 的虚拟网卡谁建、IP 谁分配——**CNI 插件**(装在每个节点上)
- 关键差异:**kind 默认的 kindnet 不支持 NetworkPolicy**;Calico/Cilium 支持(flannel 不支持)
- 策略对象在 kindnet 集群上能 apply 成功但**没人执行**——"策略没生效"排错第一怀疑项就是 CNI 能力

### 1.4 建集群工具辨析:kind 配置 ≠ K8s 清单
```yaml
kind: Cluster                       # ← kind 自己的对象类型
apiVersion: kind.x-k8s.io/v1alpha4  # ← kind 家的 API,与 K8s 无关(kubectl 不认识它)
name: netpol-lab                    # 集群名:节点容器 netpol-lab-*,context 叫 kind-netpol-lab
networking:
  disableDefaultCNI: true           # ★ 不装默认 kindnet(不支持策略),CNI 自己另装 Calico
  kubeProxyMode: iptables           # kube-proxy 用 iptables 模式(Calico 兼容)
nodes:
  - role: control-plane             # 1 控制面 + 2 worker
  - role: worker
  - role: worker
```
| | `kind` 命令 | `kubectl` 命令 |
|--|------------|----------------|
| 干什么 | 建房子:把集群本身造出来 | 住户装修:在已有集群里建资源 |
| 消费 YAML | kind 配置(本文件,apiVersion 是 kind.x-k8s.io) | K8s API 清单(v1 / apps/v1 / networking.k8s.io/v1) |
- 判别法看第二行 apiVersion 属于谁家
- **NotReady 剧情**:建完集群节点全 NotReady 是**预期**(没 CNI 布线);apply Calico 清单(这次才是 kubectl)并等其 Pod Ready 后节点才转 Ready
- kind 内部用 kubeadm 装控制面——生产自建集群的半官方工具就是 kubeadm,云上主流则是托管(ACK/EKS/GKE)

### 1.5 双集群并存
- 两套集群靠 context 切换:`kubectl config use-context kind-netpol-lab` / `kind-k8s-learning`
- **kubectl 打的是哪个集群完全由当前 context 决定**——双集群期最常见事故是 context 切错
- kind 建新集群会自动把当前 context 切到新集群;实验完 `kind delete cluster --name netpol-lab` 省内存

## 二、集群 DNS(CoreDNS)

### 2.1 解析链路
```
容器里的应用 → /etc/resolv.conf(nameserver 10.96.0.10 = CoreDNS 的 Service IP)
  → CoreDNS(住在 kube-system)→ 查出目标 Service 的 ClusterIP → 返回
```

### 2.2 名片规则(必须背)
```
<service>.<namespace>.svc.cluster.local       # Service 全名(FQDN)
<pod-ip-横线>.<namespace>.pod.cluster.local   # Pod 直连名
<pod-name>.<headless-svc>.<ns>.svc.cluster.local   # StatefulSet 专属(06 章)
```
- 同 ns 可用短名(`backend`);跨 ns 用 `backend.net-lab`

### 2.3 resolv.conf 与 ndots:5(短名补全机制)
```
nameserver 10.96.0.10
search net-lab.svc.cluster.local svc.cluster.local cluster.local
options ndots:5
```
- 规则:名字里的点数 < 5 时,系统先拿 search 域逐个拼着试(`backend` → `backend.net-lab.svc.cluster.local` 命中)
- 推论:**查外部域名要写全名并加结尾点号**(`baidu.com.`),否则被拼成 `baidu.com.net-lab.svc...` 白跑三趟——"Pod 里访问外网域名慢/失败"的经典根因

### 2.4 排查工具链
- **busybox 的 nslookup 是残废版**(无 dig、无 SRV、输出怪异)——测 DNS 用官方镜像 `registry.k8s.io/e2e-test-images/jessie-dnsutils:1.3`(正版 bind-utils 全家桶);测连通性用 busybox
- 经验法则:DNS 用 dnsutils,连通用 busybox
- **工具箱 Pod 模式**:`command: ["sleep","3600"]`(直接 argv 形式,不经 sh),容器唯一使命是活着等 exec——排查网络的标准姿势

### 2.5 DNS 排错三连
```bash
kubectl get pods -n kube-system -l k8s-app=kube-dns    # ① CoreDNS 活着吗
kubectl exec -it dnsutils -n net-lab -- nslookup kubernetes   # ② 自带 Service 能解析=链路通
kubectl exec -it dnsutils -n net-lab -- cat /etc/resolv.conf  # ③ 配置对吗(nameserver/search)
```

## 三、NetworkPolicy 语义(本章核心)

### 3.1 反转开关(最重要的一条规则)
> **默认全放行;一旦某 Pod 被任何 Ingress 策略选中,立刻翻转为白名单模式——未显式放行的入口流量全部拒绝。**

```
无策略选中        → 不设防(全通)
被选中 + 零放行规则 → 全锁
被选中 + N 条放行  → 只放 N 条
```
- "选中即入狱,写了什么才能探监什么";拒绝不是写出来的,是"没放行"**推导**出来的(白名单思维,与防火墙 blacklist 相反)

### 3.2 策略叠加取并集(零信任的数学基础)
```
backend 的入口放行集 = default-deny 的放行集(空) ∪ allow-frontend 的放行集
                     = {} ∪ {frontend→backend:8080/TCP}
                     = {frontend→backend:8080/TCP}
```
- 多条策略互不覆盖,放行集取并集 → 生产标准打法:**先 default-deny 关门,再逐条 allow 开窗**(反序会有裸奔窗口)

### 3.3 两种死法(网络排错基本功)
| 现象 | 包层面 | 典型原因 |
|------|--------|----------|
| **timeout(超时)** | 包被**静默丢弃**(DROP) | NetworkPolicy / 防火墙 / 路由不通 |
| **connection refused** | 对方回 RST"端口没人" | 服务没起 / 端口写错 |
- 策略是 DROP 不是 REJECT——**"超时 = 有东西在丢你的包"**,第一怀疑策略
- 实验命令都带 `--timeout=3`:免得默认超时干等

### 3.4 策略管不到的三条路
| 依然畅通的东西 | 原因 |
|----------------|------|
| kubectl exec / logs | 走 apiserver→kubelet **旁路**,不经 Pod 网络数据面(运维通道独立于业务流量;管理面归 14 章 RBAC 管) |
| DNS 解析 | CoreDNS 在 kube-system(没被 net-lab 策略选中);客户端查询是**出向**流量 |
| Pod 出网(Egress) | policyTypes 只写 Ingress 时出向不管 |
- "名字查得到但连接超时"这个组合 = 策略拦截的诊断特征

## 四、两条实战策略逐字段

### 4.1 默认拒绝(零信任基线,lab03 全注解)
```yaml
apiVersion: networking.k8s.io/v1     # 新 API 组:networking
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: net-lab                 # 策略是命名空间级,只管本 ns
spec:
  podSelector: {}                    # 空选择器 = 选中本 ns【全部】Pod
  policyTypes: ["Ingress"]           # 只管进,不管出
                                     # ★ 最关键的缺席:没有 ingress 字段
                                     #   声明了要管 Ingress 又零放行规则 = 入口一律拒绝
                                     #   (写 ingress: [] 同效;拒绝是推导出来的)
```

### 4.2 精确放行(lab04 全注解)
```yaml
spec:
  podSelector:
    matchLabels: { app: backend }    # ① 靶子:这条策略只管 backend(对照 lab03 的全选)
  policyTypes: ["Ingress"]
  ingress:                           # ② 这次字段出现了:带着放行规则
    - from:                          # 来源白名单
        - podSelector:               # 裸 podSelector 来源 = 仅限【同命名空间】
            matchLabels: { app: frontend }
      ports:                         # 端口白名单
        - protocol: TCP
          port: 8080
```
- **双层选择器辨析(头号易混点)**:
  | 选择器 | 位置 | 角色 |
  |--------|------|------|
  | `spec.podSelector` | 策略顶层 | **靶子**(策略作用于谁) |
  | `ingress.from.podSelector` | ingress 里 | **来源**(放谁进来) |
- 读策略顺序:先看顶层圈靶子,再看 ingress 圈访客
- **端口写靶子 Pod 的端口**:检查发生在包到达 Pod 网卡时,Service 的 DNAT 已完成——Service 若写 `port:80 → targetPort:8080`,策略必须写 8080 不是 80(新手经典翻车)

### 4.3 布尔逻辑层级(易错语义)
```
ingress:                      多条规则之间 = OR(任一命中即放行)
  - 规则: from × ports       同一条规则内 = AND(来源、端口都要匹配)
      from:                  多个来源之间 = OR
      ports:                 多个端口之间 = OR
```
- 例:"frontend 的 8080 和 client 的 9090"必须拆成**两条** ingress 规则;写成同一条的两个 from 会变成"frontend 或 client 都能进 8080 或 9090"

### 4.4 from 来源三件套
| 写法 | 放行范围 |
|------|----------|
| `podSelector` | 同命名空间里带匹配标签的 Pod(`{}` = 本 ns 全部) |
| `namespaceSelector` | 匹配标签的整个命名空间的全部 Pod(跨 ns 放行) |
| `ipBlock`(CIDR) | 指定 IP 段(放行外部/节点;Pod CIDR 慎用,Pod IP 易变) |
- 同一 from 条目里 namespaceSelector + podSelector 并列 = **AND**:"某标签 ns 里的某标签 Pod"
- 高频模板——同 ns 互访、跨 ns 全拒:
```yaml
  ingress:
    - from:
        - podSelector: {}        # from 里的空 podSelector = 本 ns 全部 Pod
```

### 4.5 Egress 变体(出向白名单,练习任务参考)
```yaml
spec:
  podSelector: {}
  policyTypes: ["Egress"]
  egress:
    - to:                                  # 只放行 DNS(CoreDNS 在 kube-system)
        - namespaceSelector: {}
      ports:
        - { protocol: UDP, port: 53 }
        - { protocol: TCP, port: 53 }
```
- "默认拒绝出网 + 只放行 DNS 与白名单目标"——对外隔离的标准写法

## 五、实验对象清单的角色设计(lab01/lab02)

### 5.1 角色表(标签即命运)
| 角色 | 标签 | 命运 |
|------|------|------|
| backend ×2 | app: backend | 靶子(lab04 顶层 podSelector 选它) |
| frontend ×1 | app: frontend | 持票者(lab04 from 放行) |
| client | app: client | 没票的(lab04 仍被拒) |
| dnsutils | 无 | 场务工具箱 |
- **策略实验的"通与不通"全部由标签决定**——同一把选择器尺子第五次出场(Service 选 Pod / Deploy 认亲 / 调度亲和 / 策略)

### 5.2 http-echo 与 args vs command(镜像入口知识)
```yaml
      image: hashicorp/http-echo:1.0
      args: ["-text=hello from backend", "-listen=:8080"]   # 只换参数,主程序用镜像的
```
| K8s 字段 | 覆盖 Docker 镜像的 | 用法 |
|----------|---------------------|------|
| `command` | ENTRYPOINT(主程序) | 镜像没入口逻辑时(basybox)写 `sh -c "..."` |
| `args` | CMD(主程序的参数) | 镜像有合理 ENTRYPOINT 时只传参(本例,干净) |
- http-echo:谁访问都复读一句固定文本——**专为网络实验生的复读机**

### 5.3 Service 与策略无关(检查点在 Pod)
```
client wget http://backend.net-lab:8080
  → DNS 查 Service VIP → kube-proxy DNAT 改写成 backend Pod IP
  → 包带"真实目的地 Pod IP"继续走 → 在 backend Pod 网卡上被策略检查
```
- **NetworkPolicy 从头到尾不认识 Service**(策略里只有 podSelector,没有"选 Service")
- Service 是查号台;包一旦上路就是 Pod IP 直达票,策略在终点 Pod 网络栈执法——所以"访问 Service 地址照样被拦"并不矛盾

## 六、零信任三部曲与速查

### 6.1 三部曲(每步一个明确现象)
| 步骤 | 动作 | 现象 |
|------|------|------|
| 实验 2 | 只部署应用,无策略 | 全通(对照组) |
| 实验 3 | 空 podSelector 默认拒绝 | 全部超时,DNS 仍通 |
| 实验 4 | 精确放行 frontend 标签 | frontend 通,client 依旧超时 |
- 方法论:**每加一条策略翻一次现象**——看不见的网络被"可视化"的方式

### 6.2 生产 checklist
- 每个命名空间标配 `default-deny`(Ingress、必要时 Egress),再按业务加 allow——**先关门后开窗**
- 策略生效前提:CNI 支持(Calico/Cilium ✓ / kindnet、flannel ✗)
- 微服务按 ns 隔离:default-deny + allow-same-ns 模板
- 改策略前想清楚双层选择器和 AND/OR;写完用"谁能访问谁"矩阵自查

### 6.3 常见坑速查
| 现象 | 根因 |
|------|------|
| 策略 apply 成功但没效果 | CNI 不支持;或策略没选中目标(顶层 podSelector 不匹配) |
| 访问外网域名慢/失败 | ndots:5 补全;外域要 FQDN + 结尾点号 |
| 全锁死后 exec 还能进 | 正常:exec 走 apiserver 旁路,不是 Pod 网络流量 |
| ping VIP 不通但服务正常 | 正常:VIP 只是 iptables 规则,不响应 ICMP |
| Service port 80 策略写了 80 | 端口要写 targetPort(Pod 真实端口,DNAT 后检查) |
| 想表达"与"关系写成一个 from | from 之间是 OR;AND 要拆多条 ingress 规则 |
