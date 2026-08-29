# 第 03 章 kubectl 基础操作

> 📁 本章实验资源(yaml / 脚本 / sql)位于 `D:\k8s\03-kubectl基础操作\`,本文档位于 `D:\k8s\mds\`。

## 学习目标

1. 掌握日常 90% 场景的 kubectl 命令
2. 学会 `-o` 各种输出格式与 jsonpath 提取字段
3. 掌握"命令式命令生成 YAML → 声明式 apply"的工作流

## 3.1 命令语法模型

```
kubectl [命令] [资源类型] [名字] [标志]
        │       │           │      │
        get     pods        web    -n dev -o wide
```

常用命令动词:`get / describe / create / apply / edit / delete / logs / exec / scale / rollout / cp / port-forward / top / explain / api-resources`

## 3.2 get 命令详解(使用频率最高,务必熟练)

通用骨架:

```
kubectl get <资源类型> [资源名] [参数]
```

- **不写名字 = 列出全部**;写名字 = 只看这一个,如 `kubectl get pod web`;一次看多个也行:`kubectl get pod web api -n dev`
- 特殊资源名 `all`:常用资源一键全看,`kubectl get all -n dev`(Pod/Service/Deployment/ReplicaSet 等)

### 高频资源缩写

| 全称 | 缩写 | 全称 | 缩写 |
|------|------|------|------|
| pods | po | deployments | deploy |
| nodes | no | replicasets | rs |
| services | svc | statefulsets | sts |
| namespaces | ns | daemonsets | ds |
| configmaps | cm | jobs | job |
| secrets | secret | cronjobs | cj |
| ingresses | ing | serviceaccounts | sa |
| persistentvolumes | pv | persistentvolumeclaims | pvc |

> 完整列表随时可查:`kubectl api-resources`(SHORTNAMES 列就是缩写)

### 常用参数

| 参数 | 全称 | 作用 | 例子 |
|------|------|------|------|
| `-n xx` | `--namespace` | 指定命名空间 | `kubectl get pods -n kube-system` |
| `-A` | `--all-namespaces` | 所有命名空间 | `kubectl get pods -A` |
| `-o wide` | `--output` | 表格加宽(多出 IP/节点等列) | `kubectl get pods -o wide` |
| `-o yaml` / `-o json` | | 完整对象定义(spec+status) | `kubectl get pod web -o yaml` |
| `-o jsonpath=` | | 提取具体字段 | `kubectl get pod web -o jsonpath='{.status.podIP}'` |
| `-o custom-columns=` | | 自定义表格列 | `kubectl get pods -o custom-columns='NAME:.metadata.name,NODE:.spec.nodeName'` |
| `-l` | `--selector` | 按**标签**筛选 | `kubectl get pods -l app=web` |
| `--show-labels` | | 显示标签列 | `kubectl get pods --show-labels` |
| `--field-selector` | | 按**字段**过滤 | `kubectl get pods --field-selector=status.phase=Running` |
| `-w` | `--watch` | 持续监听变化(观察滚动更新必用) | `kubectl get pods -w` |
| `--sort-by` | | 按字段排序 | `kubectl get pods --sort-by=.metadata.creationTimestamp` |
| `--no-headers` | | 去掉表头(写脚本用) | `kubectl get pods --no-headers` |

> `-l` 与 `--field-selector` 的区别:标签是你自己打上去的元数据,可按任意维度筛;字段是对象自带属性,只支持 name/phase 等少数几个。

### 输出列含义

`kubectl get nodes`:

| 列 | 含义 | 关注点 |
|----|------|--------|
| STATUS | Ready / NotReady / SchedulingDisabled | 必须 Ready;NotReady = kubelet 挂了 |
| ROLES | control-plane 或 `<none>` | `<none>` 即工作节点 |
| INTERNAL-IP | 节点 IP(kind 里是 Docker 容器 IP) | NodePort 实验要用(第 08 章) |
| VERSION / OS-IMAGE / CONTAINER-RUNTIME | 版本信息 | 排错偶尔用 |

`kubectl get pods`:

| 列 | 含义 |
|----|------|
| READY | 就绪容器数/总容器数,如 `1/1`(多容器 Pod 会出现 `1/2`) |
| STATUS | Running 正常 / Completed 跑完退出 / Pending 没调度上 / CrashLoopBackOff 反复崩溃 / ImagePullBackOff 拉不到镜像 |
| RESTARTS | 重启次数,不为 0 且持续增加 = 有问题 |
| AGE | 存活时长 |

### get 的黄金搭档

`get` 看"状态**是什么**",`describe` 看"**为什么**变成这个状态"——遇到 Pending、CrashLoopBackOff 时,先 `kubectl describe pod xx` 看最下面的 Events(具体见 3.3)。

## 3.3 命令速查(核心)

```bash
# ---- 查看 ----
kubectl get pods -A                    # 全命名空间 Pod
kubectl get pods -n dev -o wide        # 带 IP/节点
kubectl describe pod web -n dev        # 详情+Events,排错第一现场
kubectl logs web -n dev -f             # 日志,-f 跟随,--previous 看上次崩溃的
kubectl exec -it web -n dev -- sh      # 进容器
kubectl top pod/node                   # 资源占用(需 metrics-server,第 15 章)

# ---- 创建/修改 ----
kubectl apply -f xx.yaml               # 声明式:有则更新无则创建(推荐)
kubectl edit deployment web -n dev     # 直接改线上对象(临时救急用)
kubectl set image deployment/web nginx=nginx:1.28 -n dev

# ---- 删除 ----
kubectl delete -f xx.yaml
kubectl delete pod web -n dev --grace-period=0 --force   # 强杀(慎用)

# ---- 调试 ----
kubectl port-forward pod/web 8080:80 -n dev   # 本地访问 Pod
# cp 双向拷贝(与 scp 同向):
kubectl cp dev/web:/etc/hostname ./host.txt   # Pod → 本地
kubectl cp ./host.txt dev/web:/tmp/           # 本地 → Pod(目标要写到容器内路径)
kubectl explain pod.spec.containers.livenessProbe   # 层层查字段文档
```

## 3.4 输出格式与字段提取

```bash
kubectl get pods -o yaml                                  # 完整对象(含 status)
kubectl get pod web -o jsonpath='{.status.podIP}'        # 提取单个字段
kubectl get pods -o custom-columns='NAME:.metadata.name,NODE:.spec.nodeName'
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.addresses[0].address}{"\n"}{end}'
kubectl get events -n dev --sort-by=.lastTimestamp       # 事件按时间排序
kubectl config get-contexts && kubectl config use-context kind-k8s-learning
```

## 3.5 命令式 → 声明式工作流(生成 YAML 三板斧)

```bash
# 1) 生成 Deployment
kubectl create deployment gen-web --image=nginx:1.27 --dry-run=client -o yaml > d.yaml
# 2) 生成 Service
kubectl expose deployment gen-web --port=80 --dry-run=client -o yaml > s.yaml
# 3) 生成各种资源都有对应子命令:
kubectl create configmap / secret / job / cronjob / namespace --dry-run=client -o yaml
# 生成的文件再人工完善 → 纳入 git → kubectl apply -f
```

## 3.6 --dry-run 与 diff(安全变更)

```bash
kubectl apply -f d.yaml --dry-run=server    # 服务端校验,不落库
kubectl diff -f d.yaml                      # 看看 apply 会改什么
```

---

## 实验:10 个小任务

先部署练习用的 Deployment:

```bash
cd /mnt/d/k8s/03-kubectl基础操作/manifests
kubectl apply -f lab01-practice.yaml    # ns: kubectl-lab, deployment: shop
```

1. [ ] 列出 `kubectl-lab` 下所有 Pod 及所在节点
2. [ ] 查看 shop 的 Pod IP(jsonpath 提取)
3. [ ] 进入一个 Pod,`curl localhost` 验证 nginx 可用(`kubectl exec`)
4. [ ] 打印某个 Pod 最近 20 行日志
5. [ ] 扩容到 5 副本并观察滚动过程(`kubectl scale deployment shop --replicas=5 -n kubectl-lab && kubectl get pods -n kubectl-lab -w`)
6. [ ] 用 `kubectl label pod <pod名> tier=front -n kubectl-lab` 打标签,再用 `-l tier=front` 筛选
7. [ ] `kubectl set image` 把镜像换成 nginx:1.28,`kubectl rollout status` 观察过程
8. [ ] 觉得新版本有问题,`kubectl rollout undo deployment/shop -n kubectl-lab` 回滚
9. [ ] 用 `--dry-run=client -o yaml` 生成一个 redis ConfigMap 并保存成文件
10. [ ] 清理:`kubectl delete ns kubectl-lab`

## 常见问题

| 问题 | 答案 |
|------|------|
| `apply` 和 `create` 区别? | create 只能建一次;apply 是幂等的"声明对齐",可持续同步 |
| 忘记 namespace? | `kubectl config set-context --current --namespace=kubectl-lab` 设默认 ns |
| Pod 名记不住? | `kubectl logs deployment/shop` 会自动选一个 Pod |

## 参考

- 速查总表:`附录B-命令速查表.md`
- https://kubernetes.io/zh-cn/docs/reference/kubectl/cheatsheet/
