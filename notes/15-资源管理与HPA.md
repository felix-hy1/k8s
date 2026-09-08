# 15 资源管理与 HPA(知识笔记)

> 约定:YAML 示例出自 `~/k8s-lab/15-资源管理与HPA/manifests/lab01~lab03`,编号与章节对应;标注【实况】为实验运行的真实结果与文档未覆盖的坑。

## 一、资源限制的两种死法(04 章结论的亲手验证)

### 1.1 双轨语义(总纲)
| | requests(预留) | limits(上限) |
|--|----------------|--------------|
| 服务对象 | 调度器(12 章:过滤标尺) | 内核 cgroup(运行时) |
| HPA 中的角色 | **百分比公式的分母** | 与 HPA 无关 |
| 超限后果 | 放不下 → Pending | CPU 节流 / 内存 OOMKill |
- 单位:CPU `1`=1 核、`1000m`=1 核、`100m`=0.1 核;内存 `Mi`=2^20、`Gi`=2^30

### 1.2 CPU 节流:可压缩资源的"软死法"(lab01 cpu-burn 实况)
```yaml
    command: ["sh", "-c", "while true; do :; done"]   # 纯 CPU 死循环
    resources:
      requests: { cpu: 50m, memory: 32Mi }
      limits: { cpu: 100m, memory: 64Mi }     # 最多 0.1 核
```
- 【实况】死循环想要一整核,top 读数**永远摁在 101m**(≈limit)——这就是节流铁证
- 状态永远 Running、0 重启:**CPU 时间片可让出可补回,超限不杀进程,设计如此**
- 实战推论:**"服务莫名变慢但一切正常" → 第一眼看 top 的 CPU 是否贴着 limit**——不报错不重启,生产疑难杂症之首

### 1.3 OOMKilled:不可压缩资源的"硬死法"(lab01 mem-burn 实况)
```yaml
      # 脚本:每秒往 shell 变量塞 ~1.3MB(1MB zero 过 base64 膨胀 33%),爬向 100Mi limit
      limits: { cpu: 50m, memory: 100Mi }     # 越线即杀
```
- 【实况】内存从 22Mi 爬到 100Mi 约 1~2 分钟 → 越线瞬间:
```
Last State: Terminated
  Reason: OOMKilled        ← 死因
  Exit Code: 137           ← 128+9 = SIGKILL(内核出手,区别于应用自己 exit 1)
```
- restartPolicy Always → 重启后又从零爬 → **RESTARTS 持续上涨**(CrashLoopBackOff 的表亲,设计出来的循环)
- 内存超限必杀:已分出去的页面收不回来;处置二选一:调大 limit 或查内存泄漏

### 1.4 一软一硬对照表
| | CPU 节流 | OOMKilled |
|--|----------|-----------|
| 资源性质 | 可压缩 | 不可压缩 |
| 现象 | 状态正常、吞吐被掐 | 重启循环、exit 137 |
| 可观测 | top 贴 limit | describe Last State |
| 生产比喻 | 难排查(不报错) | 好排查(会死给你看) |

## 二、metrics-server(top 与 HPA 的数据源)

### 2.1 是什么
- 集群里"报数的人":定期从各节点 kubelet 聚合 CPU/内存实际用量,暴露成 Metrics API
- 没有它:`kubectl top` 报错、**HPA 指标 unknown 罢工**——两者共用这一个数据源

### 2.2 安装(kind 必打补丁)
```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl patch deployment metrics-server -n kube-system --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
kubectl -n kube-system wait --for=condition=available deployment/metrics-server --timeout=180s
```
- `--kubelet-insecure-tls` 是 **kind 特有**:kind 节点的 kubelet 证书自签,直连校验失败;生产集群不需要
- 验证:`kubectl top nodes` / `kubectl top pods -A` 出真实读数即成

### 2.3 【实况】下载清单的代理坑
- 现象:非交互 shell(`bash -c` 直跑)里 apply GitHub 清单报 `TLS handshake timeout`
- 原因:**/etc/profile.d 的代理变量只在交互登录 shell 加载**,直连 GitHub 超时
- 处理:命令前显式 `export https_proxy=... http_proxy=... no_proxy=localhost,127.0.0.1`,或在正常打开的终端里跑

## 三、治理三层栈(全局图)

```
04 章 QoS        → 单 Pod 级:驱逐顺位(由 requests/limits 推导)
15 章 LimitRange → ns 级:单容器的【默认值注入 + 上下限】
15 章 Quota      → ns 级:整个命名空间的【资源总量 + 对象数量】
                     ↑ 生产典型用法:每团队一个 ns 配一套两件套
```

## 四、LimitRange:单容器规矩(lab02 全解)

### 4.1 完整配置逐字段注解
```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: default-limits
  namespace: res-lab
spec:
  limits:
    - type: Container                    # 按容器为单位(还有 Pod/PVC 类型)
      default: { cpu: 200m, memory: 256Mi }          # ← 陷阱:注入的是 limits!
      defaultRequest: { cpu: 100m, memory: 128Mi }   # ← 这才是 requests
      max: { cpu: "1", memory: 1Gi }                 # 单容器上限(超 → 准入拒绝)
      min: { cpu: 10m, memory: 16Mi }                # 单容器下限(防无意义小申请)
```

### 4.2 命名陷阱(必背)
| LimitRange 字段 | 注入到容器的 |
|-----------------|--------------|
| `default` | **limits** |
| `defaultRequest` | requests |
- 反直觉命名,K8s 历史遗留;记"带 Request 的才是 requests"

### 4.3 注入机制三条推论
- 时机:**创建瞬间**,apiserver 准入阶段
- ①只对新建生效(不追溯旧 Pod)②只补缺的(写了 requests 没写 limits 只补 limits)③**该 ns 里 BestEffort 灭绝**(人人有数字 → 最差 Burstable)
- 验证:`kubectl run no-res` 后 `get -o jsonpath='{.spec.containers[0].resources}'` 看被填上的默认值

## 五、ResourceQuota:命名空间总账(lab02 全解)

### 5.1 完整配置逐字段注解
```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: ns-quota
  namespace: res-lab
spec:
  hard:                       # "硬顶",不可逾越
    requests.cpu: "2"         # ① 资源总量:ns 内所有 Pod 的 requests.cpu 之和 ≤ 2 核
    requests.memory: 2Gi
    limits.cpu: "4"           # limits 总和单独记(给突发留空间)
    limits.memory: 4Gi
    pods: "10"                # ② 对象数量:Pod 总数 ≤ 10(还能数 svc/cm/secret/pvc)
    services.loadbalancers: "0"   # ③ 0 值配额 = 制度性禁止
```
- 两类配额:**资源总量(加法会计)** + **对象数量(计数器)**
- `loadbalancers: "0"` 的治理智慧:云上 LB 按小时计费,开发 ns 配 0 从制度上杜绝成本事故——**配额不只是省资源,更是禁令**

### 5.2 会计账本(实时可查)
```bash
kubectl describe resourcequota ns-quota -n res-lab
# Resource                Used   Hard
# pods                    3      10
# requests.cpu            160m   2      ← 每建一个 Pod 实时累加
```

### 5.3 为什么两件套必须配套(设计的精髓)
- 漏洞:Quota 按 requests/limits 总和记账,若 Pod 不写 resources → 账本不记 → 配额形同虚设
- K8s 硬规则:**存在覆盖 requests/limits 的 Quota 时,不写 resources 的 Pod 直接拒绝创建**
- LimitRange 的默认值注入恰好补洞:先替你填数,再过 Quota 账本——**LimitRange 保证"人人有数字",Quota 才算得清账**

## 六、三层死法对照(排错楼层论,12/15 章合璧)

| 层 | 检查者 | 现象 | 时机 |
|----|--------|------|------|
| **准入层** | apiserver(Quota 超额 / LimitRange 超 max、min) | `Error from server (Forbidden): exceeded quota...` **创建当场报错** | 还没进集群 |
| **调度层** | 调度器(节点装不下 requests / 12 章各过滤项) | Pod 卡 **Pending**,Events 写明原因 | 进了集群没上节点 |
| **运行层** | 内核/kubelet(limits 超线) | CPU 节流(不报错)或 OOMKilled 137 | 已在运行 |
- 心法:**报错在准入层,Pending 在调度层,变慢/死在运行层——报错的位置就是故障的楼层**

## 七、HPA:水平自动扩缩容(lab03 全解)

### 7.1 四资源角色与控制循环
```
load-generator 打流量(经 Service 摊给 N 个 Pod)
  → Pod CPU 上涨 → metrics-server 采集
  → HPA 每 15s 拉指标:平均 X% vs 目标 50%
  → 套公式算期望副本 → 改 Deployment.replicas ←—— HPA 的全部权力
  → Deployment/RS 造新 Pod(05 章滚动机制)
  → Service 摊薄 → 指标回落 → 收敛,持续监视
```
| 资源 | 角色 |
|------|------|
| Deployment php-apache(官方 hpa-example 镜像,访问即烧 CPU) | 靶子 |
| Service php-apache | 靶子的门(压测流量入口) |
| HPA | 指挥官(只改 replicas 字段) |
| load-generator(busybox 工具箱) | 发令枪(exec 进去打流量) |

### 7.2 逐字段注解
```yaml
apiVersion: autoscaling/v2            # 新 API 组:autoscaling
kind: HorizontalPodAutoscaler
spec:
  scaleTargetRef:                     # ① 指挥谁(可指 Deployment/StatefulSet 等)
    apiVersion: apps/v1
    kind: Deployment
    name: php-apache
  minReplicas: 1                      # ② 副本边界
  maxReplicas: 8
  metrics:                            # ③ 决策指标
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 50      # 目标:平均 CPU 利用率 50%
  behavior:                           # ④ 扩缩的脾气
    scaleUp:
      stabilizationWindowSeconds: 0       # 扩容:立即执行
    scaleDown:
      stabilizationWindowSeconds: 300     # 缩容:观察 5 分钟(默认值)
```
- **① HPA 是"发令的"不是"干活的"**:改完 replicas,后续由 Deployment→RS→Pod 链条接力(05 章)
- 推论:**HPA 接管 replicas 字段,手动 `kubectl scale` 会被它改回去**(FAQ)

### 7.3 决策公式(必背必算)
```
期望副本数 = ceil( 当前副本数 × 当前指标值 / 目标值 )
实例:1 副本被打到 200% → ceil(1 × 200/50) = 4 个
```
- **百分比的分母是 requests(不是 limits)**——本实验 requests 200m,200% = 实际 400m
- 两种 unknown 病因:metrics-server 没就绪 / Pod 没设 cpu requests(没有分母)
- 为什么压 Service 不压 Pod:副本扩到 4 后 Service 自动摊薄 → 每 Pod CPU 回落 → 收敛;直打 Pod IP 则负载永在一个副本上,扩个没完

### 7.4 behavior 不对称哲学
- 扩容 0 秒(过载是事故,果断救火)/ 缩容 300 秒(确认不是抖动才敢减)
- 缩快了的代价:反复横跳 + 缩掉的 Pod 再扩回来要重调度冷启动
- 记:**扩容要果断,缩容要迟疑**;behavior 可再配扩缩速率策略(selectPolicy 等)

### 7.5 观察要点
```bash
kubectl get hpa -n res-lab -w
# TARGETS 列 = 当前值/目标值(3%/50% → 压测中 200%/50% → REPLICAS 1→N)
```
- 压测命令:`kubectl exec -it load-generator -- sh -c 'while true; do wget -qO- http://php-apache; done'`
- 停压后 ~5 分钟(稳定窗口)副本才缩回——不是坏了,是缩容性格谨慎

## 八、实验联动与坑速查

### 8.1 【实况】Quota × HPA 梦幻联动(文档未覆盖)
- res-lab 有 `pods: 10` 配额,实验前账上已有 3 个(lab01/02 遗留)
- HPA 上限 8 副本 + load-generator + 遗留 3 = 12 > 10 → **扩到 6~7 个副本时撞墙**:
  Deployment Events 出现 `exceeded quota: ns-quota ... limited: pods=10`,副本卡住
- 这正是配额在管 HPA 的活演示;跑 lab03 前先清场:`kubectl delete pod cpu-burn mem-burn no-res -n res-lab`

### 8.2 FAQ 速查
| 问题 | 答案 |
|------|------|
| HPA 一直 unknown | metrics-server 没就绪 / 没设 cpu requests(百分比无分母) |
| CPU 超限为什么不报错 | 节流是软限制,设计如此;看 top 是否贴 limit |
| top 报 error | metrics-server 没装 / kind 没加 insecure-tls 补丁 |
| 手动 scale 和 HPA 冲突 | HPA 接管 replicas,手动改会被覆盖 |
| 超配额是什么现象 | apiserver 创建当场报错(准入层),**不是 Pending**(调度层) |

### 8.3 知识地图
```
04 章 QoS(单 Pod 驱逐顺位) → 15 章 LimitRange(ns 默认值/边界)
  → 15 章 ResourceQuota(ns 总量/数量) → 15 章 HPA(按负载自动伸缩)
      ↑ 依赖 metrics-server 报数 ↑ 依赖 Pod 设了 requests(分母)
```
- 与 19 章的接口:生产风格部署 = resources 全写 + HPA 弹性 + 配额治理,三件都在本章
