# 第 17 章 Helm 包管理(应用的"apt/yum")

> 📁 本章实验资源(yaml / 脚本 / sql)位于 `D:\k8s\17-Helm包管理\`,本文档位于 `D:\k8s\mds\`。

## 学习目标

1. 掌握 Helm 核心概念与发布生命周期命令
2. 读懂并能改 Chart:values → 模板 → 渲染产物
3. 从零交付一个完整 Chart(my-chart:Deployment+Service+ConfigMap+Ingress+HPA)

## 17.1 核心概念

| 概念 | 类比 | 说明 |
|------|------|------|
| Chart | 软件包 | 一套 K8s 资源模板 + 默认值 |
| values | 配置文件 | 安装时可覆盖:`-f` / `--set` |
| Release | 一次安装实例 | 同一 Chart 可装多份(release 名区分) |
| Repository | 软件源 | chart 仓库(Bitnami、prometheus-community...) |

### 发布生命周期

```bash
helm install   myapp chart/    # 安装
helm upgrade   myapp chart/ -f prod-values.yaml   # 升级(自动生成新 revision)
helm rollback  myapp 1         # 回滚到 revision 1
helm history   myapp           # 查看历史
helm uninstall myapp           # 卸载
helm list                     # 现有 release
```

### 常用调试三板斧(写模板必用)

```bash
helm lint my-chart/                    # 语法检查
helm template test my-chart/           # 本地渲染,不装
helm install test my-chart/ --dry-run --debug   # 服务端校验渲染
helm get manifest myapp                # 看已装 release 的最终产物
```

### 模板语法速记

```
{{ .Values.image.tag }}            取值
{{ .Values.xxx | default "abc" }}  管道与默认值
{{ quote .Values.a }}              函数:加引号
{{- if .Values.ingress.enabled }} ... {{- end }}   条件
{{- range .Values.extraEnv }} ... {{- end }}       循环
{{ include "mychart.name" . }}     引用 helper(nindent 控制缩进)
{{- toYaml .Values.resources | nindent 12 }}       map 转 YAML 并缩进
```

> `.helmignore` 忽略打包文件;`NOTES.txt` 安装成功后的输出说明。

---

## 实验列表

### 步骤 0:安装 Helm(第 16 章装过可跳过)

```bash
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version
```

### 实验 1:使用公共 Chart(体验发布管理)

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
helm show values bitnami/redis | head -40          # 看看可配置项
helm install my-redis bitnami/redis -n helm-lab --create-namespace \
  --set master.persistence.enabled=false \
  --set replica.replicaCount=1
helm list -n helm-lab
helm get manifest my-redis -n helm-lab | head -30
helm uninstall my-redis -n helm-lab
```

### 实验 2:本地渲染自制 Chart(读懂 my-chart)

```bash
cd /mnt/d/k8s/17-Helm包管理
helm lint my-chart/
helm template demo my-chart/ | less                      # 检查渲染产物
helm template demo my-chart/ --set autoscaling.enabled=true | grep -A5 HorizontalPod
helm template demo my-chart/ --set ingress.host=custom.local | grep host
```

my-chart 目录结构(先通读一遍再往下做):

```
my-chart/
├── Chart.yaml        # chart 元信息
├── values.yaml       # 默认值
├── .helmignore
└── templates/
    ├── _helpers.tpl  # 公共命名/标签模板(下划线开头=不渲染产物)
    ├── deployment.yaml
    ├── service.yaml
    ├── configmap.yaml
    ├── ingress.yaml   # 由 values.ingress.enabled 控制
    ├── hpa.yaml       # 由 values.autoscaling.enabled 控制
    └── NOTES.txt      # 安装完的提示输出
```

### 实验 3:安装/升级/回滚完整闭环

```bash
# 安装(默认:2副本,无Ingress)
helm install demo my-chart/ -n helm-lab
kubectl get all -n helm-lab

# 升级:开 Ingress + 换版本(要求先装好 ingress-nginx,见第 09 章)
helm upgrade demo my-chart/ -n helm-lab \
  --set image.tag=1.27-alpine --set ingress.enabled=true --set ingress.host=demo.local
helm history demo -n helm-lab          # revision 1→2

# 验证:echo "127.0.0.1 demo.local" | sudo tee -a /etc/hosts 后 curl http://demo.local
curl -s http://demo.local/

# 回滚
helm rollback demo 1 -n helm-lab
helm status demo -n helm-lab

# 卸载
helm uninstall demo -n helm-lab
```

## 常见问题

| 问题 | 答案 |
|------|------|
| 渲染报缩进错误? | `toYaml | nindent N` 的 N 必须等于当前字段缩进 |
| `--set` 嵌套怎么写? | `--set a.b.c=v`,列表:`--set list[0]=x` |
| 升级会不会中断服务? | 模板里是 Deployment,沿用其滚动更新策略 |
| 同一 chart 装两份? | 两个 release 名;fullname helper 已用 release 名避免冲突 |

## 练习任务

1. [ ] 给 my-chart 增加 `serviceAccount.create` 开关(参考 ingress.yaml 的条件写法)
2. [ ] 用 `--set replicaCount=5` 安装并验证
3. [ ] `helm package my-chart/` 打包,再 `helm install` 本地 tgz

## 参考

- https://helm.sh/zh/docs/intro/quickstart/
