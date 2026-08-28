# 第 19 章 综合实战:生产风格部署 WordPress + MySQL

> 📁 本章实验资源(yaml / 脚本 / sql)位于 `D:\k8s\19-综合实战-WordPress\`,本文档位于 `D:\k8s\mds\`。

## 学习目标

把前面 18 章的全部知识串成一个真实项目:

> Namespace 隔离 → Secret 管口令 → ConfigMap 管初始化 SQL → PVC 持久化 → Deployment/探针/资源 → Service → Ingress → 故障演练

## 19.1 架构图

```
浏览器 http://wp.demo.local
        │(hosts: 127.0.0.1 wp.demo.local)
        ▼
Ingress(ingress-nginx,第 09 章已装)
        ▼
Service wordpress (ClusterIP)
        ▼ 80
Deployment wordpress ──┐ WORDPRESS_DB_HOST=mysql.wordpress.svc
                        ▼ 3306
Service mysql (ClusterIP,仅集群内可见)
        ▼
Deployment mysql:8.0 ── PVC 8Gi(standard 动态供给)
        └ 初始化:/docker-entrypoint-initdb.d/01-init.sql(ConfigMap)
```

## 19.2 部署顺序(依赖决定顺序,必须照做)

```bash
cd /mnt/d/k8s/19-综合实战-WordPress/manifests

# 1) 数据库(先起!)
kubectl apply -f lab01-mysql.yaml
kubectl -n wordpress rollout status deployment/mysql --timeout=180s

# 2) 应用
kubectl apply -f lab02-wordpress.yaml
kubectl -n wordpress rollout status deployment/wordpress --timeout=180s

# 3) 入口(hosts 加映射后 apply)
echo "127.0.0.1 wp.demo.local" | sudo tee -a /etc/hosts
kubectl apply -f lab03-ingress.yaml
```

Windows 浏览器打开 **http://wp.demo.local**,应看到 WordPress 著名的 5 分钟安装向导(选语言 → 站点名 → 完成安装)。

> 前置:ingress-nginx 已按第 09 章安装;没装就先 `kubectl apply -f <kind deploy.yaml>`。

## 19.3 逐层验证清单

| 层 | 命令 | 预期 |
|----|------|------|
| PVC | `kubectl get pvc -n wordpress` | mysql-data Bound |
| 数据库 | `kubectl exec -n wordpress deploy/mysql -- mysql -uroot -pRoot@123456 -e "SHOW DATABASES;"` | 含 wordpress、wp_stats |
| 初始化 SQL | 同上 `-e "USE wp_stats; SELECT * FROM deploy_log;"` | 有一条部署记录 |
| 应用探针 | `kubectl get pods -n wordpress` | wordpress 1/1 Ready |
| Service | `kubectl run c --rm -it --image=curlimages/curl --restart=Never -- curl -sI http://wordpress.wordpress` | 200 |
| Ingress | `curl -sI http://wp.demo.local` | 200 |

## 19.4 故障演练(必做)

```bash
# 1) 杀数据库:WordPress 应短暂报错,自愈后恢复
kubectl delete pod -n wordpress -l app=mysql
#   → Deployment 重建(第 05 章),PVC 数据还在(第 11 章)

# 2) 扩容 WordPress 副本:验证无状态服务随便扩
kubectl scale deployment wordpress -n wordpress --replicas=3
kubectl get pods -n wordpress -o wide    # 分散在多节点(第 12 章)

# 3) 观察配置链路
kubectl exec -it deploy/wordpress -n wordpress -- env | grep WORDPRESS_   # Secret 注入的证据
```

## 19.5 sql/init.sql 说明

通过 ConfigMap 挂到 `/docker-entrypoint-initdb.d/`,**首次建库时自动执行**:

- `wordpress` 库由镜像的 `MYSQL_DATABASE` 环境变量创建(应用主库)
- `wp_stats` 库由本脚本创建,并插入 `deploy_log` 部署审计表(演示 SQL 初始化链路)

## 19.6 升级与回滚练习

```bash
# 记录变更原因
kubectl annotate deployment wordpress kubernetes.io/change-cause="wp 6.7" -n wordpress --overwrite
# 换镜像(升 PHP 版本线)
kubectl set image deployment/wordpress wordpress=wordpress:php8.3-apache -n wordpress
kubectl rollout status deployment/wordpress -n wordpress
kubectl rollout history deployment/wordpress -n wordpress
kubectl rollout undo deployment/wordpress -n wordpress
```

## 19.7 清理

```bash
kubectl delete ns wordpress
sudo sed -i '/wp.demo.local/d' /etc/hosts
```

## 进阶方向(学完可挑战)

1. 用 Helm 把本项目改造成 Chart(第 17 章知识)
2. 换成 StatefulSet 部署 MySQL(第 06 章模板)
3. 备份 CronJob:每天 `mysqldump` 到 PVC(第 07 章 + SQL)
4. 加 NetworkPolicy:只允许 wordpress 访问 3306(第 13 章,需 Calico 集群)
