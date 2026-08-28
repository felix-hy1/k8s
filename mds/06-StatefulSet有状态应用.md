# 第 06 章 StatefulSet 与有状态应用(MySQL 实战)

> 📁 本章实验资源(yaml / 脚本 / sql)位于 `D:\k8s\06-StatefulSet有状态应用\`,本文档位于 `D:\k8s\mds\`。

## 学习目标

1. 理解"有状态"与"无状态"的差异及 StatefulSet 的三大承诺
2. 掌握 Headless Service 与稳定网络标识
3. 用 StatefulSet + ConfigMap(SQL 脚本)+ Secret + PVC 部署生产风格的 MySQL
4. 学会对有状态应用做数据持久性验证

## 6.1 核心概念

### Deployment 做不到什么?

数据库、消息队列、分布式存储这类应用需要:**稳定的网络名**、**稳定的存储**、**有序启停**。Pod 名随机 + 共享存储的 Deployment 模式会直接崩溃。

### StatefulSet 的三大承诺

| 承诺 | 说明 |
|------|------|
| 稳定网络标识 | Pod 名固定:`<sts名>-<序号>`,配合 Headless Service 得到 DNS:`mysql-0.mysql.ns.svc.cluster.local` |
| 稳定存储 | `volumeClaimTemplates` 为每个 Pod 生成专属 PVC,Pod 重启(哪怕调度到别的节点)仍挂回原来的卷 |
| 有序启停 | 创建 0→N 顺序,删除 N→0 逆序;更新也逐个进行(默认 RollingUpdate,可改 OnDelete) |

### Headless Service(clusterIP: None)

- 不分配 VIP,DNS 直接解析到**每个 Pod 的 IP 列表**
- StatefulSet 通过 `serviceName` 字段与之绑定
- `mysql.mysql-ns.svc.cluster.local` → 所有 Pod;`mysql-0.mysql...` → 指定 Pod

### 有状态应用部署原则

1. 配置(建库建表 SQL)→ ConfigMap;口令 → Secret;数据 → PVC
2. MySQL 官方镜像约定:`/docker-entrypoint-initdb.d/` 下的 `.sql` 会在**首次初始化空数据目录**时自动执行
3. 单节点学习版够用;生产主从/集群推荐 Operator(见第 18 章)

---

## 实验列表

### 实验 1:稳定标识体验(nginx StatefulSet)

```bash
cd /mnt/d/k8s/06-StatefulSet有状态应用/manifests
kubectl apply -f lab01-headless-nginx.yaml
kubectl get pods -n sts-lab -w          # web-0 完全 Ready 后才创建 web-1,依次类推

# 每个 Pod 一条 DNS 记录
kubectl run dns-test --rm -it --image=busybox:1.36 --restart=Never -n sts-lab -- \
  nslookup web-0.web.sts-lab.svc.cluster.local
kubectl run dns-test --rm -it --image=busybox:1.36 --restart=Never -n sts-lab -- \
  nslookup web.sts-lab.svc.cluster.local   # 返回所有 Pod IP

# 删除中间的 Pod,名字不变、PVC 不变
kubectl delete pod web-1 -n sts-lab
kubectl get pods,pvc -n sts-lab          # web-1 重建,web-1 对应的 PVC 依旧在
```

### 实验 2:部署 MySQL 8.0(重点,串联 4 种资源)

```bash
kubectl apply -f lab02-mysql-statefulset.yaml
kubectl get pods -n mysql-ns -w          # 等 mysql-0 Running(约 30~60s)
kubectl get pvc -n mysql-ns              # data-mysql-0 已 Bound

# 进入一次性客户端 Pod,连 MySQL
kubectl exec -it mysql-client -n mysql-ns -- \
  mysql -h mysql-0.mysql.mysql-ns.svc.cluster.local -uroot -pRoot@123456

# 在 MySQL 里验证初始化脚本(sql/01-init.sql)已自动执行:
#   SHOW DATABASES;                 → 有 k8s_learning
#   USE k8s_learning; SELECT * FROM students;
#   SHOW GRANTS FOR 'dev'@'%';
```

### 实验 3:数据持久性演练

```bash
# 写入一条新数据
kubectl exec -it mysql-client -n mysql-ns -- \
  mysql -h mysql-0.mysql -uroot -pRoot@123456 \
  -e "USE k8s_learning; INSERT INTO students(name,major,score) VALUES('赵六','云计算',95);"

# 杀掉数据库 Pod(模拟故障)
kubectl delete pod mysql-0 -n mysql-ns

# 重建后数据还在 → PVC 兜住了
kubectl exec -it mysql-client -n mysql-ns -- \
  mysql -h mysql-0.mysql -uroot -pRoot@123456 \
  -e "USE k8s_learning; SELECT COUNT(*) FROM students;"
```

### 实验 4:用 sql/02-test-queries.sql 做查询练习

```bash
# 把文件内容直接灌进客户端执行(文件在 Windows 盘,WSL 里路径 /mnt/d/...)
kubectl exec -i mysql-client -n mysql-ns -- \
  mysql -h mysql-0.mysql -uroot -pRoot@123456 < /mnt/d/k8s/06-StatefulSet有状态应用/sql/02-test-queries.sql
```

### 清理

```bash
kubectl delete ns sts-lab mysql-ns     # PVC 随 ns 删除(StorageClass Delete 策略)
```

## SQL 脚本说明(sql/ 目录)

| 文件 | 用途 |
|------|------|
| `01-init.sql` | 建库建表 + 种子数据 + 业务账号授权(内容已内嵌进 lab02 的 ConfigMap) |
| `02-test-queries.sql` | 查询练习:聚合、分组、连接,用于验证库可用 |

## 常见问题

| 问题 | 答案 |
|------|------|
| Pod 一直 `0/1` 起不来? | `describe` 看 events;多半是 PVC Pending 或探针密码错 |
| 改了 init.sql 不生效? | `/docker-entrypoint-initdb.d` 只在数据目录为空时执行一次;要重跑需删 PVC 重建 |
| 怎么扩容到多副本? | `kubectl scale sts mysql --replicas=2`;但 MySQL 多副本需要主从配置,生产用 Operator |
| StatefulSet 能滚动更新吗? | 能,默认逐个逆序更新;Partition 字段可实现灰度 |

## 练习任务

1. [ ] 把 sts-lab 的 nginx 扩到 5 副本,观察 PVC 逐个生成、命名规则
2. [ ] 给 lab02 的 MySQL 加一个 `03-grants.sql`(建只读账号),验证需删 PVC 才会重新初始化
3. [ ] `kubectl explain statefulset.spec.updateStrategy` 研究滚动/分区策略

## 参考

- https://kubernetes.io/zh-cn/docs/concepts/workloads/controllers/statefulset/
