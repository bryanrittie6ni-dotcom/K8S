# 整体架构

## 服务拓扑

```
Internet
    │
    │ HTTPS (443)
    ▼
┌─────────────────────────────────────────────────────┐
│ nginx (LoadBalancer)                                │
│ External-IP: 192.168.0.2, 172.17.0.10              │
│ TLS: www.ailiwen.com.cn                             │
│                                                     │
│ /            → llmops-ui:3000                       │
│ /api/*       → llmops-api:5001                      │
│ /langfuse    → langfuse-web:3000   ← ═══════════╗  │
└─────────────────────────────────────────────────║──┘
                                                   ║
┌─────────────────────────────────────────────────║──┐
│ llmops Namespace (vm-0-10-ubuntu)              ║  │
│                                                 ║  │
│  ┌──────────────────────────────┐              ║  │
│  │ langfuse-web (Next.js)       │◄─────────────╝  │
│  │ port: 3000                   │                  │
│  │ envFrom: secret + configmap  │                  │
│  └──────────┬───────────────────┘                  │
│             │                                       │
│  ┌──────────┴───────────────────┐                  │
│  │ langfuse-worker (BullMQ)     │                  │
│  │ port: 3030                   │                  │
│  │ envFrom: secret + configmap  │                  │
│  └──────────┬───────────────────┘                  │
│             │                                       │
│  ┌──────────┼───────────────────────────────────┐  │
│  │          依赖服务 (均为 ClusterIP)            │  │
│  │                                              │  │
│  │  ┌──────────┐ ┌───────────┐ ┌───────┐ ┌────┐ │  │
│  │  │postgres  │ │clickhouse │ │ redis │ │minio│ │  │
│  │  │  :5432   │ │ :8123/9000│ │ :6379 │ │:9000│ │  │
│  │  │ 10Gi PVC │ │ 20Gi PVC  │ │  AOF  │ │10Gi │ │  │
│  │  └──────────┘ └───────────┘ └───────┘ └────┘ │  │
│  └──────────────────────────────────────────────┘  │
│                                                    │
│  ┌────────────┐ ┌────────┐                         │
│  │ llmops-ui  │ │ nginx  │  (已有服务)              │
│  │  :3000     │ │ :80/443│                         │
│  └────────────┘ └────────┘                         │
└────────────────────────────────────────────────────┘
```

## Namespace 资源完整清单

### Secrets

| 名称 | 类型 | 内容 |
|------|------|------|
| `langfuse-secrets` | Opaque | DB密码、S3密钥、加密密钥 |
| `ccr-registry` | dockerconfigjson | CCR 私有仓库凭据 |
| `nginx-tls` | kubernetes.io/tls | www.ailiwen.com.cn 证书 |

### ConfigMaps

| 名称 | 用途 |
|------|------|
| `langfuse-config` | Langfuse 所有非敏感配置 |
| `nginx-config` | Nginx 反向代理规则 |

### Deployments (8个)

| Deployment | 副本 | 镜像来源 |
|------------|------|----------|
| postgres | 1 | CCR |
| clickhouse | 1 | CCR |
| redis | 1 | CCR |
| minio | 1 | CCR |
| langfuse-web | 1 | CCR (用户构建) |
| langfuse-worker | 1 | CCR (用户构建) |
| nginx | 1 | (已有) |
| llmops-ui | 1 | CCR (已有) |

### Services (9个)

| Service | 类型 | 端口 |
|---------|------|------|
| nginx | LoadBalancer | 80, 443 |
| langfuse-web | ClusterIP | 3000 |
| langfuse-worker | ClusterIP | 3030 |
| postgres | ClusterIP | 5432 |
| clickhouse | ClusterIP | 8123, 9000 |
| redis | ClusterIP | 6379 |
| minio | ClusterIP | 9000, 9001 |
| llmops-ui | ClusterIP | 3000 |
| llmops-api | ClusterIP | 5001 (Placeholder) |

### PVCs (3个)

| PVC | 容量 | 绑定 Pod |
|-----|------|-----------|
| postgres-data | 10Gi | postgres |
| clickhouse-data | 20Gi | clickhouse |
| minio-data | 10Gi | minio |

### Jobs (一次性)

| Job | 状态 | 用途 |
|-----|------|------|
| minio-create-bucket | Completed | 创建 S3 bucket `langfuse` |

## 环境变量流转

```
┌─ Secret: langfuse-secrets ─────────┐
│ DATABASE_URL                       │
│ CLICKHOUSE_PASSWORD                │
│ REDIS_AUTH                         │
│ LANGFUSE_S3_*_ACCESS_KEY_ID        │
│ LANGFUSE_S3_*_SECRET_ACCESS_KEY    │
│ NEXTAUTH_SECRET, SALT, ENCRYPTION  │
└────────────┬───────────────────────┘
             │ envFrom.secretRef
             ▼
┌─ ConfigMap: langfuse-config ───────┐
│ NEXTAUTH_URL                       │
│ CLICKHOUSE_URL / MIGRATION_URL     │
│ CLICKHOUSE_USER                    │
│ REDIS_HOST / PORT                  │
│ LANGFUSE_S3_*_BUCKET / ENDPOINT    │
│ LANGFUSE_LOG_LEVEL / FORMAT        │
└────────────┬───────────────────────┘
             │ envFrom.configMapRef
             ▼
     ┌──────────────┐
     │ langfuse-web │  + HOSTNAME, NODE_ENV, PORT (直接 env)
     │   :3000      │
     └──────────────┘
```

## 关键设计决策

| 决策 | 原因 |
|------|------|
| 全部走 CCR 镜像 | 国内无法稳定访问 Docker Hub |
| 所有 Pod 绑定 control-plane | 跨节点 L2 不通，host-gw 模式限制 |
| Redis 无 PVC | 数据量小，AOF 容器内恢复即可 |
| MinIO Bucket 用 Job 创建 | 避免 initContainer 依赖 MinIO 先启动 |
| ConfigMap + Secret 分离 | 敏感/非敏感配置分离管理 |
