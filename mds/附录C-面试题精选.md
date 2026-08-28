# 附录 C:K8s 高频面试题精选(30 问)

> 每题都可在本手册中找到动手验证方法,答案要点供背诵。

## 基础概念(01~03 章)

**1. Pod 和容器的区别?**
Pod 是 K8s 最小调度单位,含 1+ 容器;同 Pod 容器共享网络(namespace/localhost)、存储卷、生命周期;隔离单位是 cgroup/namespace 级别。

**2. K8s 架构核心组件及职责?**
控制面:apiserver(唯一入口)、etcd(状态存储)、scheduler(选节点)、controller-manager(调谐)。节点:kubelet(Pod 生命周期)、kube-proxy(Service 转发)、容器运行时(CRI)。

**3. 声明式 API 和命令式区别?**
声明式提交"期望状态",控制器持续收敛;支持 diff/审计/自愈、幂等。

## Pod(04 章)

**4. 三种探针区别?**
startup(慢启动保护)→ liveness(失败重启容器)→ readiness(失败摘除流量)。参数:initialDelay/period/failureThreshold。

**5. liveness 和 readiness 同时探测 /healthz 有什么坑?**
依赖故障时 readiness 应先失败(摘流),liveness 别依赖外部服务,否则会连环重启(雪崩)。

**6. QoS 三等级与驱逐顺序?**
Guaranteed(requests=limits)→ Burstable → BestEffort(最先驱逐)。由调度器/驱逐管理器按内存压力选择。

**7. init 容器与普通容器区别?**
串行先执行、必须成功;可不同镜像/命令;共享 Volume 传数据;常用于等待依赖与预处理。

**8. postStart/preStop 时机?**
postStart 在容器创建后异步执行(不保证在 ENTRYPOINT 前);preStop 在 SIGTERM 前同步执行,配 terminationGracePeriodSeconds 做优雅下线。

## 工作负载(05~07 章)

**9. Deployment 滚动更新原理?**
新建 RS(扩到目标)→ 旧 RS 缩容,按 maxSurge/maxUnavailable 步进;旧 RS 保留(0 副本)供回滚。

**10. StatefulSet 适用场景与三大特性?**
数据库/MQ;稳定网络名(pod.svc.ns)、稳定存储(volumeClaimTemplates 专属 PVC)、有序启停(0→N 建,N→0 删)。

**11. Job 和 CronJob 关键参数?**
completions/parallelism/backoffLimit/activeDeadlineSeconds/ttlSecondsAfterFinished;CronJob 的 concurrencyPolicy(Forbid 防重叠)。

**12. DaemonSet 典型用途?为什么控制面节点也能跑?**
每节点一个:日志/监控/网络组件;需容忍 control-plane 污点。

## 网络(08~09/13 章)

**13. Service 四种类型?**
ClusterIP(内)/ NodePort(节点高位端口)/ LoadBalancer(云 LB)/ ExternalName(CNAME 别名);另有 Headless(clusterIP: None)直接返回 Pod IP。

**14. Service 如何实现负载均衡?**
kube-proxy 在每个节点写 iptables/ipvs 规则,VIP 随机/轮询到 endpoints;endpoints 由 readiness 驱动。

**15. port / targetPort / nodePort?**
port=Service VIP 端口;targetPort=容器端口;nodePort=节点对外端口(30000-32767)。

**16. Ingress 和 Service 区别?**
Service 是四层转发;Ingress 由 Controller(如 nginx)实现七层路由(host/path/TLS),后端仍是 Service。

**17. 集群内 DNS 解析格式?**
svc: `<svc>.<ns>.svc.cluster.local`;Pod: `<ip 横线>.<ns>.pod.cluster.local`;StatefulSet Pod: `<pod>.<headless-svc>.<ns>`。

**18. NetworkPolicy 默认行为?**
默认全放行;Pod 被任一策略选中即对其白名单化;需 CNI 支持(Calico/Cilium,kindnet 不支持)。

## 配置与存储(10~11 章)

**19. ConfigMap 注入方式与热更新?**
env(不热更)/envFrom(不热更)/volume 挂载(约 1 分钟热更)/subPath(不热更);程序需自行 reload。

**20. Secret 安全真相?**
base64 仅编码;需 etcd 静态加密 + RBAC 限制读取 + 尽量卷挂载而非 env。

**21. PV/PVC/StorageClass 关系?**
PVC 声明需求;PV 是资源;SC 驱动动态供给;绑定看容量≥请求+访问模式+类名匹配。

**22. RWO/ROX/RWX?**
ReadWriteOnce 单节点;ReadOnlyMany 多节点只读;ReadWriteMany 需共享文件系统(NFS/CephFS)。

## 调度与资源(12/15 章)

**23. 调度两阶段?**
Predicates 过滤(资源/亲和/污点/卷拓扑)→ Priorities 打分(均衡性/亲和偏好)→ bind。

**24. 污点三种 effect?**
NoSchedule(不调新)/PreferNoSchedule(尽量)/NoExecute(驱逐已有)。

**25. requests/limits 对 CPU 和内存的不同后果?**
CPU 超限节流(不杀);内存超限 OOMKill。

**26. HPA 期望副本公式?**
`ceil(当前副本 × 当前指标/目标指标)`;缩容有稳定窗口(默认 5 分钟)。

## 运维与生态(14/16~18 章)

**27. RBAC 四对象与绑定关系?**
Role(ns 级)/ClusterRole(集群级)定义规则;RoleBinding/ClusterRoleBinding 绑给 User/Group/ServiceAccount;RoleBinding 可引 ClusterRole(裁剪到 ns)。

**28. 排查 CrashLoopBackOff 思路?**
`logs --previous` 看崩溃前日志 → 检查配置/依赖/探针/权限 → `describe` 看 exitCode。

**29. Helm Chart 结构与升级回滚?**
Chart.yaml/values.yaml/templates(_helpers/NOTES);release 按 revision 管理,`helm rollback` 回滚。

**30. Operator 是什么?与 CRD 关系?**
CRD 定义新资源类型(API/存储);Operator=CRD+自定义控制器,把运维知识代码化(部署/备份/扩缩/自愈),Reconcile 幂等收敛。
