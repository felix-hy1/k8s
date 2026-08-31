# 01 环境搭建:WSL2 + Docker + kind(知识笔记)

## 一、kind 是什么

### 1.1 定位与本质
- kind 全称 **Kubernetes IN Docker**,sig 社区维护的本地集群工具
- 核心思想:**用 Docker 容器伪装成 K8s 节点**。每个"节点"其实是一个特权容器(privileged),里面运行着真实的 kubelet、containerd、systemd 等全套组件——不是模拟器、不是玩具,节点内部跑的就是生产同款组件
- 官方用途:Kubernetes 自身的 CI 与一致性测试(每个 PR 都跑 kind);社区用途:本地学习、开发调试、CI 流水线
- 学习价值:因为节点内部组件与生产完全一致(同 kubelet、同 apiserver、同调度器),你在 kind 里学到的排错、调度、网络行为几乎可以无损迁移到真实集群

### 1.2 节点容器的内部构造
一个 kind 节点容器里有什么:

```
┌────── Docker 容器: k8s-learning-worker ──────────┐
│  systemd (PID 1)                                  │
│   ├── containerd        ← 容器运行时               │
│   │    └── 业务 Pod 的容器(嵌套容器,sibling 模式) │
│   └── kubelet           ← 向 apiserver 注册自己    │
└───────────────────────────────────────────────────┘
```
- 节点容器以 `--privileged` 运行(需要操作 cgroup、挂载、网络等内核能力)
- Pod 的容器并非"容器中的容器",而是由节点内的 containerd 直接创建,与节点容器是**兄弟关系**——kubelet 把节点容器当宿主机看待
- 节点容器有独立文件系统,所以 hostPath 卷、daemonset 实验里写的"节点目录"实际落在节点容器的文件系统里(排错时要用 `docker exec` 进去看)

### 1.3 与其他本地方案的对比
| 方案 | 节点形态 | 多节点 | 与生产一致性 | 适用 |
|------|----------|--------|--------------|------|
| kind | Docker 容器 | ✅ 原生支持 | 高(完整 kubelet) | 学习/CI,最接近真实 |
| minikube | 虚机/容器 | 弱(多节点麻烦) | 高但重 | 传统单机体验 |
| k3d(k3s) | Docker 容器 | ✅ | 中(k3s 裁剪版) | 边缘/轻量场景 |
| Docker Desktop K8s | 内置单节点 | ❌ | 低 | 纯入门 |

## 二、建集群的完整过程(kind create 背后)

### 2.1 六个阶段
1. **准备节点镜像**:确保本地有指定版本的 `kindest/node` 镜像(没有则 docker pull;镜像内已打包好对应版本的 kubelet/kubeadm/containerd——**K8s 版本由镜像决定**,换版本=换镜像)
2. **准备网络**:创建/复用名为 `kind` 的 docker bridge 网络(同宿主机多个 kind 集群共用这一个网络,但各自有独立网段内的 IP)
3. **启动控制面容器**:以特权模式运行,内部执行 `kubeadm init`;控制面组件(apiserver/etcd/scheduler/controller-manager)以**静态 Pod** 形式启动;同时按配置生成证书、kubeconfig、以及 apiserver 的对外端口映射
4. **写入 kubeconfig**:把新集群的地址(127.0.0.1 + 分配的宿主机端口)、CA 与客户端证书写进 `~/.kube/config`,生成 context `kind-<集群名>` 并设为 current-context
5. **安装默认组件**:kindnet(CNI)、kube-proxy、CoreDNS、local-path-provisioner(默认 StorageClass `standard`)
6. **逐个加入 worker**:每个 worker 容器内执行 `kubeadm join`,join 过程包括:发现(读 kube-public 的 cluster-info)→ TLS 引导(kubelet 拿到身份证书)→ 注册 Node 对象 → kubelet 开始按指派运行 Pod

### 2.2 镜像与 K8s 版本的对应
- `kindest/node:v1.27.3` ⟺ K8s v1.27.3;kind 二进制有一个"默认镜像"(取决于 kind 版本),也可用 `--image` 显式指定
- 镜像 pull 支持 digest 锁定(kind 报错里那串 `@sha256:...` 就是内容寻址,保证拉到的镜像逐字节一致)

### 2.3 kubeconfig 与 context 的生成
- kind 是少数会**主动维护你 kubeconfig** 的工具:建集群追加 context、删集群移除 context
- apiserver 对外暴露方式:绑定宿主机 127.0.0.1 的一个随机高位端口(所以 `kubectl cluster-info` 显示 `https://127.0.0.1:44851` 这种地址)——多个集群不会抢 6443

## 三、配置文件逐字段原理(kind-cluster.yaml)

### 3.1 文件性质
- apiVersion 是 `kind.x-k8s.io/v1alpha4` —— kind 私有 schema,**不是** K8s 资源;不能被 kubectl apply
- 语义:"集群本身长什么样"(拓扑/网络/端口),与"集群里跑什么"(资源清单)是两个世界

### 3.2 name 与命名派生
一个名字派生出一整套标识:

```
name: k8s-learning
 ├── context:              kind-k8s-learning
 ├── 节点容器:             k8s-learning-control-plane / -worker / -worker2
 ├── HA 时负载均衡容器:     k8s-learning-external-load-balancer
 └── 管理命令参数:          kind delete cluster --name k8s-learning
```

### 3.3 nodes[].role
- `control-plane`:kubeadm init,承载四大件;数量可为多个(HA)
- `worker`:kubeadm join,只跑业务;**控制面默认带污点** `node-role.kubernetes.io/control-plane:NoSchedule`,普通 Pod 不会落上去(第 12 章污点实验的伏笔)
- 学习场景至少 2 个 worker:调度(亲和/打散)与网络(NetworkPolicy 跨节点)实验需要真实拓扑

### 3.4 extraPortMappings 原理
- 本质等同 `docker run -p`:把**宿主机**(这里是 WSL2)端口转发到**该节点容器**的端口
- 学习集群把 80/443 映射到控制面,配合 ingress-nginx 实验形成完整链路:

```
Windows 浏览器 http://demo.local
   → (hosts 解析到 127.0.0.1)
   → WSL2 的 localhost 转发(WSL 特性)
   → 宿主机 80 端口(docker-proxy)
   → 控制面容器 80(ingress-nginx 监听)
   → 按 Ingress 规则转发到后端 Pod
```
- 约束:宿主机端口必须空闲,否则 create 阶段直接报端口占用失败;这也是为什么映射要开在控制面(ingress-nginx 官方 kind 清单通过 nodeSelector 把 controller 钉在带 ingress-ready 标签的控制面上)

### 3.5 kubeadmConfigPatches
- kind 底层用 kubeadm 装集群;kubeadm 自己有配置 API(InitConfiguration/ClusterConfiguration/JoinConfiguration/KubeletConfiguration)
- patches 允许把这些段的任意字段**合并注入**。典型用例:
  - 给 kubelet 加 `--node-labels=ingress-ready=true`(打标签)
  - 修改证书 SAN、禁用某组件、注入 kubelet 配置
- YAML 写法 `- |` 是**字面块标量**:下面整段缩进文本作为一个字符串整体传入(内部的 `kind:` 属于 kubeadm 的配置,与外层 kind 工具无关,初学最容易在这里绕晕)
- EDA 项目的配置里还用了另一种 patch(containerdConfigPatches),用来给节点内 containerd 配私有仓库镜像源——原理相同:往节点内的配置文件里注入段落

### 3.6 networking 可配项(学习集群未写=全默认)
| 字段 | 作用 | 默认 |
|------|------|------|
| apiServerAddress | apiserver 绑定的宿主机地址 | 127.0.0.1 |
| apiServerPort | apiserver 绑定的宿主机端口 | **随机分配**(EDA 项目固定 6443 就是为了可预测) |
| serviceSubnet | Service VIP 网段 | 10.96.0.0/16 |
| podSubnet | Pod IP 网段 | 10.244.0.0/16 |
| disableDefaultCNI | 禁用 kindnet | false(NetworkPolicy 实验必须 true 换 Calico) |
| kubeProxyMode | ipvs/iptables/none | iptables |

### 3.7 默认组件全景
| 组件 | 提供方 | 备注 |
|------|--------|------|
| kindnet | kind 内置 CNI | 极简 host-gw 方式,**不支持 NetworkPolicy** |
| CoreDNS | 官方 addon | 集群 DNS,双副本 |
| kube-proxy | 标准 | iptables 模式 |
| standard StorageClass | local-path-provisioner | 动态供给:PVC→hostPath,回收策略 Delete |

## 四、高可用(HA)集群原理

### 4.1 etcd 的 Raft 与 quorum
- etcd 是强一致 KV,写入需**多数派(quorum)确认**:N 成员的 quorum = ⌈(N+1)/2⌉
- 容错公式:可容忍故障数 = (N-1)/2 → 3 容忍 1、5 容忍 2、7 容忍 3
- **必须奇数**:4 成员 quorum 是 3,容忍度仍 1(和 3 一样),多花一倍资源零收益;6 成员容忍度仍 2(和 5 一样)
- 失去 quorum 的后果:etcd 只读,apiserver 无法写入 → 集群"冻结"(已运行 Pod 不受影响)

### 4.2 堆叠式与外置式 etcd
| 形态 | 结构 | 优缺点 |
|------|------|--------|
| 堆叠式(stacked) | 每个控制面节点同时跑 apiserver + etcd | 部署简单、省机器;k8s/kubeadm 默认;节点故障同时损失 apiserver 和 etcd 成员 |
| 外置式(external) | etcd 独立集群,apiserver 全部外连 | 故障域分离、更稳;成本高、运维复杂 |

### 4.3 kind 的 HA 实现
- 3 个 control-plane 节点容器即堆叠式 HA
- kind 自动创建一个 **nginx 负载均衡容器**:`<集群名>-external-load-balancer`,监听 apiServerPort,后端挂所有控制面的 6443 → kubeconfig/kubelet/后续 join 都指向 LB,免去手动搭负载均衡
- 验证方式(知识层面):HA 集群 `docker ps` 能看到 LB 容器;停掉任一控制面,集群仍可读写(apiserver 层)且 etcd 仍有 quorum

## 五、WSL2 环境原理(踩坑背后的机制)

### 5.1 WSL2 的网络模型
- WSL2 是轻量级 VM(不是进程模拟),默认 **NAT 模式**:WSL 有独立虚拟网卡与内网网段,出网经 Windows NAT 转发
- Windows → WSL:默认开启 localhost 转发(Windows 访问 127.0.0.1:port 可达 WSL 内监听的同端口服务)——这是"浏览器访问 localhost 就能进 kind"的基础
- WSL → Windows:不走代理时直连外网;**Windows 上设置的代理不会自动被 WSL 继承**

### 5.2 代理与 autoProxy 的作用域
- `.wslconfig` 里 `autoProxy=true`:把 Windows 的系统代理同步为 WSL 内**登录/交互 shell 的环境变量**(http_proxy 等,常见值 127.0.0.1:7890)
- 关键限制:**环境变量只随 shell 会话传播**。dockerd、containerd 等 systemd 服务有自己的环境,不读 shell 变量 → 表现为"shell 里 curl 通,docker pull 超时"
- 修复原理:给 dockerd 配 systemd drop-in(proxy.conf)注入代理环境变量;NO_PROXY 必须覆盖内网段与本地私有 registry,否则集群内部通信被代理劫持

### 5.3 mirrored(镜像)网络模式
- WSL2 新模式:WSL 与 Windows 共享网卡与 IP(loopback 互通、支持 IPv6)
- 副作用:容器/工具对 localhost、IPv6(`::1`)的解析行为改变,与部分工具存在兼容问题;排查问题时可作为变量之一,但**不要一上来就归咎于它**(经验教训:曾误判)

### 5.4 inotify 机制与耗尽
- inotify 是 Linux 内核的文件系统事件通知机制;`fs.inotify.max_user_instances`(默认 128)限制**每用户可创建的 inotify 实例数**,`max_user_watches` 限制监视的条目数
- 大量容器/开发工具(vite、容器里的 fsnotify)都会消耗实例;配额耗尽后新实例创建失败 → kubelet 启动时报 `too many open files` 而崩溃(healthz 端口无人监听 → kubeadm join 检测"kubelet isn't running")
- 调大即恢复(sysctl),无需重启;注意报错表面([::1]:10248 refused)与根因(inotify)可能相距很远——**排错要抓到组件内部日志再下结论**

### 5.5 PATH 查找顺序
- shell 执行命令时按 PATH **从左到右**找第一个可执行文件
- `~/.local/bin` 这类用户级目录常排在 `/usr/local/bin` 前 → 装了新版到 /usr/local/bin 但行为不变,其实是旧版遮蔽
- 排查意识:`which -a <cmd>` 列出所有命中,而不是 `which <cmd>` 只看第一个

## 六、多集群并存的隔离模型

### 6.1 隔离的层次
| 层 | 隔离内容 |
|----|----------|
| 容器 | 每个集群独立的节点容器集合 |
| 网络 | 各自 apiserver 绑定不同宿主机端口 |
| 数据 | 独立 etcd,资源互不可见 |
| 身份 | 独立 context(独立证书) |

### 6.2 风险点:current-context 是全局状态
- kubectl 的"当前集群"存在 kubeconfig 里,是**跨终端共享的全局状态**——任何一个脚本/终端切了 context,其他终端裸敲的命令都会跟着变
- 典型事故:自动化脚本(如 EDA 部署脚本)在不知情时把资源发到学习集群(或反过来),ns/对象"神秘出现"
- 防御意识:操作前确认 context;自动化里显式 `--context`;重要项目用专用 kubeconfig 文件隔离(`KUBECONFIG` 环境变量或 `--kubeconfig`)
