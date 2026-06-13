# 镜像清单

## 全部镜像

| 服务 | 镜像地址 | 用途 |
|------|----------|------|
| PostgreSQL | `ccr.ccs.tencentyun.com/my-app-20/postgres:17` | 主数据库 |
| ClickHouse | `ccr.ccs.tencentyun.com/my-app-20/clickhouse-server:latest` | 分析数据库 |
| Redis | `ccr.ccs.tencentyun.com/my-app-20/redis:7` | 队列 + 缓存 |
| MinIO | `ccr.ccs.tencentyun.com/my-app-20/minio:latest` | 对象存储 |
| MinIO Client | `ccr.ccs.tencentyun.com/my-app-20/minio-mc:latest` | 创建 Bucket (Job) |
| Langfuse Web | `ccr.ccs.tencentyun.com/my-app-20/langfuse-web:3` | 前端 + API |
| Langfuse Worker | `ccr.ccs.tencentyun.com/my-app-20/langfuse-worker:3` | 后台 Worker |

## 私有仓库配置

### Registry 地址

```
ccr.ccs.tencentyun.com/my-app-20/
```

腾讯云容器镜像服务 (CCR) — 私有仓库，需要认证。

### K8s 拉取凭据

```yaml
imagePullSecrets:
  - name: ccr-registry
```

Secret `llmops/ccr-registry` 类型为 `kubernetes.io/dockerconfigjson`，已在集群中创建。

### 上传镜像命令参考

```bash
# 从 Docker Hub 拉取并推送到 CCR
docker pull postgres:17
docker tag postgres:17 ccr.ccs.tencentyun.com/my-app-20/postgres:17
docker push ccr.ccs.tencentyun.com/my-app-20/postgres:17

# 同理
docker pull clickhouse/clickhouse-server:latest
docker tag clickhouse/clickhouse-server:latest ccr.ccs.tencentyun.com/my-app-20/clickhouse-server:latest
docker push ccr.ccs.tencentyun.com/my-app-20/clickhouse-server:latest

docker pull redis:7
docker tag redis:7 ccr.ccs.tencentyun.com/my-app-20/redis:7
docker push ccr.ccs.tencentyun.com/my-app-20/redis:7

docker pull minio/minio:latest
docker tag minio/minio:latest ccr.ccs.tencentyun.com/my-app-20/minio:latest
docker push ccr.ccs.tencentyun.com/my-app-20/minio:latest

docker pull minio/mc:latest
docker tag minio/mc:latest ccr.ccs.tencentyun.com/my-app-20/minio-mc:latest
docker push ccr.ccs.tencentyun.com/my-app-20/minio-mc:latest
```

### 为什么全部走 CCR

1. Docker Hub 在国内直连超时（`registry-1.docker.io` i/o timeout）
2. 阿里云镜像源（`registry.cn-hangzhou.aliyuncs.com`）返回 `pull access denied`
3. DaoCloud 镜像源（`docker.m.daocloud.io`）速度极慢（大镜像 >5min）
4. CCR 是从腾讯云直接拉取，速度稳定（3-30s）

> **教训：在国内部署 K8s，所有公共镜像必须提前同步到私有仓库。**
