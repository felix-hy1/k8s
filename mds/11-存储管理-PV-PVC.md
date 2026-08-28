# 第 11 章 存储管理:Volume、PV、PVC 与 StorageClass

> 📁 本章实验资源(yaml / 脚本 / sql)位于 `D:\k8s\11-存储管理-PV-PVC\`,本文档位于 `D:\k8s\mds\`。

## 学习目标

1. 掌握常用 Volume 类型及各自生命周期
2. 深刻理解 PV/PVC 解耦模型:开发人员"要多少",基础设施"给什么"
3. 在 kind 里玩转静态供给(手工 PV)与动态供给(StorageClass)

## 11.1 核心概念

### 卷类型速览

| 类型 | 生命周期 | 用途 |
|------|----------|------|
| emptyDir | 与 Pod 相同 | 容器间共享临时数据(缓存/工作目录) |
| hostPath | 节点目录 | DaemonSet 访问节点文件(日志/Socket);生产慎用 |
| configMap/secret | 随对象 | 配置注入(第 10 章) |
| PVC | 独立于 Pod | 真正的持久存储,Pod 挂了数据还在 |

### PV/PVC 模型(面试必考)

```
Pod --引用--> PVC(申请:多大?什么模式?)--绑定--> PV(实际存储资源)
                     ↑ 开发人员写                          ↑ 存储管理员/自动供给器创建
                     └────────── StorageClass(动态供给的"货源")──────────┘
```

- **PVC 是 Namespace 级**,PV 是集群级
- 绑定后 PV 与 PVC 一一对应;PVC 不删,PV 不会释放
- **访问模式**:`ReadWriteOnce(RWO)` 单节点读写 / `ReadOnlyMany(ROX)` 多节点只读 / `ReadWriteMany(RWX)` 多节点读写(需要 NFS/CephFS 等支持)
- **回收策略**:`Retain`(保留,手动清理)/ `Delete`(删 PVC 连带删存储)/ `Recycle`(已废弃)
- `volumeName`、容量、访问模式同时匹配才能静态绑定

### kind 的默认 StorageClass

kind 自带 `standard`(rancher local-path-provisioner):**动态供给、hostPath 落盘、回收策略 Delete**。第 06 章 MySQL 的 PVC 就是它供给的。

---

## 实验列表

### 实验 1:emptyDir 与 hostPath

```bash
cd /mnt/d/k8s/11-存储管理-PV-PVC/manifests
kubectl apply -f lab01-emptydir-hostpath.yaml
# emptyDir:容器 A 写,容器 B 读
kubectl logs vol-demo -c reader -n stor-lab
# hostPath:写进节点 /tmp/k8s-hostpath,直接在"节点容器"里验证
docker exec k8s-learning-worker cat /tmp/k8s-hostpath/hello.txt
```

### 实验 2:静态供给(手工 PV + PVC)

```bash
# 1) 先在 worker 节点上准备目录(kind 节点=容器,所以要 docker exec)
bash /mnt/d/k8s/11-存储管理-PV-PVC/scripts/prepare-pv-dirs.sh

kubectl apply -f lab02-pv-pvc-static.yaml
kubectl get pv,pvc -n stor-lab
# 观察:PV 10Gi 与 PVC 5Gi 能绑定吗?→ 能!绑定看"容量够不够",不是精确匹配
# 观察:pvc-pending-demo 故意要 50Gi → Pending(没有 PV 满足)

kubectl get pv pv-manual-1 -o jsonpath='{.spec.claimRef.name}{"\n"}'   # 反查绑定关系
```

### 实验 3:动态供给(StorageClass + PVC)

```bash
kubectl apply -f lab03-pvc-dynamic.yaml
kubectl get pvc -n stor-lab -w        #几秒内 Pending → Bound
kubectl get pv | grep dynamic          #系统自动创建了 PV

# 写数据 → 删 Pod → 数据仍在(重建 Pod 复用同一 PVC)
kubectl apply -f lab03-pvc-dynamic.yaml   # 已含写入 Pod;先删 Pod 再重建验证
kubectl delete pod data-writer -n stor-lab --wait=false
kubectl apply -f lab03-pvc-dynamic.yaml
kubectl logs data-writer -n stor-lab      # 第二次能看到上次写入的文件
```

### 观察"卷抓取"过程(进阶)

```bash
kubectl describe pod data-writer -n stor-lab | grep -A5 Volumes
kubectl get storageclass
```

### 清理

```bash
kubectl delete ns stor-lab
kubectl get pv        # 静态 PV 的 Retain 策略会留下 Released 状态的 PV,需手动删
kubectl delete pv pv-manual-1 pv-manual-2 --ignore-not-found
```

## 常见问题

| 问题 | 答案 |
|------|------|
| PVC 一直 Pending? | 静态:没有容量/模式匹配的可用 PV;动态:StorageClass 的 provisioner 没就绪 |
| StatefulSet 的 PVC 与普通 PVC 区别? | sts 用 volumeClaimTemplates 为每个副本生成专属 PVC,随 Pod 而非模板删除 |
| 删除 PVC 为什么卡 Terminating? | 有 Pod 还在用;先删 Pod |
| RWX 用不了? | 底层存储不支持;local-path/hostPath 只能 RWO |

## 练习任务

1. [ ] 建一个 2Gi 的 PVC 并挂到两个不同节点的 Pod(RWO),观察第二个 Pod 挂载失败
2. [ ] 把 pv-manual-1 的 persistentVolumeReclaimPolicy 改成 Delete,删除 PVC 看发生什么
3. [ ] `kubectl explain pv.spec` 通读一遍字段

## 参考

- https://kubernetes.io/zh-cn/docs/concepts/storage/persistent-volumes/
