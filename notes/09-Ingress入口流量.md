# 09 Ingress 入口流量(知识笔记)

> 约定:YAML 示例出自 `~/k8s-lab/09-Ingress入口流量/manifests/lab01~lab04` 与 `scripts/gen-tls.sh`,编号与章节对应;标注【实况】为实际搭建时踩到的坑(文档未覆盖)。

## 一、Ingress 与 Ingress Controller:两个东西

### 1.1 定位:一张表和一个执行者
| | Ingress | Ingress Controller |
|--|---------|--------------------|
| 是什么 | **API 对象,一张七层路由规则表**(host+path → Service) | **真正收流量的反向代理**(ingress-nginx 本质是个 nginx Pod) |
| 干活吗 | 不干活,纯粹一张表 | 干全部的活:watch 规则 → 生成 nginx.conf → 收发流量 |
| 是否自带 | K8s **不自带**任何 Ingress Controller | 必须自己装(ingress-nginx/Traefik/HAProxy…) |

- **不装 Controller,写一万条 Ingress 也是空气**——80/443 上没有任何人监听
- 与 Deployment 控制器的区别:Deployment 的控制器是 K8s 内置的;Ingress 的控制器是外挂的、可换品牌
- 价值:四层 Service 一个服务一个入口(端口管理灾难);七层 Ingress 一个 80/443 收敛所有服务,按域名/路径分流,HTTPS 统一在入口卸载

### 1.2 与 Service 的分工
- Ingress **不能替代 Service**:它把流量转给 Service(实为经 DNAT 直达 Pod);后端 Service 用最普通的 ClusterIP 就够
- 对外暴露这件事 Ingress 包了——后端服务不再需要 NodePort/LoadBalancer
- 与 NetworkPolicy 的对照:NetworkPolicy 管 **Pod 数据面**的东西向黑白名单(L3/L4,DROP 静默超时);Ingress 管入口的**七层分发**(域名/路径/TLS)——一个管"谁能进哪个门",一个管"进了大门往哪走",正交互补

### 1.3 kind 专用清单与端口链路
```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
kubectl -n ingress-nginx wait --for=condition=ready pod -l app.kubernetes.io/component=controller --timeout=180s
curl -s http://localhost        # 返回 404 = 成功(Controller 在岗,只是没规则)
```
- kind 版清单的特殊点:让 Controller 通过 **hostPort 直接占用节点的 80/443**
- 完整端口链路(每一段都是之前的知识):
```
WSL curl localhost:80
  → 第 01 章 extraPortMappings(WSL:80 → 控制面容器:80)
  → 控制面节点 80(hostPort)
  → Controller 的 nginx → 查路由表:0 条规则 → 404
```
- **404 = 链路全通只差规则**;`connection refused` 才是没装好

### 1.4 【实况】Controller 装错节点的坑(文档未覆盖)
- 现象:Controller Pod Running 但 `curl localhost` **静默无输出**(Connection reset by peer)
- 原因链:main 分支的最新 kind 清单**不再自带** `nodeSelector: ingress-ready=true` → Pod 调度到 worker(hostPort 80 开在 worker 容器)→ 而 extraPortMappings 只映射**控制面**容器:80 → 控制面容器里没人听 80 → reset
- 诊断思路(网络排错通用):Pod 状态(`get pods -o wide` 看节点)→ 分段测(容器内 curl)→ 端口监听(`ss -ltn` 看谁在听)——**"静默"比"报错"信息少,要用 `-v`/退出码/分段测试把死点逼出来**
- 修复:
```bash
kubectl -n ingress-nginx patch deployment ingress-nginx-controller \
  -p '{"spec":{"template":{"spec":{"nodeSelector":{"ingress-ready":"true","kubernetes.io/os":"linux"}}}}}'
# Pod 重新调度回控制面(它带着 ch01 打的 ingress-ready 标签)→ 链路全通
```
- 对照:老版本清单自带该 selector,所以老文档照抄能过——**清单会随版本变,原理不变**

## 二、Ingress 资源解剖(lab03 最简形态先讲)

### 2.1 最简形态:按域名路由(虚拟主机)
```yaml
apiVersion: networking.k8s.io/v1     # 网络组的 API
kind: Ingress
metadata:
  name: host-routing
  namespace: ing-lab
spec:
  ingressClassName: nginx            # 指名交给"nginx 家"的 Controller 执行
  rules:                             # 规则列表:多条 host 完全独立
    - host: a.demo.local             # 卡 1
      http:
        paths:
          - path: /                  # 这个域名下所有路径全收
            pathType: Prefix
            backend:
              service: { name: app1, port: { number: 80 } }   # 下一跳
    - host: b.demo.local             # 卡 2:与卡 1 零耦合
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service: { name: app2, port: { number: 80 } }
```
- **`ingressClassName` 必须理解**:集群可装多个品牌的 Controller,每张表要指名给谁执行,不然没人认领("规则不干活"的配套机制)
- **路由依据是 HTTP Host 头**(每个 HTTP 请求必带,客户端自称要访问谁):
```
Host: a.demo.local → 命中卡 1 → app1
Host: 未知域名     → 谁都不匹配 → 404(无 defaultBackend 时)
```
- **域名不需要真实存在/可解析**——路由只看请求头自称什么
- 虚拟主机价值:一台入口服务器、一个 IP,hosting 无限个"独立网站";域名卡和路径卡可嵌套(host 下还可以有自己的 paths)

### 2.2 Host 头与两种等价测法
```bash
# 前置:hosts 文件加假域名(本地"名字→IP"翻译表,优先于一切 DNS)
echo "127.0.0.1 a.demo.local b.demo.local" | sudo tee -a /etc/hosts

curl -s http://a.demo.local/                      # 测法一:走 hosts 翻译
curl -s -H "Host: a.demo.local" http://localhost/ # 测法二:手动带 Host 头
```
- 两种测法**到达 nginx 时一模一样**:目的地 127.0.0.1:80 + Host 头——殊途同归,hosts 只是让客户端帮你带上头
- 测法二的价值:把"路由依据 = Host 头"赤裸裸演示(随便编个 Host → 404)
- 浏览器测试需 Windows 侧 hosts(`C:\Windows\System32\drivers\etc\hosts`,管理员)——可选

## 三、路径路由与 rewrite(lab02 全解)

### 3.1 完整配置逐字段注解
```yaml
metadata:
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /$2   # Controller 私货接口:重写路径
spec:
  ingressClassName: nginx
  rules:
    - host: demo.local                 # 一个域名
      http:
        paths:                         # 卡内按路径分流
          - path: /app1(/|$)(.*)       # 正则前缀(见 3.3 拆解)
            pathType: ImplementationSpecific   # 正则只有这种模式支持
            backend:
              service: { name: app1, port: { number: 80 } }
          - path: /app2(/|$)(.*)
            pathType: ImplementationSpecific
            backend: { service: { name: app2, port: { number: 80 } } }
```

### 3.2 三个新面孔各司其职
| 字段 | 作用 |
|------|------|
| `ingressClassName` | 指定执行者(同 2.1) |
| `pathType: ImplementationSpecific` | 匹配语义交给 Controller 定——ingress-nginx 里 = 支持正则路径 |
| `rewrite-target: /$2` | 门口剥前缀(见 3.4) |

### 3.3 pathType 三取值
| 取值 | 语义 |
|------|------|
| `Prefix` | 前缀匹配(按路径**组件**整段匹配:`/app` 匹配 `/app/x` 不匹配 `/apple`) |
| `Exact` | 精确等于 |
| `ImplementationSpecific` | 交给 Controller 解释;ingress-nginx = 支持正则 |
- 正则路径(`(/|$)(.*)`)**必须**用 ImplementationSpecific——Prefix 模式下正则被当字面字符串,永远匹配不上

### 3.4 rewrite-target: /$2——为什么要剥前缀
- 问题:直接按 `/app1` 原样转发,后端 nginx 找 `/usr/share/nginx/html/app1/index.html` → 不存在 → 404
- **后端不知道自己是 app1**——路径前缀只是入口侧的路由暗号,后端没义务配合;入口侧的事入口侧解决
- 机制:path 正则有两个捕获组,`$2` 引用第二个:
```
/app1(/|$)(.*)
      ↑     ↑
     $1    $2(前缀后面剩下的全部)
rewrite-target: /$2 = 把请求路径重写成 $2
```
| 你请求 | $2 捕获 | 后端收到 |
|--------|---------|----------|
| /app1/ | 空 | / (正中 index.html) |
| /app1/index.html | index.html | /index.html |
| /app1 | 空(尾部$兜住) | / |
- `(/|$)` 是防误伤设计:`/app10` 中 "app1" 后面是 `0`,不满足 → 不匹配
- 注解认知呼应第 10 章:**标准 spec 管通用语义,annotations 是各家 Controller 的扩展通道**(canary 灰度/limit-rps 限流/ssl-redirect 都在这)

## 四、TLS 终结(lab04 全解)

### 4.1 完整配置注解
```yaml
metadata:
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"   # HTTP 一律 301 踢去 HTTPS
spec:
  ingressClassName: nginx
  tls:                            # ★ 证书声明(与路由解耦)
    - hosts: [demo.local]         # 这张证书服务哪个域名(对应证书 CN/SAN)
      secretName: demo-tls        # 引用 kubernetes.io/tls 类型 Secret
  rules:                          # 路由规则与 lab02 逐字相同
    - host: demo.local
      http:
        paths:
          - path: /app1(/|$)(.*)
            pathType: ImplementationSpecific
            backend: { service: { name: app1, port: { number: 80 } } }
```
- **Controller 的动作**:watch 到 tls 段 → 把 Secret 里的证书+私钥加载进 nginx → 在 443 上做 TLS 握手
- **证书与路由解耦**:tls 段只管"demo.local 的 HTTPS 用哪张证书",rules 才管流量去哪——两者按域名关联;一个 Secret 可被多个 Ingress 引用(通配符证书场景)

### 4.2 TLS 终结(Termination)终结在哪
```
浏览器 ──[HTTPS 加密]──► Controller(443)      ← 加密段到此为止
                          │ 解密(终结点)
                          ▼ 明文 HTTP
                        Service app1 ──► Pod(明文:80)
```
- **终结 = 加密在 Controller 被终止(解密)**,集群内部全明文——默认模式与行业惯例
- 原因:集群内部是可信域(有 NetworkPolicy/RBAC 设防),内部再加密开销大;证书管理收敛到入口一处,后端服务完全不知道 TLS 存在(lab01 的 backend nginx 没有任何证书配置)
- 反义:TLS 透传(passthrough,加密包原样转发、后端自己解密)——后端要做双向认证等极少数场景,知道即可

### 4.3 证书的来路:gen-tls.sh(自签 + 存档 + 销毁)
```bash
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout tls.key -out tls.crt \
  -subj "/CN=${DOMAIN}" \
  -addext "subjectAltName=DNS:${DOMAIN}"     # 证书声称代表这个域名(CN/SAN 不匹配 → 浏览器告警)

kubectl create secret tls demo-tls --cert=tls.crt --key=tls.key -n "$NS" \
  --dry-run=client -o yaml | kubectl apply -f -    # 存成 tls 类型 Secret(固定两把钥匙)
rm -f tls.key tls.crt                              # 私钥不留盘
```
- 自签证书:加密功能完整,但没有权威 CA 背书 → 客户端校验会失败,**curl 加 `-k` 跳过校验**("自己担责");生产用 Let's Encrypt/商业证书
- `kubernetes.io/tls` 类型固定 `tls.crt` + `tls.key` 两个键(10 章 6.7 的专用信封);`get ingress` 的 PORTS 列出现 443 = Controller 已接管 TLS

### 4.4 ssl-redirect 与验证现象
```bash
curl -s -o /dev/null -w '%{http_code} → %{redirect_url}\n' http://demo.local/app1/
# 301 → https://demo.local/app1/        ← HTTP 被踢
curl -sk https://demo.local/app1/      # I am APP-1 (v1)
```
- ssl-redirect 其实是**默认行为**(有 tls 段就自动跳);显式写的价值是能反向设 `"false"`(健康检查等端点不跳转)
- 404 出现在 `/app2`:本清单只配了 /app1 一条规则——404 来自 Controller(查无此路由),练习:把 /app2 的 path 搬进来

## 五、演示应用的设计(lab01)

### 5.1 对称结构:只差一句话的孪生应用
```
Namespace ing-lab
├── ConfigMap ×2(index.html:"I am APP-1/APP-2")     ← 10 章:配置外置
├── Deployment ×2(nginx:1.27-alpine ×2 副本)        ← 05 章
└── Service ×2(ClusterIP)                            ← 08 章
```
- **设计目的**:两个应用除文案全同 → 路由效果肉眼可辨(页面自报家门,不能自己骗自己)
- 挂载点 `/usr/share/nginx/html` = nginx 官方镜像默认网页根目录(约定);ConfigMap 目录挂载投影出 index.html(10 章标准应用;对照 04 章 init 容器写同一位置)
- Service 是 ClusterIP:给 Ingress 当内部下一跳,自己不对暴露——"入口统一收口"的含义

### 5.2 基线验证(绕过 Ingress 直连后端)
```bash
kubectl run curl-test --image=curlimages/curl:8.9.1 -n ing-lab --restart=Never --rm -it -- \
  curl -s http://app1          # I am APP-1(集群内部短名经 CoreDNS 解析)
```
- 先证"货是好的",再测"门卫的路由"——分层验证的实验方法

## 六、一条 HTTPS 请求的完整旅程(全章拼图)
```
浏览器 https://demo.local/app1/
  ① hosts:demo.local → 127.0.0.1(本地名字翻译)
  ② TCP:WSL:443 → extraPortMappings(ch01)→ 控制面容器 443
  ③ TLS 握手:Controller 出示 demo-tls 证书,协商加密通道(本实验)
  ④ 解密:拿到明文 "GET /app1/"
  ⑤ 路由:正则命中 → rewrite 剥前缀(lab02)→ 转给 Service app1
  ⑥ 后端:Pod 明文应答 → 原路加密返回
```
- ①②是环境基建,③④是 TLS,⑤是路由,⑥是 08 章转发——九章零件各就各位

## 七、排错与速查

### 7.1 两个错误码的分诊
| 错误码 | 含义 | 排查 |
|--------|------|------|
| **404** | 规则没匹配上(Host/path 写错) | `describe ingress` 核对;`-H` 手动带 Host 验证 |
| **503** | 规则命中但后端没人 | `kubectl get endpoints -n ing-lab`(空 = Service 没找到 Pod) |
| 连接 refused/reset | 链路断:端口没监听/映射错节点 | 见 1.4 分段诊断法 |
- 与 13 章呼应:404 是应用层"查无此路由"(连接是通的);NetworkPolicy 的 DROP 是超时——**超时/404/503 三种现象对应三种死法**

### 7.2 常用注解速查(ingress-nginx)
| 注解 | 作用 |
|------|------|
| rewrite-target | 路径重写(剥前缀) |
| ssl-redirect | 强制跳 HTTPS(有 tls 段时默认 true) |
| canary / canary-weight | 金丝雀灰度(按权重分流,两个 Ingress 同 host) |
| limit-rps | 限流 |
- 注解是 Controller 的扩展通道;标准 spec 之外的私货,换品牌 Controller 注解全部失效

### 7.3 收尾三件套
```bash
kubectl delete ns ing-lab                  # ① 删实验应用与 Secret
kubectl delete -f <controller 清单地址>     # ② 删 Controller(不打算长期用的话)
sudo sed -i '/demo.local/d;/a.demo.local/d;/b.demo.local/d' /etc/hosts   # ③ 清假域名
```
- hosts 不清的后果:以后 curl 这些域名永远指向 127.0.0.1(隐形坑)

### 7.4 面试要点速记
- Ingress 与 Service 分工:七层路由表 vs 四层转发;Ingress 依赖 Controller 执行(无内置)
- 路由依据:Host 头 + path;pathType 三取值;正则要 ImplementationSpecific
- rewrite 的动机:后端不认识路由前缀
- TLS 终结:加密止步于入口,内部明文(默认信任域);证书存 tls 类型 Secret
- 生产扩展:金丝雀灰度(canary 注解)、证书自动续期(cert-manager,未学,知道有此物)
