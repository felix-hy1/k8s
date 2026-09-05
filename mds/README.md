# 🎓 Kubernetes 系统学习手册(kind + WSL2 实验环境)

> 学习环境:Windows + WSL2(Ubuntu)+ Docker + kind 本地集群
> 手册更新:2026-08-28
> 适用版本:Kubernetes v1.30+ / kind v0.24+

---

## 〇、目录结构说明(重要)

```
D:\k8s\
├── mds\                          ← 只有 .md 文档(本目录)
│   ├── README.md                 ← 总览与学习表(本文件)
│   ├── 01-环境搭建-Kind.md ... 19-综合实战-WordPress.md   ← 各章教程
│   ├── 附录A-排错手册.md
│   ├── 附录B-命令速查表.md
│   └── 附录C-面试题精选.md
│
├── 01-环境搭建-Kind\             ← 各章实验资源(与文档同名)
│   ├── manifests\                ← kind 集群配置等 YAML
│   └── scripts\                  ← 安装/建集群脚本
├── 04-Pod详解\
│   └── manifests\lab01~07.yaml   ← 每章按 labXX 编号的实验清单
├── 06-StatefulSet有状态应用\
│   ├── manifests\                ← MySQL StatefulSet 部署清单
│   └── sql\                      ← 建库建表/查询练习 SQL 脚本
├── 17-Helm包管理\
│   └── my-chart\                 ← 完整可安装的示例 Chart
└── ... 其余各章同理
```

**对应关系**:`mds\NN-章节名.md`(教程)↔ `D:\k8s\NN-章节名\`(实验资源)。

---

## 一、快速开始(3 步)

```bash
# 1. Windows 上打开 WSL2 Ubuntu
wsl -d Ubuntu

# 2. 一键搭建 kind 学习集群(首次会安装 docker/kubectl/kind)
bash /mnt/d/k8s/01-环境搭建-Kind/scripts/00-setup-all.sh

# 3. 从第 02 章开始,阅读 mds 下的章节文档并动手做实验
#    文档:mnt/d/k8s/mds/02-K8s架构与核心概念.md
```

---

## 二、章节总表(学习表)

| 章 | 文档(mds/) | 资源目录(D:\k8s\) | 核心实验 | 建议学时 | 难度 | 进度 |
|----|-------------|--------------------|----------|----------|------|------|
| 01 | `01-环境搭建-Kind.md` | `01-环境搭建-Kind\` | 搭建 1 控制面 + 2 工作节点集群 | 2h | ★ | ✅ |
| 02 | `02-K8s架构与核心概念.md` | `02-K8s架构与核心概念\` | 观察集群组件、跑第一个 Pod | 3h | ★ | ✅ |
| 03 | `03-kubectl基础操作.md` | `03-kubectl基础操作\` | 10 个命令小任务、生成 YAML | 4h | ★★ | ✅ |
| 04 | `04-Pod详解.md` | `04-Pod详解\` | 7 个递进实验(探针/QoS/多容器) | 8h | ★★ | ✅ |
| 05 | `05-Deployment与ReplicaSet.md` | `05-Deployment与ReplicaSet\` | 发布策略对比、版本回滚 | 6h | ★★ | ✅ |
| 06 | `06-StatefulSet有状态应用.md` | `06-StatefulSet有状态应用\` | 部署 MySQL + SQL 脚本初始化 | 8h | ★★★ | ☐ |
| 07 | `07-DaemonSet-Job-CronJob.md` | `07-DaemonSet-Job-CronJob\` | 节点代理、并行 Job、定时任务 | 4h | ★★ | ✅ |
| 08 | `08-Service服务发现.md` | `08-Service服务发现\` | 四种 Service + MetalLB | 6h | ★★★ | ☐ |
| 09 | `09-Ingress入口流量.md` | `09-Ingress入口流量\` | 路径/域名路由 + TLS | 5h | ★★ | ☐ |
| 10 | `10-ConfigMap与Secret.md` | `10-ConfigMap与Secret\` | 配置外置 + 热更新实验 | 6h | ★★ | ✅ |
| 11 | `11-存储管理-PV-PVC.md` | `11-存储管理-PV-PVC\` | 手工 PV + 动态 PVC | 7h | ★★★ | ✅ |
| 12 | `12-调度机制.md` | `12-调度机制\` | 亲和性/污点/拓扑打散 4 组实验 | 6h | ★★★ | ✅ |
| 13 | `13-集群网络与NetworkPolicy.md` | `13-集群网络与NetworkPolicy\` | DNS 解析 + Calico 网络策略 | 7h | ★★★ | ☐ |
| 14 | `14-RBAC与安全.md` | `14-RBAC与安全\` | 多用户权限 + kubeconfig | 6h | ★★★ | ☐ |
| 15 | `15-资源管理与HPA.md` | `15-资源管理与HPA\` | OOM 复现 + HPA 压测 | 5h | ★★★ | ☐ |
| 16 | `16-监控与日志.md` | `16-监控与日志\` | kube-prometheus-stack 全套 | 6h | ★★★ | ☐ |
| 17 | `17-Helm包管理.md` | `17-Helm包管理\` | 从零编写完整 Chart | 6h | ★★★ | ☐ |
| 18 | `18-CRD与Operator.md` | `18-CRD与Operator\` | 自定义 Website 资源 | 5h | ★★★★ | ☐ |
| 19 | `19-综合实战-WordPress.md` | `19-综合实战-WordPress\` | 生产风格部署 WordPress | 8h | ★★★★ | ☐ |
| 附 | `附录A-排错手册.md` / `附录B-命令速查表.md` / `附录C-面试题精选.md` | - | 随查随用 | - | - | - |

---

## 三、学习路线计划

### 3.1 标准版:12 周(每周约 6~8 小时)

| 周次 | 章节 | 本周目标 |
|------|------|----------|
| 第 1 周 | 01 → 03 | 环境就绪,理解架构,熟练 kubectl |
| 第 2 周 | 04 | 彻底吃透 Pod(最重要的一章) |
| 第 3 周 | 05 + 07 | 无状态发布与任务型工作负载 |
| 第 4 周 | 06 | 有状态应用与 MySQL 实战 |
| 第 5 周 | 08 + 09 | 集群内/外流量入口打通 |
| 第 6 周 | 10 + 11 | 配置与存储分离 |
| 第 7 周 | 12 + 13 | 调度与网络两大难点 |
| 第 8 周 | 14 + 15 | 安全与资源治理 |
| 第 9 周 | 16 | 可观测性 |
| 第 10 周 | 17 | Helm 交付 |
| 第 11 周 | 18 | 扩展 K8s(CRD/Operator) |
| 第 12 周 | 19 + 复习 | 综合实战 + 附录查漏补缺 |

### 3.2 速成版:4 周(每天约 3 小时)

| 周次 | 章节 |
|------|------|
| 第 1 周 | 01 ~ 05 |
| 第 2 周 | 06 ~ 09 |
| 第 3 周 | 10 ~ 14 |
| 第 4 周 | 15 ~ 19 |

---

## 四、本手册使用方法

1. **读文档**:`D:\k8s\mds\NN-章节名.md` —— 理论精讲 + 逐条命令的实验步骤 + 常见坑 + 练习任务。
2. **做实验**:文档中所有 `cd /mnt/d/k8s/NN-章节名/manifests` 后 `kubectl apply -f labXX-*.yaml` 即可复现;`scripts/`、`sql/` 等资源也在同名章节目录下。
3. **路径约定**:Windows 下文档目录是 `D:\k8s\mds`,实验资源是 `D:\k8s\NN-*`;WSL2 内分别是 `/mnt/d/k8s/mds` 与 `/mnt/d/k8s/NN-*`。所有命令都在 **WSL2 终端**执行。
4. **换行符提示**:脚本在 WSL 报 `$'\r': command not found` 时,先执行 `sed -i 's/\r//' 脚本路径`。
5. **实验隔离约定**:每章实验使用独立 Namespace,做完执行文档末尾的清理命令。
6. **进度记录**:完成一章后,把上方表格中对应 `☐` 改成 `✅`。

---

## 五、前置知识自查

- [ ] Linux 基本命令(cd/ls/cat/grep/chmod)
- [ ] 了解 Docker 镜像与容器概念(docker run/ps/logs)
- [ ] YAML 基础(缩进、键值、列表)
- [ ] 网络基础(IP/端口/DNS/HTTP)

不满足也没关系,遇到不会的先查 `附录B-命令速查表.md`。

---

## 六、参考资料

- 官方文档:https://kubernetes.io/zh-cn/docs/home/
- API 参考:https://kubernetes.io/docs/reference/kubernetes-api/
- kind:https://kind.sigs.k8s.io/
- 交互式教程:https://kubernetes.io/zh-cn/docs/tutorials/kubernetes-basics/
