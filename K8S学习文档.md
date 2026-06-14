# Kubernetes 学习文档 —— 基于 LLMOps 平台实战

> 以本仓库的 LLMOps 平台（Langfuse + Nginx + 前端 UI）为案例，系统讲解 Kubernetes 核心概念、资源配置与部署实践。
>
> 集群环境：K3s v1.31.5 | 命名空间：`llmops` | 节点：Ubuntu 22.04

---

## 目录

1. [Kubernetes 是什么](#1-kubernetes-是什么)
2. [核心概念速览](#2-核心概念速览)
3. [集群架构全景](#3-集群架构全景)
4. [资源类型详解（逐文件分析）](#4-资源类型详解逐文件分析)
   - [4.1 Namespace — 命名空间](#41-namespace--命名空间)
   - [4.2 Pod 与 Deployment — 应用部署核心](#42-pod-与-deployment--应用部署核心)
   - [4.3 Service — 服务发现与负载均衡](#43-service--服务发现与负载均衡)
   - [4.4 ConfigMap — 配置管理](#44-configmap--配置管理)
   - [4.5 Secret — 敏感信息管理](#45-secret--敏感信息管理)
   - [4.6 PersistentVolumeClaim — 持久化存储](#46-persistentvolumeclaim--持久化存储)
   - [4.7 Job — 一次性任务](#47-job--一次性任务)
   - [4.8 健康检查（Probes）](#48-健康检查probes)
   - [4.9 资源限制与调度策略](#49-资源限制与调度策略)
5. [项目架构深度解析](#5-项目架构深度解析)
6. [部署流程](#6-部署流程)
7. [实战排障手册](#7-实战排障手册)
8. [最佳实践总结](#8-最佳实践总结)

---

## 1. Kubernetes 是什么

Kubernetes（简称 K8S）是一个**容器编排平台**，负责：

| 能力 | 说明 | 本项目体现 |
|------|------|-----------|
| **自动部署** | 声明式描述期望状态，控制器驱动实际状态向期望状态收敛 | 所有 YAML 文件都是期望状态的声明 |
| **服务发现** | Pod 之间通过 DNS 名称互相访问 | `langfuse-web` 通过 `postgres:5432` 访问数据库 |
| **负载均衡** | Service 将流量分发到多个 Pod 副本 | Nginx LoadBalancer → 后端 ClusterIP |
| **自愈** | Pod 挂了自动重建，节点挂了自动迁移 | livenessProbe 检测 + 自动重启 |
| **滚动更新** | 不中断服务的版本升级 | `kubectl rollout restart` |
| **配置管理** | 配置与镜像解耦，改配置不需要重新构建镜像 | ConfigMap 存 Nginx 配置 |

### 声明式 vs 命令式

```bash
# 命令式（告诉 K8S "做什么"）
kubectl run nginx --image=nginx:latest

# 声明式（告诉 K8S "期望状态是什么"）— 本项目采用
kubectl apply -f nginx-deployment.yaml
```

声明式的优势：YAML 文件可以进 Git 版本管理、Code Review、回滚，且幂等（多次 apply 结果一致）。

---

## 2. 核心概念速览

在深入配置文件之前，先理解 K8S 资源之间的层级关系：

```
┌────────────────────────────────────────────────────────────────┐
│ Cluster                                                        │
│  ├── Namespace "llmops"  ──────────────────────────────────┐   │
│  │   ├── Deployment "postgres"                              │   │
│  │   │   └── ReplicaSet                                     │   │
│  │   │       └── Pod (postgres-xxxxx)                       │   │
│  │   │           ├── Container: postgres (image: postgres:17)│   │
│  │   │           └── Volume: postgres-data (PVC)            │   │
│  │   │                                                      │   │
│  │   ├── Service "postgres" (ClusterIP: 10.43.x.x:5432)     │   │
│  │   │   └── Endpoints → Pod IP:5432                        │   │
│  │   │                                                      │   │
│  │   ├── ConfigMap "nginx-config"                           │   │
│  │   ├── Secret "langfuse-secrets"                          │   │
│  │   └── ...                                                │   │
│  └──────────────────────────────────────────────────────────┘   │
└────────────────────────────────────────────────────────────────┘
```

### 关键关系表

| 资源 | 作用 | 类比 |
|------|------|------|
| **Node** | 物理机/虚拟机，跑容器的机器 | 服务器 |
| **Namespace** | 资源逻辑隔离 | 项目/环境分组 |
| **Pod** | K8S 最小调度单元，包含 1+ 容器 | 一组紧密耦合的进程 |
| **Deployment** | 管理 Pod 的副本数、更新策略 | 应用版本管理器 |
| **Service** | 给 Pod 提供固定 DNS + IP | 内置负载均衡器 |
| **ConfigMap** | 非敏感配置键值对 | 配置文件 |
| **Secret** | 密码、密钥等敏感数据 | 加密配置文件 |
| **PVC** | 持久化存储申请 | 申请一块硬盘 |
| **Job** | 一次性任务，跑完就结束 | 脚本 |

---

## 3. 集群架构全景

### 3.1 本项目的完整服务拓扑

```
Internet
    │ HTTPS (443)
    ▼
┌─────────────────────────────────────────────────────────┐
│ nginx (LoadBalancer Service)                             │
│ External IP: 由腾讯云 CLB 分配                            │
│                                                          │
│ ┌── nginx Pod ────────────────────────────────────────┐ │
│ │ TLS 终结 (www.ailiwen.com.cn)                        │ │
│ │                                                      │ │
│ │ /          → llmops-ui:3000        (前端 SPA)       │ │
│ │ /api/*     → llmops-api:5001       (后端 API)       │ │
│ │ /langfuse  → langfuse-web:3000     (LLM 可观测平台)  │ │
│ └──────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘
                         │
    ┌────────────────────┼────────────────────────────┐
    │          llmops Namespace (内部)                  │
    │                                                   │
    │  ┌──────────────┐  ┌────────────────┐           │
    │  │ langfuse-web │  │ langfuse-worker │           │
    │  │  (Next.js)   │  │   (BullMQ)      │           │
    │  └──────┬───────┘  └───────┬────────┘           │
    │         │                  │                      │
    │         └──────┬───────────┘                      │
    │                │                                   │
    │  ┌─────────────┼──────────────────────────────┐  │
    │  │   依赖服务 (均为 ClusterIP)                 │  │
    │  │                                             │  │
    │  │  postgres:5432    (主数据库, 10Gi PVC)      │  │
    │  │  clickhouse:8123  (分析数据库, 20Gi PVC)    │  │
    │  │  redis:6379       (队列+缓存, AOF 持久化)   │  │
    │  │  minio:9000       (S3 对象存储, 10Gi PVC)   │  │
    │  └─────────────────────────────────────────────┘  │
    └────────────────────────────────────────────────────┘
```

### 3.2 项目资源完整清单

| 资源类型 | 数量 | 列表 |
|----------|------|------|
| Namespace | 1 | `llmops` |
| Deployment | 8 | postgres, clickhouse, redis, minio, langfuse-web, langfuse-worker, nginx, llmops-ui |
| Service | 9 | nginx (LoadBalancer), 其余 8 个 (ClusterIP) |
| ConfigMap | 2 | `langfuse-config`, `nginx-config` |
| Secret | 3 | `langfuse-secrets`, `ccr-registry`, `nginx-tls` |
| PVC | 3 | postgres-data (10Gi), clickhouse-data (20Gi), minio-data (10Gi) |
| Job | 1 | `minio-create-bucket` |

---

## 4. 资源类型详解（逐文件分析）

### 4.1 Namespace — 命名空间

**文件：** `k8s/namespace.yaml`

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: llmops
```

#### 概念解释

Namespace 是 K8S 中最简单的资源，用于**逻辑隔离**。不同 Namespace 中的资源互相不可见（除非通过完整 DNS 名称跨命名空间访问）。

#### 关键知识点

- **默认命名空间**：如果不指定 namespace，资源默认创建在 `default`
- **DNS 作用域**：Service 的 DNS 名称是 `<service>.<namespace>.svc.cluster.local`
- **删除影响**：删除 namespace 会级联删除其中所有资源

#### 跨命名空间通信

本项目所有资源都在 `llmops` 命名空间内，但如果你有另一个项目需要共享这些基础设施（比如共享 postgres），可以通过跨命名空间 DNS 访问：

```
postgres.llmops.svc.cluster.local:5432
```

参见 `langfuse/shared-infra.yaml` 中记录的连接信息。

---

### 4.2 Pod 与 Deployment — 应用部署核心

**文件：** `k8s/postgres.yaml`、`k8s/langfuse-web.yaml` 等

#### Pod 是什么？

Pod 是 K8S 的**最小调度单元**，包含一个或多个容器。同一 Pod 内的容器共享网络命名空间（同一个 IP）和存储卷。

```
┌── Pod ──────────────────────────┐
│  IP: 10.42.0.xx                 │
│                                  │
│  ┌── Container: postgres ──────┐│
│  │  image: postgres:17         ││
│  │  port: 5432                 ││
│  │  env: POSTGRES_USER=...     ││
│  └─────────────────────────────┘│
│                                  │
│  ┌── Volume ───────────────────┐│
│  │  /var/lib/postgresql/data   ││
│  │  → PVC: postgres-data       ││
│  └─────────────────────────────┘│
└──────────────────────────────────┘
```

#### Deployment 是什么？

Deployment 是比 Pod 更高层的抽象，管理 Pod 的：
- **副本数**（replicas）：保持指定数量的 Pod 运行
- **更新策略**（滚动更新/重建）
- **版本回滚**

**不建议直接创建 Pod**，而是创建 Deployment 让它管理 Pod。

#### Deployment 配置逐段解析

以 `postgres` 为例：

```yaml
apiVersion: apps/v1          # API 版本
kind: Deployment             # 资源类型
metadata:
  name: postgres             # Deployment 名称
  namespace: llmops          # 所属命名空间
  labels:
    app: postgres            # 标签（用于筛选）
spec:                        # ===== 期望状态 =====
  replicas: 1                # 保持 1 个 Pod 副本
  selector:                  # 选择器：哪些 Pod 归我管
    matchLabels:
      app: postgres          # 必须匹配 Pod 的 label
  template:                  # ===== Pod 模板 =====
    metadata:
      labels:
        app: postgres        # Pod 的标签，必须匹配 selector
    spec:                    # Pod 内部规格
      nodeSelector:          # 调度策略：指定节点
        kubernetes.io/hostname: vm-0-10-ubuntu
      imagePullSecrets:      # 拉取私有镜像的凭据
        - name: ccr-registry
      containers:            # 容器列表
        - name: postgres
          image: ccr.ccs.tencentyun.com/my-app-20/postgres:17
          ports:
            - containerPort: 5432
              name: postgres
          env:                # 环境变量
            - name: POSTGRES_USER
              value: "postgres"
            - name: POSTGRES_PASSWORD
              value: "postgres5432"
          resources:          # 资源限制（详见 4.9）
            requests:
              cpu: "250m"
              memory: "256Mi"
            limits:
              cpu: "1"
              memory: "1Gi"
          volumeMounts:       # 卷挂载
            - name: data
              mountPath: /var/lib/postgresql/data
          livenessProbe:      # 存活探针（详见 4.8）
            exec:
              command: ["pg_isready", "-U", "postgres"]
            initialDelaySeconds: 10
            periodSeconds: 10
          readinessProbe:     # 就绪探针（详见 4.8）
            exec:
              command: ["pg_isready", "-U", "postgres"]
            initialDelaySeconds: 5
            periodSeconds: 5
      volumes:                # 卷定义
        - name: data
          persistentVolumeClaim:
            claimName: postgres-data
```

#### selector 与 labels 的匹配机制

这是 K8S 最核心的**松耦合**设计：

```
Deployment                          Pod
┌──────────────────┐               ┌──────────────────┐
│ selector:        │    通过       │ labels:          │
│   matchLabels:   │   label 匹配  │   app: postgres  │
│     app: postgres│◄─────────────►│                  │
└──────────────────┘               └──────────────────┘
```

Service 找 Pod 也是同样的机制 — 通过 label selector。

#### imagePullPolicy 策略

| 值 | 行为 | 适用场景 |
|-----|------|----------|
| `Always` | 每次创建 Pod 都拉取 | `latest` 标签，开发环境 |
| `IfNotPresent` | 本地有就用，没有才拉 | 版本标签，生产环境 |
| `Never` | 只用本地镜像 | 离线环境 |

本项目 `llmops-ui` 使用 `imagePullPolicy: Always`，因为使用 `latest` 标签需要确保拉取到最新镜像。

---

### 4.3 Service — 服务发现与负载均衡

**文件：** `k8s/nginx-service.yaml`、`k8s/postgres.yaml`（Service 部分）等

#### 为什么需要 Service？

Pod 的 IP 是**临时的** — Pod 重建后 IP 会变。Service 提供一个**固定的 DNS 名称和 Cluster IP**，无论后端 Pod 如何变化。

```
客户端                     Service                    Pod
┌──────┐     postgres     ┌──────────┐    label      ┌──────────┐
│ App  │ ───────────────► │ ClusterIP│   selector    │ postgres │
│      │   DNS 解析为     │10.43.x.x │──────────────►│10.42.0.x │
│      │   固定 ClusterIP │  :5432   │               │  :5432   │
└──────┘                  └──────────┘               └──────────┘
                           Endpoints
                           自动维护 Pod IP 列表
```

#### Service 类型对比

| 类型 | 访问范围 | 本项目使用 |
|------|----------|-----------|
| **ClusterIP** | 仅集群内部 | postgres, redis, clickhouse, minio, langfuse-web, langfuse-worker, llmops-ui, llmops-api |
| **NodePort** | 集群外通过 `<NodeIP>:<Port>` | 未使用 |
| **LoadBalancer** | 云厂商分配公网 IP | nginx |

#### ClusterIP Service 配置解析

```yaml
apiVersion: v1
kind: Service
metadata:
  name: postgres               # DNS 名称 = postgres
  namespace: llmops
  labels:
    app: postgres
spec:
  type: ClusterIP              # 仅集群内可访问
  ports:
    - port: 5432               # Service 对外暴露的端口
      targetPort: 5432         # Pod 容器的端口
      name: postgres
  selector:                    # 流量转发到具有此 label 的 Pod
    app: postgres
```

**port vs targetPort 的区别：**

```
请求 → Service (port: 5432) → Pod (targetPort: 5432)
                ↑ 可以不同              ↑ 容器实际监听的端口
```

#### LoadBalancer Service

```yaml
apiVersion: v1
kind: Service
metadata:
  name: nginx
  namespace: llmops
spec:
  type: LoadBalancer           # 云厂商分配公网 IP
  selector:
    app: nginx
  ports:
    - name: http
      port: 80
      targetPort: 80
    - name: https
      port: 443
      targetPort: 443
```

腾讯云会自动创建 CLB（Cloud Load Balancer），分配公网 IP 并将流量转发到 nginx Pod。

#### K8S DNS 服务发现

K8S 内置 CoreDNS，每个 Service 自动获得 DNS 记录：

```
# 同命名空间内访问 — 直接用 Service 名
postgres:5432

# 跨命名空间访问 — 使用 FQDN
postgres.llmops.svc.cluster.local:5432

# DNS 格式
<service-name>.<namespace>.svc.cluster.local
```

---

### 4.4 ConfigMap — 配置管理

**文件：** `k8s/langfuse-configmap.yaml`、`k8s/nginx-configmap.yaml`

#### 核心理念

> **配置与镜像解耦** — 改配置不需要重建 Docker 镜像，改完 ConfigMap 后重启 Pod 即可。

#### 两种使用方式

**方式 A：作为环境变量注入**

```yaml
# langfuse-configmap.yaml — 键值对形式的配置
apiVersion: v1
kind: ConfigMap
metadata:
  name: langfuse-config
  namespace: llmops
data:
  NEXTAUTH_URL: "https://www.ailiwen.com.cn/langfuse"
  CLICKHOUSE_URL: "http://clickhouse:8123"
  REDIS_HOST: "redis"
  REDIS_PORT: "6379"
  LANGFUSE_LOG_LEVEL: "info"
```

在 Deployment 中引用：

```yaml
containers:
  - name: langfuse-web
    envFrom:
      - configMapRef:
          name: langfuse-config    # 注入 ConfigMap 中所有 key 作为环境变量
```

**方式 B：作为文件挂载**

```yaml
# nginx-configmap.yaml — 整个配置文件的内容
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-config
  namespace: llmops
data:
  nginx.conf: |
    user nginx;
    worker_processes auto;
    ...
  proxy.conf: |
    proxy_set_header Host $host;
    ...
  default.conf: |
    server {
        listen 80;
        ...
    }
```

在 Deployment 中以 subPath 方式挂载单个文件：

```yaml
volumeMounts:
  - name: nginx-config
    mountPath: /etc/nginx/nginx.conf
    subPath: nginx.conf        # 只挂载 ConfigMap 中的一个 key
  - name: nginx-config
    mountPath: /etc/nginx/conf.d/default.conf
    subPath: default.conf
```

#### subPath 挂载的重要注意事项

| 挂载方式 | ConfigMap 更新后 | 说明 |
|----------|-----------------|------|
| **目录挂载**（无 subPath） | 自动同步（有延迟） | 会覆盖整个目录 |
| **subPath 挂载** | **不会自动更新** | 只替换单个文件，需重启 Pod |

本项目的 `deploy-nginx.sh` 通过比较 ConfigMap 的 `resourceVersion` 来检测变化，变化后自动执行 `rollout restart`。

#### ConfigMap vs 镜像内置配置

```
❌ 旧方式：配置写死在镜像里
   修改路由 → 改配置 → docker build → docker push → kubectl apply

✅ ConfigMap 方式：
   修改路由 → 改 ConfigMap → kubectl apply → rollout restart
   （秒级生效，不需要构建和推送镜像）
```

---

### 4.5 Secret — 敏感信息管理

**文件：** `k8s/langfuse-secret.yaml`

#### Secret vs ConfigMap

| 特性 | ConfigMap | Secret |
|------|-----------|--------|
| 存储内容 | 非敏感配置 | 密码、密钥、Token |
| 编码 | 明文 | Base64 编码（非加密！） |
| 内存 | 存储在 API Server | 仅分发到需要节点 |
| 大小限制 | 1MB | 1MB |

> ⚠️ **重要：** Secret 只是 Base64 编码，不是加密。K8S 的 Secret 安全依赖于 RBAC 权限控制和 etcd 加密。生产环境建议配合 Vault 等外部密钥管理。

#### Opaque Secret 配置解析

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: langfuse-secrets
  namespace: llmops
type: Opaque                     # 通用类型
stringData:                      # 明文写入（K8S 自动 Base64 编码）
  NEXTAUTH_SECRET: "f0f89a225ddbf7e8fdde9e2f..."
  SALT: "015e2d1be3caae6018d5130e..."
  DATABASE_URL: "postgresql://postgres:postgres5432@postgres:5432/postgres"
  REDIS_AUTH: "myredissecret"
```

两种数据字段的区别：

| 字段 | 写入方式 | 查看时 |
|------|----------|--------|
| `stringData` | 明文直接写 | 不返回（只写） |
| `data` | Base64 编码后写 | 返回 Base64 |

#### 使用方式

```yaml
# 方式 1：全部注入为环境变量
containers:
  - name: langfuse-web
    envFrom:
      - secretRef:
          name: langfuse-secrets

# 方式 2：注入单个 key
env:
  - name: DB_PASSWORD
    valueFrom:
      secretKeyRef:
        name: langfuse-secrets
        key: DATABASE_URL

# 方式 3：挂载为文件
volumes:
  - name: tls
    secret:
      secretName: nginx-tls
```

#### TLS Secret

```bash
kubectl create secret tls nginx-tls \
  --cert=www.ailiwen.com.cn.pem \
  --key=www.ailiwen.com.cn.key \
  -n llmops
```

TLS Secret 自动生成固定文件名：
- `tls.crt` — 证书
- `tls.key` — 私钥

Nginx 配置中引用：
```nginx
ssl_certificate     /etc/ssl/tls.crt;
ssl_certificate_key /etc/ssl/tls.key;
```

#### imagePullSecret

拉取私有镜像仓库需要 Docker 凭据：

```bash
kubectl create secret docker-registry ccr-registry \
  --docker-server=ccr.ccs.tencentyun.com \
  --docker-username=100028762684 \
  --docker-password=<CCR_PASSWORD> \
  -n llmops
```

Deployment 中引用：
```yaml
spec:
  imagePullSecrets:
    - name: ccr-registry
```

---

### 4.6 PersistentVolumeClaim — 持久化存储

**文件：** `k8s/postgres.yaml`（PVC 部分）、`k8s/clickhouse.yaml`、`k8s/minio.yaml`

#### 为什么需要 PVC？

容器是无状态的 — 重启后所有文件丢失。PVC 提供**与 Pod 生命周期解耦的持久存储**。

```
┌── Pod ───────────────┐        ┌── PVC ──────────────┐       ┌── PV ────────────────┐
│ volumeMounts:        │  绑定  │ accessModes: RWO     │ 供给  │ /var/lib/rancher/     │
│   /var/lib/postgres  │◄──────►│ storage: 10Gi         │◄─────►│   k3s/storage/         │
│                      │        │ storageClass: local   │       │   pvc-xxxxx/           │
└──────────────────────┘        └───────────────────────┘       └───────────────────────┘
```

#### PVC 配置解析

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-data
  namespace: llmops
spec:
  accessModes:
    - ReadWriteOnce           # 单节点读写（一个 Pod 挂载）
  resources:
    requests:
      storage: 10Gi           # 申请 10GB 空间
  storageClassName: local-path # 使用 K3s 内置的 local-path provisioner
```

#### AccessMode 三种模式

| 模式 | 缩写 | 含义 | 适用场景 |
|------|------|------|----------|
| ReadWriteOnce | RWO | 单节点读写 | 数据库（postgres, clickhouse） |
| ReadOnlyMany | ROX | 多节点只读 | 共享静态资源 |
| ReadWriteMany | RWX | 多节点读写 | 需要分布式文件系统 |

#### StorageClass 与动态供给

本项目使用 K3s 内置的 `local-path` provisioner：

```
特性：
- Provisioner: rancher.io/local-path
- Reclaim Policy: Delete（删除 PVC 时自动删除数据！）
- Volume Binding Mode: WaitForFirstConsumer（Pod 调度后才创建存储）
- 实际路径: /var/lib/rancher/k3s/storage/pvc-<uuid>_llmops_<pvc-name>/
```

#### 本项目的 PVC 清单

| PVC | 容量 | 挂载路径 | 所属 Pod | 数据重要性 |
|-----|------|----------|----------|-----------|
| `postgres-data` | 10Gi | `/var/lib/postgresql/data` | postgres | **核心业务数据** |
| `clickhouse-data` | 20Gi | `/var/lib/clickhouse` | clickhouse | 分析事件数据 |
| `minio-data` | 10Gi | `/data` | minio | S3 对象存储 |

> Redis **不使用 PVC** — 数据量小，通过 AOF（Append Only File）在容器内持久化，重启后自动恢复。

#### 数据安全注意事项

| 操作 | 后果 |
|------|------|
| `kubectl delete pvc` | **数据永久丢失**（Reclaim Policy: Delete） |
| `kubectl delete deployment` | 数据保留（PVC 不受影响），重新部署后自动挂载 |
| 升级 PostgreSQL 大版本 | PVC 数据可能不兼容，需 `pg_dump` → 升级 → `pg_restore` |
| 节点故障 | `local-path` 无复制，数据随节点丢失 |

---

### 4.7 Job — 一次性任务

**文件：** `k8s/minio.yaml`（Job 部分）

#### Job vs Deployment

| 特性 | Deployment | Job |
|------|------------|-----|
| 运行方式 | 持续运行 | 完成后终止 |
| 重启策略 | Always | Never / OnFailure |
| 完成条件 | 无（一直跑） | Pod 成功退出（exit 0） |
| 典型场景 | Web 服务、数据库 | 数据迁移、初始化 |

#### MinIO Bucket 创建 Job

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: minio-create-bucket
  namespace: llmops
spec:
  ttlSecondsAfterFinished: 60    # 完成后 60 秒自动删除
  template:
    spec:
      restartPolicy: OnFailure    # 失败时重试
      containers:
        - name: create-bucket
          image: ccr.ccs.tencentyun.com/my-app-20/minio-mc:latest
          command:
            - /bin/sh
            - -c
            - |
              mc alias set local http://minio:9000 minio miniosecret
              mc mb --ignore-existing local/langfuse
              echo "Bucket 'langfuse' ready"
```

**设计要点：** 为什么用 Job 而不是 initContainer？

- initContainer 必须和主容器在同一个 Pod 内，且先于主容器启动
- MinIO 的 initContainer 无法在 MinIO **之前**运行 — 鸡生蛋问题
- 用独立的 Job 可以在 MinIO Service 就绪后异步创建 Bucket

---

### 4.8 健康检查（Probes）

K8S 提供三种探针，每种有不同的目的和时机：

```
Pod 启动 → startupProbe   → livenessProbe (持续监控)
         → readinessProbe → 加入 Service Endpoints
```

#### 三种探针对比

| 探针 | 目的 | 失败后果 | 典型场景 |
|------|------|----------|----------|
| **startupProbe** | 判断是否启动完成 | 重启容器 | 启动慢的应用（如 Langfuse 需等数据库迁移） |
| **livenessProbe** | 判断是否还活着 | 重启容器 | 应用死锁、内存泄漏导致无响应 |
| **readinessProbe** | 判断是否可以接流量 | 从 Service 摘除 | 应用在加载缓存、数据库暂时不可达 |

#### 探针检测方式

```yaml
# 方式 1：HTTP GET（最常用）
livenessProbe:
  httpGet:
    path: /api/public/health
    port: 3000
  initialDelaySeconds: 10
  periodSeconds: 10

# 方式 2：执行命令
livenessProbe:
  exec:
    command: ["pg_isready", "-U", "postgres"]
  initialDelaySeconds: 10
  periodSeconds: 10

# 方式 3：TCP Socket
livenessProbe:
  tcpSocket:
    port: 443
  initialDelaySeconds: 15
  periodSeconds: 30
```

#### 本项目探针配置汇总

| 服务 | startupProbe | livenessProbe | readinessProbe |
|------|-------------|---------------|----------------|
| postgres | - | `pg_isready` | `pg_isready` |
| clickhouse | - | HTTP `/ping` | HTTP `/ping` |
| redis | - | `redis-cli ping` | `redis-cli ping` |
| minio | - | HTTP `/minio/health/live` | HTTP `/minio/health/ready` |
| langfuse-web | HTTP `/api/public/health` (failureThreshold: 30) | HTTP `/api/public/health` | HTTP `/api/public/health` |
| langfuse-worker | HTTP `/api/health` (failureThreshold: 30) | HTTP `/api/health` | HTTP `/api/health` |
| nginx | - | TCP 443 | TCP 443 |
| llmops-ui | - | HTTP `/` | HTTP `/` |

#### 参数说明

```yaml
initialDelaySeconds: 10   # 容器启动后等多久才开始检测
periodSeconds: 10         # 检测间隔
timeoutSeconds: 5         # 单次检测超时
failureThreshold: 3       # 连续失败多少次才判定为失败
successThreshold: 1       # 连续成功多少次才判定为成功
```

**时间线示例（livenessProbe）：**

```
Pod 启动
    │
    + 10s (initialDelaySeconds)
    │
    ├── 检测 ① → 失败
    │   + 10s (periodSeconds)
    ├── 检测 ② → 失败
    │   + 10s
    ├── 检测 ③ → 失败  ← failureThreshold=3, 触发重启
    │
    └── 容器被 kill，重新创建
```

#### langfuse-web 的 startupProbe 特殊配置

```yaml
startupProbe:
  httpGet:
    path: /api/public/health
    port: 3000
  initialDelaySeconds: 10
  periodSeconds: 5
  failureThreshold: 30    # 允许 30 次失败 = 最多等 10 + 30×5 = 160 秒
```

Langfuse 启动时需要运行数据库迁移，可能耗时较长（特别是首次部署）。`failureThreshold: 30` 给它充足的时间完成启动，避免被 livenessProbe 过早杀掉。

---

### 4.9 资源限制与调度策略

#### 资源请求（requests）vs 资源限制（limits）

```yaml
resources:
  requests:        # 调度保证：Pod 至少能拿到这么多
    cpu: "250m"
    memory: "256Mi"
  limits:          # 运行时上限：超过了就限制/杀掉
    cpu: "1"
    memory: "1Gi"
```

| 参数 | requests | limits |
|------|----------|--------|
| **对调度的影响** | 节点剩余资源必须 ≥ requests 才调度 | 不影响调度 |
| **对运行时的影响** | 保证至少分配这么多 | CPU 超过就限流，内存超过就 OOM Kill |
| **设置原则** | 设为正常运行的 50-70% | 设为峰值的 120%，留 buffer |

#### CPU 单位

```
1000m = 1 CPU 核
250m  = 0.25 核
100m  = 0.1 核
```

#### 节点亲和性 — 为什么本项目全部调度到同一节点？

```yaml
nodeSelector:
  kubernetes.io/hostname: vm-0-10-ubuntu
```

**原因：** 本项目使用 K3s + Flannel 的 `host-gw`（Host Gateway）模式，要求所有节点在同一 L2 网络。但两个节点：
- `vm-0-10-ubuntu` — 公网 IP（云服务商 VPC）
- `lsltidysqg` — 内网 IP（本地局域网）

两者不在同一二层网络，跨节点 Pod 无法通信。因此所有 Pod 强制调度到 control-plane 节点。

**不同节点的 nodeSelector：**

```yaml
# 基础设施 Pod → 调度到 control-plane 节点
nodeSelector:
  kubernetes.io/hostname: vm-0-10-ubuntu

# Nginx / UI → 调度到 control-plane 角色节点
nodeSelector:
  node-role.kubernetes.io/control-plane: "true"
```

#### 替代方案

如果未来需要多节点部署，可以：
- 切换到 Flannel `vxlan` 模式（隧道封装，有性能开销）
- 使用 Calico 等支持跨网段的 CNI 插件
- 将所有节点放入同一云 VPC

---

## 5. 项目架构深度解析

### 5.1 Nginx 反向代理设计

这是整个项目最精妙的部分，体现了 K8S 环境下的设计智慧。

#### 问题：为什么用变量 proxy_pass 而不是静态 upstream？

```nginx
# ❌ 静态方式 — Pod 重建后 IP 变化导致 Connection Refused
upstream llmops_ui {
    server llmops-ui:3000;
}
location / {
    proxy_pass http://llmops_ui;
}

# ✅ 动态方式 — 每次请求通过 DNS 重新解析
location / {
    resolver 10.43.0.10 valid=30s ipv6=off;
    set $ui_host llmops-ui.llmops.svc.cluster.local;
    proxy_pass http://$ui_host:3000;
}
```

**原理：** Nginx 对静态 `proxy_pass` 中的域名只在**启动时**解析一次。K8S 的 Pod IP 在重建后会变，但 Nginx 还缓存着旧 IP，导致请求失败。使用变量 + `resolver` 让 Nginx 根据 DNS TTL 动态重新解析。

#### 路由设计

```
用户请求
    │
    ▼
┌── nginx (TLS 终结) ─────────────────────────────────┐
│                                                       │
│  :80  → 301 重定向到 :443                              │
│                                                       │
│  :443 (www.ailiwen.com.cn)                            │
│  ├── /            → llmops-ui:3000       (前端 SPA)   │
│  ├── /api/*       → llmops-api:5001      (后端 API)   │
│  │     └── rewrite ^/api/(.*)$ /$1 break  # 剥离前缀  │
│  └── /langfuse    → langfuse-web:3000    (可观测平台)  │
│        └── 不 rewrite — Langfuse 自己处理 basePath     │
└───────────────────────────────────────────────────────┘
```

#### proxy.conf 通用配置

```nginx
proxy_set_header Host $host;                    # 传递原始域名
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;  # 传递真实客户端 IP
proxy_set_header X-Forwarded-Proto $scheme;     # 传递原始协议 (https)
proxy_http_version 1.1;                          # HTTP/1.1 支持 keep-alive
proxy_set_header Upgrade $http_upgrade;          # WebSocket 支持
proxy_set_header Connection $connection_upgrade;
proxy_read_timeout 600s;                         # LLM 调用可能很长
```

### 5.2 配置分离策略

```
┌──────────────────────────────────────────────┐
│ Secret: langfuse-secrets                     │
│ 密码、密钥、连接串                            │
│ → 不进入 Git（实际项目中应加密或外部管理）      │
├──────────────────────────────────────────────┤
│ ConfigMap: langfuse-config                   │
│ URL、开关、日志级别                           │
│ → 可以进 Git，团队可见                        │
├──────────────────────────────────────────────┤
│ ConfigMap: nginx-config                      │
│ Nginx 路由、超时、TLS 参数                    │
│ → 可以进 Git，改配置不需要 rebuild 镜像       │
└──────────────────────────────────────────────┘
```

### 5.3 环境变量流转

```
┌── Secret: langfuse-secrets ──────┐  ┌── ConfigMap: langfuse-config ──┐
│ DATABASE_URL                     │  │ NEXTAUTH_URL                   │
│ CLICKHOUSE_PASSWORD              │  │ CLICKHOUSE_URL                 │
│ REDIS_AUTH                       │  │ REDIS_HOST / PORT              │
│ LANGFUSE_S3_*_ACCESS_KEY_ID      │  │ LANGFUSE_S3_*_BUCKET/ENDPOINT  │
│ LANGFUSE_S3_*_SECRET_ACCESS_KEY  │  │ LANGFUSE_LOG_LEVEL/FORMAT      │
│ NEXTAUTH_SECRET, SALT, ENCRYPTION│  └──────────┬────────────────────┘
└──────────────┬───────────────────┘             │
               │ envFrom.secretRef               │ envFrom.configMapRef
               ▼                                 ▼
         ┌──────────────────────────────────────────┐
         │  langfuse-web / langfuse-worker 容器      │
         │  + HOSTNAME, NODE_ENV, PORT (直接 env)    │
         └──────────────────────────────────────────┘
```

### 5.4 依赖服务部署顺序

```
部署顺序很重要 — 被依赖的服务必须先就绪：

1. Namespace + Secret + ConfigMap     ← 基础
2. PostgreSQL                         ← 主数据库
3. ClickHouse                         ← 分析数据库
4. Redis                              ← 队列/缓存
5. MinIO + Bucket Job                 ← 对象存储
6. langfuse-web                       ← 前端 + API
7. langfuse-worker                    ← 后台任务
```

---

## 6. 部署流程

### 6.1 部署脚本体系

本项目有 2 个部署脚本，覆盖了完整的 CI/CD 流程：

| 脚本 | 功能 | 触发条件 |
|------|------|----------|
| `deploy-nginx.sh` | 部署 Nginx 反向代理（配置 + 可选镜像构建） | 改路由、超时、SSL 证书 |
| `deploy-ui.sh` | 构建前端镜像 → 推送 → 部署 | 修改前端代码 |

### 6.2 deploy-nginx.sh 工作流

```
┌─────────────────────────────────────────────────┐
│ deploy-nginx.sh 支持两种运行模式                  │
├─────────────────────────────────────────────────┤
│                                                   │
│  模式 A：仅更新配置（默认，最常用）                 │
│  ─────────────────────────────                    │
│  [1/7] 确保 namespace 存在                        │
│  [2/7] 创建/更新 imagePullSecret (CCR)            │
│  [3/7] 创建/更新 TLS Secret                      │
│  [4/7] 应用 ConfigMap                            │
│        → 比较 resourceVersion 判断是否有变化      │
│  [5/7] 应用后端 Service（确保 DNS 可解析）        │
│  [6/7] 应用 Deployment + Service                 │
│        → ConfigMap 有变化时自动 rollout restart    │
│  [7/7] 等待就绪 + 状态汇总 + 外部验证              │
│                                                   │
│  模式 B：构建镜像 + 更新配置（--build）            │
│  ─────────────────────────────────                │
│  额外执行 docker build + push，然后继续模式 A     │
│                                                   │
└─────────────────────────────────────────────────┘
```

**智能重启判断逻辑：**

```bash
# 比较 ConfigMap 的 resourceVersion
CONFIGMAP_BEFORE=$(kubectl get configmap nginx-config -n llmops \
  -o jsonpath='{.metadata.resourceVersion}')
kubectl apply -f nginx-configmap.yaml
CONFIGMAP_AFTER=$(kubectl get configmap nginx-config -n llmops \
  -o jsonpath='{.metadata.resourceVersion}')

# 只在 ConfigMap 真的变了才重启
if [ "$CONFIGMAP_BEFORE" != "$CONFIGMAP_AFTER" ]; then
  kubectl rollout restart deployment/nginx -n llmops
fi
```

### 6.3 deploy-ui.sh 工作流

```
[preflight] 检查 docker + kubectl + dist/ 目录 + CCR_PASSWORD
    │
[1/5] docker login ccr.ccs.tencentyun.com
    │
[2/5] docker build -t llmops-ui:latest ./llmops-ui
    │
[3/5] docker push
    │
[4/5] kubectl apply -f llmops-ui-deployment.yaml
      + latest 标签 → rollout restart（配合 Always 拉取策略）
    │
[5/5] kubectl rollout status --timeout=120s
    │
[汇总] Pod 状态 + Service + Endpoints
    │
[验证] Pod 内自检 + 外部 URL 验证
```

### 6.4 使用示例

```bash
# 首次部署 nginx
CCR_PASSWORD=xxx ./scripts/deploy-nginx.sh --build

# 仅更新 nginx 配置（最常用操作）
./scripts/deploy-nginx.sh

# 更新 SSL 证书后重新部署
./scripts/deploy-nginx.sh

# 部署前端
CCR_PASSWORD=xxx ./scripts/deploy-ui.sh

# 用版本标签部署前端（推荐生产环境）
TAG=v1.2.3 CCR_PASSWORD=xxx ./scripts/deploy-ui.sh
```

### 6.5 后续更新流程

```
修改了前端代码？
  → 构建 dist/ → ./scripts/deploy-ui.sh

修改了 nginx 路由/超时？
  → 编辑 k8s/nginx-configmap.yaml → ./scripts/deploy-nginx.sh

SSL 证书过期了？
  → 替换 nginx/ssl/*.pem + *.key → ./scripts/deploy-nginx.sh

新增了一个服务需要反向代理？
  → 在 nginx-configmap.yaml 添加 location 块 → ./scripts/deploy-nginx.sh

Nginx base image 需要安全更新？
  → ./scripts/deploy-nginx.sh --build
```

---

## 7. 实战排障手册

### 7.1 日常排障流程

```bash
# 第一步：查看 Pod 状态
kubectl get pods -n llmops

# 第二步：查看 Pod 详情（重点看 Events 和 Conditions）
kubectl describe pod <pod-name> -n llmops

# 第三步：查看日志
kubectl logs <pod-name> -n llmops

# 如果 Pod 反复重启，查看上一次的日志
kubectl logs <pod-name> -n llmops --previous

# 第四步：进入容器调试
kubectl exec -it <pod-name> -n llmops -- sh
```

### 7.2 常见问题速查表

| 现象 | 可能原因 | 排查命令 | 解决方案 |
|------|----------|----------|----------|
| `ErrImagePull` | 镜像不存在或拉取凭据错误 | `kubectl describe pod` 看 Events | 检查 imagePullSecrets，确认镜像已推送 |
| `CrashLoopBackOff` | 容器启动后立即退出 | `kubectl logs --previous` | 查看应用日志，检查配置是否正确 |
| `OOMKilled` | 内存超过 limits | `kubectl describe pod` 看 State | 提高 memory limits 或排查内存泄漏 |
| `Pending` | 资源不足或 PVC 未绑定 | `kubectl describe pod` 看 Events | 降低 requests 或扩容节点 |
| DNS 解析失败 | CoreDNS 不可达 | `kubectl exec -- nslookup postgres` | 检查 CoreDNS Pod 状态 |
| Service 不通 | Endpoints 为空（selector 不匹配） | `kubectl get endpoints` | 检查 Service selector 和 Pod labels |

### 7.3 nginx proxy_pass 静态 DNS 解析坑

**现象：** Nginx Pod 状态 `CrashLoopBackOff`，日志显示：
```
host not found in upstream "llmops-ui" in /etc/nginx/conf.d/default.conf:27
```

**根因：** Nginx 对静态 `proxy_pass http://upstream:port` 会在**启动时**解析 DNS。如果目标 Service 尚不存在，Nginx 直接退出。

**解决方案：** 使用变量 + resolver：
```nginx
# ❌ 启动时解析
proxy_pass http://llmops-ui:3000;

# ✅ 运行时解析
resolver kube-dns.kube-system.svc.cluster.local valid=30s;
set $ui_host llmops-ui.llmops.svc.cluster.local;
proxy_pass http://$ui_host:3000;
```

### 7.4 排障技巧：Shell 包装命令的 exit code 陷阱

```yaml
# ❌ 危险 — sh -c 返回最后一条命令的退出码
command: ["sh", "-c"]
args:
  - |
    nginx -t          # 可能失败
    nginx -g 'daemon off;'  # 可能失败
    sleep 5           # 这条成功了 → exitCode: 0
# 结果：看到 exitCode:0，以为 nginx 正常，实际早就崩了
```

**正确做法：** 使用 `set -e` 让 shell 在任何命令失败时立即退出：
```yaml
command: ["sh", "-c"]
args:
  - |
    set -e                    # 关键：任何命令失败立即退出
    nginx -t
    exec nginx -g 'daemon off;'
```

### 7.5 MinIO 权限问题

**现象：** MinIO 启动失败，日志：
```
FATAL: Unable to initialize backend: Unable to write to the backend
```

**根因：** Chainguard 构建的 MinIO 以非 root 用户（uid 65532）运行，但 PVC 挂载的目录 owner 是 root。

**解决方案：** 使用 initContainer + securityContext：
```yaml
securityContext:
  fsGroup: 65532
initContainers:
  - name: fix-permissions
    image: minio-mc:latest
    command: ["sh", "-c", "chown -R 65532:65532 /data && chmod -R u+rwx /data"]
    volumeMounts:
      - name: data
        mountPath: /data
```

### 7.6 镜像拉取问题（国内环境）

**现象：** `ImagePullBackOff` — Docker Hub 超时。

**根因：** Docker Hub 在国内无法直连。

**解决方案：** 所有镜像先 `docker pull` → `docker tag` → `docker push` 到腾讯云 CCR。

```bash
# 从 Docker Hub 同步到 CCR
docker pull postgres:17
docker tag postgres:17 ccr.ccs.tencentyun.com/my-app-20/postgres:17
docker push ccr.ccs.tencentyun.com/my-app-20/postgres:17
```

---

## 8. 最佳实践总结

### 8.1 配置管理

| 实践 | 说明 |
|------|------|
| **配置进 ConfigMap，不进镜像** | 改路由/超时不需要 rebuild |
| **密码进 Secret，不进 ConfigMap** | 敏感/非敏感分离 |
| **ConfigMap 用 subPath 挂载时记得重启** | subPath 不会自动热更新 |
| **ConfigMap 变了大不了 `rollout restart`** | 滚动更新零停机 |

### 8.2 镜像管理

| 实践 | 说明 |
|------|------|
| **生产环境用版本标签，不用 latest** | `v1.2.3` 可追溯、可回滚 |
| **国内环境提前同步镜像到私有仓库** | 避免 Docker Hub 不可达 |
| **imagePullPolicy: Always 配合 latest** | 确保拉取最新 |

### 8.3 健康检查

| 实践 | 说明 |
|------|------|
| **三探针都配（startup/liveness/readiness）** | 各有各的用途 |
| **liveness 比 readiness 更宽松** | 不要让 K8S 频繁杀 Pod |
| **启动慢的应用用 startupProbe** | 给足够的启动时间 |
| **数据库用 exec 探针，Web 用 httpGet** | 用最适合的检测方式 |

### 8.4 资源管理

| 实践 | 说明 |
|------|------|
| **requests 和 limits 都要设** | requests 影响调度，limits 防止资源耗尽 |
| **memory requests = limits** | 避免内存 OOM |
| **cpu requests 设小点，limits 设大点** | CPU 是可压缩资源，弹性利用 |

### 8.5 网络与 Service

| 实践 | 说明 |
|------|------|
| **内部服务用 ClusterIP** | 不暴露到公网 |
| **入口用 LoadBalancer + Nginx** | 统一 TLS 终结 + 路由 |
| **proxy_pass 用变量 + resolver** | 避免 DNS 缓存导致 Connection Refused |
| **跨节点通信用 vxlan/wireguard** | host-gw 要求同 L2 网段 |

### 8.6 持久化

| 实践 | 说明 |
|------|------|
| **有状态服务必须配 PVC** | 数据库、对象存储 |
| **local-path 适合单节点，生产用分布式存储** | Ceph、Longhorn 等 |
| **定期备份数据库** | `pg_dump` / `clickhouse-client --query "BACKUP..."` |
| **删除 Deployment 不会删 PVC** | 数据保留，安全 |

### 8.7 部署脚本

| 实践 | 说明 |
|------|------|
| **声明式管理（kubectl apply）** | YAML 文件进 Git |
| **幂等设计** | 多次执行结果一致 |
| **智能重启** | 配置变了才重启，不浪费 |
| **部署后验证** | 检查 Pod 状态 + 端点 + 外部可达性 |

---

## 附录

### A. 常用 kubectl 命令速查

```bash
# 资源查看
kubectl get pods -n llmops                    # Pod 列表
kubectl get pods -n llmops -o wide            # 含 IP 和节点
kubectl get svc -n llmops                     # Service 列表
kubectl get deployments -n llmops             # Deployment 列表
kubectl get pvc -n llmops                     # PVC 列表
kubectl get configmap -n llmops               # ConfigMap 列表
kubectl get secrets -n llmops                 # Secret 列表
kubectl get endpoints -n llmops               # Endpoints（Service → Pod 映射）
kubectl get events -n llmops --sort-by=.lastTimestamp  # 事件（排障必看）

# 详细信息
kubectl describe pod <name> -n llmops         # Pod 详情
kubectl logs <pod> -n llmops                  # 查看日志
kubectl logs <pod> -n llmops --previous       # 查看上一次容器日志
kubectl logs -f <pod> -n llmops               # 实时跟踪日志

# 进入容器
kubectl exec -it <pod> -n llmops -- sh        # 进入容器
kubectl exec <pod> -n llmops -- <command>     # 执行命令

# 部署操作
kubectl apply -f <file.yaml>                  # 应用配置
kubectl delete -f <file.yaml>                 # 删除资源
kubectl rollout restart deployment/<name> -n llmops  # 重启 Deployment
kubectl rollout status deployment/<name> -n llmops   # 查看更新状态
kubectl rollout undo deployment/<name> -n llmops     # 回滚
kubectl scale deployment/<name> --replicas=3 -n llmops  # 扩缩容

# 临时诊断 Pod
kubectl run test --image=busybox --rm -it --restart=Never -- sh
```

### B. 文件索引

| 文件/目录 | 内容 |
|-----------|------|
| `k8s/namespace.yaml` | Namespace 定义 |
| `k8s/backend-services.yaml` | UI 和 API 的 Service 占位 |
| `k8s/postgres.yaml` | PostgreSQL Deployment + Service + PVC |
| `k8s/clickhouse.yaml` | ClickHouse Deployment + Service + PVC |
| `k8s/redis.yaml` | Redis Deployment + Service |
| `k8s/minio.yaml` | MinIO Deployment + Service + PVC + Bucket Job |
| `k8s/langfuse-web.yaml` | Langfuse Web Deployment + Service |
| `k8s/langfuse-worker.yaml` | Langfuse Worker Deployment + Service |
| `k8s/langfuse-configmap.yaml` | Langfuse 非敏感配置 |
| `k8s/langfuse-secret.yaml` | Langfuse 敏感配置 |
| `k8s/nginx-configmap.yaml` | Nginx 完整配置 |
| `k8s/nginx-deployment.yaml` | Nginx Deployment |
| `k8s/nginx-service.yaml` | Nginx LoadBalancer Service |
| `k8s/llmops-ui-deployment.yaml` | 前端 UI Deployment |
| `scripts/deploy-nginx.sh` | Nginx 部署脚本 |
| `scripts/deploy-ui.sh` | 前端部署脚本 |
| `langfuse/` | Langfuse 相关参考文档 |
| `langfuse/shared-infra.yaml` | 跨项目共享基础设施连接信息 |

### C. 关键术语对照

| 英文 | 中文 | 说明 |
|------|------|------|
| Pod | Pod | 最小调度单元 |
| Deployment | 部署 | 管理 Pod 副本和版本 |
| Service | 服务 | 固定 DNS + 负载均衡 |
| ConfigMap | 配置映射 | 非敏感配置存储 |
| Secret | 密钥 | 敏感信息存储 |
| PVC | 持久卷声明 | 存储申请 |
| Namespace | 命名空间 | 资源逻辑隔离 |
| Label | 标签 | 用于筛选和关联 |
| Selector | 选择器 | 根据标签选择资源 |
| Probe | 探针 | 健康检查 |
| LoadBalancer | 负载均衡器 | 对外暴露服务 |
| ClusterIP | 集群 IP | 内部服务发现 |
| scheduler | 调度器 | 决定 Pod 在哪个节点运行 |
| kubelet | kubelet | 节点上的 K8S 代理 |
| CoreDNS | CoreDNS | 集群 DNS 服务 |

---

> 📅 文档生成日期：2026-06-14 | 基于本仓库 K8S 配置实战经验编写
