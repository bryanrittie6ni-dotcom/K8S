# 持久化存储映射

## PVC 清单

| PVC 名称 | 容量 | StorageClass | 访问模式 | 挂载路径 (容器内) | 所属 Pod |
|----------|------|-------------|----------|-------------------|----------|
| `postgres-data` | 10Gi | local-path | RWO | `/var/lib/postgresql/data` | postgres |
| `clickhouse-data` | 20Gi | local-path | RWO | `/var/lib/clickhouse` | clickhouse |
| `minio-data` | 10Gi | local-path | RWO | `/data` | minio |

## 无需 PVC 的服务

| 服务 | 原因 |
|------|------|
| Redis | AOF 文件在容器内持久化，重启后通过 AOF 恢复，数据量小 |

## StorageClass 详情

```
NAME: local-path (default)
PROVISIONER: rancher.io/local-path
RECLAIM POLICY: Delete
VOLUME BINDING MODE: WaitForFirstConsumer
```

### 实际存储位置

`local-path` provisioner 在节点上创建的实际路径：

```
/var/lib/rancher/k3s/storage/pvc-<uuid>_llmops_<pvc-name>/
```

每个 PVC 对应一个目录，以 hostPath 方式挂载到 Pod。

### WaitForFirstConsumer 行为

- PVC 创建时状态为 `Pending`
- 当 Pod 被调度到节点后，provisioner 才在该节点创建实际存储
- **这意味着 PVC 与 Pod 绑定在同一节点** — Pod 迁移到其他节点后 PVC 不会跟随

## 数据重建注意事项

| 操作 | 后果 |
|------|------|
| 删除 PVC | **所有数据永久丢失**（Reclaim Policy: Delete） |
| 删除 Deployment 保留 PVC | 数据保留，重新部署后自动挂载 |
| 升级 PostgreSQL 大版本 | PVC 数据不兼容，需要 pg_dump/pg_restore 或删除 PVC |
| 节点故障 | 数据随节点丢失（local-path 无复制）— 需定期备份 |

## 备份建议

```bash
# PostgreSQL 备份
kubectl exec -n llmops deployment/postgres -- pg_dumpall -U postgres > backup.sql

# ClickHouse 备份
kubectl exec -n llmops deployment/clickhouse -- clickhouse-client --query "BACKUP DATABASE * TO Disk('backups', 'backup.zip')"
```
