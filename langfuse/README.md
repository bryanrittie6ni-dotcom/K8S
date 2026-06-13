# Langfuse 部署文档

> 部署日期：2026-06-13 | 集群：K3s v1.31.5 | 命名空间：`llmops`

## 访问入口

```
https://www.ailiwen.com.cn/langfuse
```

Nginx 反向代理路由：`/langfuse` → `langfuse-web.llmops.svc.cluster.local:3000`

## 文件索引

| 文档 | 内容 |
|------|------|
| [infrastructure.md](infrastructure.md) | 前置依赖：PostgreSQL、ClickHouse、Redis、MinIO |
| [credentials.md](credentials.md) | 所有账号、密码、连接串 |
| [persistence.md](persistence.md) | PVC 持久化映射关系 |
| [images.md](images.md) | 镜像清单与私有仓库配置 |
| [pitfalls.md](pitfalls.md) | 部署坑点与解决方案 |
| [cross-node.md](cross-node.md) | 跨节点网络问题分析 |
| [architecture.md](architecture.md) | 整体架构与服务依赖图 |
