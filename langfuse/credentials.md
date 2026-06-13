# 账号密码与连接串

## 数据库账号

### PostgreSQL

| 项 | 值 |
|----|-----|
| 主机 | `postgres` (K8s Service DNS) |
| 端口 | `5432` |
| 用户 | `postgres` |
| 密码 | `postgres5432` |
| 数据库 | `postgres` |
| 连接串 | `postgresql://postgres:postgres5432@postgres:5432/postgres` |
| 环境变量 | `DATABASE_URL` (在 Secret `langfuse-secrets` 中) |

### ClickHouse

| 项 | 值 |
|----|-----|
| HTTP 端点 | `http://clickhouse:8123` |
| Native 端点 | `clickhouse://clickhouse:9000` |
| 用户 | `clickhouse` |
| 密码 | `clickhouse` |
| 环境变量 (ConfigMap) | `CLICKHOUSE_URL`, `CLICKHOUSE_MIGRATION_URL`, `CLICKHOUSE_USER` |
| 环境变量 (Secret) | `CLICKHOUSE_PASSWORD` |

### Redis

| 项 | 值 |
|----|-----|
| 主机 | `redis` (K8s Service DNS) |
| 端口 | `6379` |
| 密码 | `myredissecret` |
| 环境变量 (ConfigMap) | `REDIS_HOST`, `REDIS_PORT` |
| 环境变量 (Secret) | `REDIS_AUTH` |

## S3 / MinIO

| 项 | 值 |
|----|-----|
| 端点 | `http://minio:9000` |
| Access Key | `minio` |
| Secret Key | `miniosecret` |
| Bucket | `langfuse` |
| Region | `us-east-1` (强制路径风格) |

S3 用途分离（3 组凭据，当前值相同）：

| 用途 | Access Key 环境变量 | Secret Key 环境变量 |
|------|---------------------|----------------------|
| 事件上传 | `LANGFUSE_S3_EVENT_UPLOAD_ACCESS_KEY_ID` | `LANGFUSE_S3_EVENT_UPLOAD_SECRET_ACCESS_KEY` |
| 媒体上传 | `LANGFUSE_S3_MEDIA_UPLOAD_ACCESS_KEY_ID` | `LANGFUSE_S3_MEDIA_UPLOAD_SECRET_ACCESS_KEY` |
| 批量导出 | `LANGFUSE_S3_BATCH_EXPORT_ACCESS_KEY_ID` | `LANGFUSE_S3_BATCH_EXPORT_SECRET_ACCESS_KEY` |

## NextAuth / 安全密钥

| 项 | 值 | 用途 |
|----|-----|------|
| `NEXTAUTH_SECRET` | `f0f89a225...` | 会话加密 (openssl rand -hex 32) |
| `SALT` | `015e2d1be3...` | API Key 哈希盐值 |
| `ENCRYPTION_KEY` | `9be8ff574c...` | 数据加密密钥 (部署后不可更改) |

## NEXTAUTH_URL

```
NEXTAUTH_URL=https://www.ailiwen.com.cn/langfuse
```

## K8s 资源位置

- **Secret**: `llmops/langfuse-secrets` (Opaque)
- **ConfigMap**: `llmops/langfuse-config`

## 镜像仓库凭据

- **Secret**: `llmops/ccr-registry` (kubernetes.io/dockerconfigjson)
- **仓库**: `ccr.ccs.tencentyun.com/my-app-20/`
