# 前置依赖服务

Langfuse 依赖 4 个后端服务，全部部署在 `llmops` 命名空间的 `vm-0-10-ubuntu` 节点。

## 依赖关系图

```
langfuse-web (Next.js) ─────┬── PostgreSQL (主数据库，ORM + 业务数据)
                            ├── ClickHouse (分析事件存储)
                            ├── Redis (BullMQ 队列 + 缓存)
                            └── MinIO  (S3 对象存储: events/media/exports)

langfuse-worker ────────────同上────────────────────────────
```

## 各服务部署规格

### PostgreSQL

| 项 | 值 |
|----|-----|
| 镜像 | `ccr.ccs.tencentyun.com/my-app-20/postgres:17` |
| Service | `postgres:5432` (ClusterIP: 10.43.82.98) |
| PVC | `postgres-data` / 10Gi / local-path |
| 挂载路径 | `/var/lib/postgresql/data` |
| YAML | `k8s/postgres.yaml` |

### ClickHouse

| 项 | 值 |
|----|-----|
| 镜像 | `ccr.ccs.tencentyun.com/my-app-20/clickhouse-server:latest` |
| Service | `clickhouse:8123` (HTTP), `clickhouse:9000` (Native) |
| PVC | `clickhouse-data` / 20Gi / local-path |
| 挂载路径 | `/var/lib/clickhouse` |
| YAML | `k8s/clickhouse.yaml` |

### Redis

| 项 | 值 |
|----|-----|
| 镜像 | `ccr.ccs.tencentyun.com/my-app-20/redis:7` |
| Service | `redis:6379` |
| 启动参数 | `redis-server --requirepass myredissecret --appendonly yes` |
| 持久化 | AOF (容器内，无 PVC) |
| YAML | `k8s/redis.yaml` |

### MinIO (S3 兼容存储)

| 项 | 值 |
|----|-----|
| 镜像 | `ccr.ccs.tencentyun.com/my-app-20/minio:latest` |
| Service | `minio:9000` (API), `minio:9001` (Console) |
| PVC | `minio-data` / 10Gi / local-path |
| 挂载路径 | `/data` |
| Bucket | `langfuse` (由 Job `minio-create-bucket` 自动创建) |
| YAML | `k8s/minio.yaml` |

> ⚠️ MinIO 镜像是 Chainguard 构建的，以非 root 用户 (uid 65532) 运行，需要 `securityContext.fsGroup: 65532` + initContainer 修复 `/data` 权限。

## 部署顺序

```
1. Secret + ConfigMap  (凭据和配置)
2. PostgreSQL          (主数据库)
3. ClickHouse          (分析数据库)
4. Redis               (队列/缓存)
5. MinIO + Bucket Job  (对象存储)
6. langfuse-web        (前端 + API)
7. langfuse-worker     (后台任务)
```
