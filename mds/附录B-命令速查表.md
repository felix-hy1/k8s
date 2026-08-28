# 附录 B:kubectl 命令速查表

> 建议配 `alias k=kubectl` + `source <(kubectl completion bash)`

## B.1 查看类

| 命令 | 作用 |
|------|------|
| `k get all -A` | 全部核心资源 |
| `k get pods -o wide --show-labels` | Pod 详情+标签 |
| `k get pods -l app=web -n prod` | 按标签筛选 |
| `k describe pod xx` | 详情+Events(排错首选) |
| `k logs xx -f --tail=100` | 日志(实时/行数) |
| `k logs xx --previous` | 上次崩溃的日志 |
| `k logs deploy/web` | 按工作负载取日志 |
| `k exec -it xx -- sh` | 进容器 |
| `k top pods/nodes` | 资源占用(需 metrics-server) |
| `k get events --sort-by=.lastTimestamp` | 事件排序 |
| `k explain pod.spec.containers` | 字段文档 |

## B.2 输出与提取

| 命令 | 作用 |
|------|------|
| `-o yaml` / `-o json` | 全量对象 |
| `-o jsonpath='{.status.podIP}'` | 提取字段 |
| `-o custom-columns='N:.metadata.name,IP:.status.podIP'` | 自定义列 |
| `k config use-context kind-k8s-learning` | 切集群 |
| `k config set-context --current --namespace=xx` | 设默认 ns |

## B.3 生命周期

| 命令 | 作用 |
|------|------|
| `k apply -f xx.yaml` | 声明式创建/更新 |
| `k diff -f xx.yaml` | 预览变更 |
| `k delete -f xx.yaml` / `k delete pod xx` | 删除 |
| `k edit deploy xx` | 直接编辑线上对象 |
| `k set image deploy/xx c=nginx:1.28` | 换镜像 |
| `k scale deploy xx --replicas=5` | 手动扩缩 |

## B.4 发布管理

| 命令 | 作用 |
|------|------|
| `k rollout status deploy/xx` | 看滚动进度 |
| `k rollout history deploy/xx` | 版本历史 |
| `k rollout undo deploy/xx` | 回滚上一版 |
| `k rollout undo deploy/xx --to-revision=2` | 回指定版 |
| `k rollout restart deploy/xx` | 全量重启 |
| `k rollout pause/resume deploy/xx` | 暂停/恢复发布 |

## B.5 调试

| 命令 | 作用 |
|------|------|
| `k port-forward svc/web 8080:80` | 本地端口映射 |
| `k run t --rm -it --image=busybox --restart=Never -- sh` | 一次性调试 Pod |
| `k cp ns/pod:/path ./local` | 拷文件 |
| `k auth can-i delete pods --as=xx` | 权限自检 |
| `k get --raw='/readyz?verbose'` | 组件健康 |

## B.6 节点与调度

| 命令 | 作用 |
|------|------|
| `k label node xx key=val` / `k label node xx key-` | 打/删标签 |
| `k taint node xx key=val:NoSchedule` / 末尾 `-` 删 | 打/删污点 |
| `k cordon xx` / `k uncordon xx` | 禁调度/恢复 |
| `k drain xx --ignore-daemonsets` | 驱离负载 |

## B.7 生成 YAML(dry-run)

```bash
k create deploy web --image=nginx --dry-run=client -o yaml > d.yaml
k expose deploy web --port=80 --dry-run=client -o yaml
k create cm app --from-file=a.properties --dry-run=client -o yaml
k create secret generic db --from-literal=pw=1 --dry-run=client -o yaml
k create job j1 --image=busybox --dry-run=client -o yaml
```

## B.8 Helm

```bash
helm repo add/update
helm install|upgrade|rollback|uninstall|list|history|status
helm template .      # 本地渲染
helm lint .          # 检查
helm get manifest    # 看产物
```

## B.9 kind

```bash
kind create cluster --config xx.yaml --wait 120s
kind get clusters / kind delete cluster --name xx
docker exec <node> sh          # 进"节点"内部排查
```
