# /home/ubuntu/K8S — K8S 资源配置与部署脚本详解

## 项目概览

本项目是一个基于 **腾讯云 TKE** 的 LLMOps 平台部署方案，通过 Kubernetes 管理前端 UI、后端 API 和 Nginx 反向代理。整体架构链路如下：

```
用户浏览器 → LoadBalancer (nginx Service) → Nginx Pod (TLS 终结 + 反向代理)
                                              ├── /    → llmops-ui Pod (前端, :3000)
                                              └── /api/ → llmops-api Service (后端, :5001)
```

所有资源统一部署在 `llmops` 命名空间下，镜像存储在腾讯云 CCR（Container Registry）。

---

## 一、`k8s/` 目录 —— Kubernetes 资源配置文件

该目录存放所有 K8S 资源的声明式 YAML 文件，共计 **6 个文件**。

### 文件总览

| 文件 | 资源类型 | 用途 |
|------|----------|------|
| `namespace.yaml` | Namespace | 创建 `llmops` 命名空间 |
| `backend-services.yaml` | Service ×2 | 为前端 UI 和后端 API 创建 ClusterIP Service |
| `nginx-configmap.yaml` | ConfigMap | 存储 Nginx 完整运行时配置 |
| `nginx-deployment.yaml` | Deployment | 部署 Nginx 反向代理 Pod |
| `nginx-service.yaml` | Service | 暴露 Nginx 为 LoadBalancer 类型 |
| `llmops-ui-deployment.yaml` | Deployment | 部署前端 UI Pod |

---

### 1.1 `namespace.yaml` —— 命名空间

```yaml
kind: Namespace
metadata:
  name: llmops
```

最简单的资源定义，创建名为 `llmops` 的命名空间。项目中所有其他资源都部署在这个命名空间下，实现逻辑隔离。

---

### 1.2 `backend-services.yaml` —— 后端 Service 占位

定义了 **两个 ClusterIP 类型的 Service**：

| Service 名 | 端口 | 用途 |
|------------|------|------|
| `llmops-ui` | 3000 | 前端 UI Pod 的服务发现 |
| `llmops-api` | 5001 | 后端 API Pod 的服务发现 |

**关键设计说明：**
- 这两个 Service 初始作为 **占位服务** 存在，确保 Nginx 启动时 upstream DNS 可解析（否则 Nginx 会因 DNS 解析失败而 crash）。
- 后续部署真实 Pod 时，只要 Pod 的 `app` label 与 Service 的 `selector` 匹配，流量就会自动路由。
- 使用 `ClusterIP` 类型，仅集群内部可访问。

---

### 1.3 `nginx-configmap.yaml` —— Nginx 配置中心

存储 Nginx 运行时的三份配置文件的完整内容：

#### a) `nginx.conf` — 主配置
- `worker_processes auto`：自动匹配 CPU 核数
- `client_max_body_size 15M`：允许 15MB 的请求体（适配 LLM 相关大请求）
- 开启 gzip 压缩
- 定义 `$connection_upgrade` 变量映射（WebSocket 支持）
- 引入 `conf.d/*.conf` 子配置

#### b) `proxy.conf` — 反向代理通用配置
- 转发原始 Host、客户端 IP、协议头
- 支持 WebSocket 升级（`Upgrade` 和 `Connection` 头）
- 关闭代理缓冲（`proxy_buffering off`），适合流式响应
- 连接超时 60s，读写超时 **600s**（10 分钟，适配 LLM 长响应）

#### c) `default.conf` — 站点配置（核心路由）

**HTTP → HTTPS 重定向：**
```
:80 → 301 https://$host$request_uri
```

**HTTPS 443（域名 `www.ailiwen.com.cn`）：**

| 路径 | 代理目标 | 关键技巧 |
|------|----------|----------|
| `/api/` | `llmops-api.llmops.svc.cluster.local:5001` | 变量 proxy_pass + K8S CoreDNS 动态解析，rewrite 剥离 `/api` 前缀 |
| `/` | `llmops-ui.llmops.svc.cluster.local:3000` | 变量 proxy_pass + resolver 运行时解析 |

> **为什么用变量 proxy_pass？** K8S 的 Pod IP 会在重建后变化。静态 `upstream` 块只在 Nginx 启动时解析一次 DNS，之后 IP 变化会导致 `Connection refused`。使用 `resolver` + 变量 `$ui_host` / `$api_host` 的方式，Nginx 会在每次请求时根据 DNS TTL 动态重新解析，确保始终路由到正确的 Pod IP。

**TLS 配置：**
- 证书/私钥从 K8S TLS Secret 挂载到 `/etc/ssl/tls.crt` 和 `/etc/ssl/tls.key`
- 仅启用 TLSv1.2 和 TLSv1.3
- 开启 SSL session 缓存（10MB 共享内存，10 分钟超时）

---

### 1.4 `nginx-deployment.yaml` —— Nginx 反向代理部署

| 配置项 | 值 | 说明 |
|--------|-----|------|
| 副本数 | 1 | 单副本，可通过 `kubectl scale` 扩展 |
| 节点选择 | `node-role.kubernetes.io/control-plane: "true"` | 固定在 control-plane 节点（与 UI 同节点，降低内网延迟） |
| 镜像 | `ccr.ccs.tencentyun.com/my-app-20/nginx-llmops:latest` | 腾讯云 CCR 私有镜像 |
| 拉取策略 | `Always` | 每次重建都拉取最新镜像 |
| 容器端口 | 80 (HTTP), 443 (HTTPS) | |
| 资源请求 | 128Mi / 100m | 最小保证资源 |
| 资源限制 | 512Mi / 500m | 最大可用资源 |

**卷挂载（关键架构点）：**

| 卷 | 来源 | 挂载路径 | 说明 |
|-----|------|----------|------|
| nginx-config | ConfigMap `nginx-config` | `/etc/nginx/nginx.conf` | 主配置（subPath） |
| nginx-config | ConfigMap `nginx-config` | `/etc/nginx/proxy.conf` | 代理通用配置（subPath） |
| nginx-config | ConfigMap `nginx-config` | `/etc/nginx/conf.d/default.conf` | 站点路由配置（subPath） |
| tls | Secret `nginx-tls` | `/etc/ssl` | SSL 证书（只读） |

> **注意：** 所有配置以 `subPath` 方式挂载单个文件。这种方式的副作用是 **ConfigMap 更新不会自动反映到运行中的 Pod**，因此部署脚本会在检测到 ConfigMap 变化后执行 `rollout restart`。

**健康检查：**
- Liveness / Readiness 均检查 TCP 443 端口

---

### 1.5 `nginx-service.yaml` —— Nginx 对外服务

| 配置项 | 值 |
|--------|-----|
| 类型 | **LoadBalancer** |
| 端口 | 80 → 80 (HTTP), 443 → 443 (HTTPS) |
| Selector | `app: nginx` |

LoadBalancer 类型会自动创建腾讯云 CLB（Cloud Load Balancer），分配公网 IP，用户通过该 IP + 域名 `www.ailiwen.com.cn` 访问服务。

---

### 1.6 `llmops-ui-deployment.yaml` —— 前端 UI 部署

| 配置项 | 值 | 说明 |
|--------|-----|------|
| 副本数 | 1 | |
| 节点选择 | control-plane | 与 Nginx 同节点 |
| 镜像 | `ccr.ccs.tencentyun.com/my-app-20/llmops-ui:latest` | 前端镜像（Nginx Alpine + 静态资源） |
| 容器端口 | 3000 | UI 容器内 Nginx 监听端口 |
| 资源请求 | 64Mi / 50m | 轻量级前端，资源需求小 |
| 资源限制 | 256Mi / 200m | |

**前端镜像内部架构：**

```
llmops-ui 镜像 (FROM nginx:alpine)
├── nginx.conf     → 自定义配置，监听 3000 端口，SPA fallback
├── dist/          → 前端构建产物 → /usr/share/nginx/html/
│   └── assets/    → CSS/JS 等资源（1 年强缓存）
```

**SPA 路由支持：**
```
location / {
    try_files $uri $uri/ /index.html;
}
```
所有未匹配到静态文件的路径都返回 `index.html`，由前端路由（如 React Router）接管。

**健康检查：** HTTP GET `/` 端口 3000，保证 UI 页面可访问。

---

### 与 `nginx/` 目录的镜像构建关系

`k8s/nginx-configmap.yaml` 中的 ConfigMap 内容来源于 `nginx/` 目录下原始配置文件的适配版本：

| 源文件 | 关系 |
|--------|------|
| `nginx/nginx.conf` | ConfigMap 中 `nginx.conf` 的原始来源 |
| `nginx/proxy.conf` | ConfigMap 中 `proxy.conf` 的原始来源 |
| `nginx/conf.d/default.conf` | ConfigMap 中 `default.conf` 的基础版本 |

**区别：** ConfigMap 版本使用 K8S 内部 DNS 名称（如 `llmops-api.llmops.svc.cluster.local`）和 `resolver kube-dns`，而原始 `.conf` 文件使用简单的 Service 名称（如 `llmops-api`）。这是因为 ConfigMap 的配置在 K8S 集群内运行，需要适配 Pod 网络环境。

SSL 证书文件 `nginx/ssl/www.ailiwen.com.cn.pem` 和 `.key` 不打包进镜像，而是通过部署脚本创建 K8S TLS Secret，运行时挂载。

---

## 二、`scripts/` 目录 —— 部署脚本

该目录存放 **2 个 Shell 脚本**，负责完整的 CI/CD 流水线：构建镜像 → 推送 CCR → 部署 K8S 资源 → 等待就绪 → 验证连通性。

### 文件总览

| 脚本 | 用途 |
|------|------|
| `deploy-ui.sh` | 构建、推送并部署前端 UI |
| `deploy-nginx.sh` | 部署/更新 Nginx 反向代理（含可选镜像构建） |

---

### 2.1 `deploy-ui.sh` —— 前端 UI 部署

**执行流程（5 步）：**

```
[preflight] 检查依赖
    ├── docker、kubectl 是否安装
    ├── llmops-ui/dist/ 目录是否存在（前端是否已构建）
    └── CCR_PASSWORD 环境变量是否设置
         ↓
[1/5] 登录 CCR（腾讯云容器镜像仓库）
         ↓
[2/5] 使用 Docker 构建镜像
    sudo docker build -t ccr.ccs.tencentyun.com/my-app-20/llmops-ui:latest ./llmops-ui
         ↓
[3/5] 推送镜像到 CCR
         ↓
[4/5] 应用 K8S Deployment
    kubectl apply -f k8s/llmops-ui-deployment.yaml
    + latest 标签时自动 rollout restart（确保拉取最新镜像）
         ↓
[5/5] 等待 Deployment 就绪 (timeout=120s)
         ↓
[状态汇总] Pod 状态 + Service 信息 + Endpoints
         ↓
[连通性验证]
    ├── Pod 内自检 (wget localhost:3000)
    └── 外部验证 (curl https://<LB_IP>/)
```

**环境变量：**

| 变量 | 必需 | 默认值 | 说明 |
|------|------|--------|------|
| `CCR_PASSWORD` | 是 | - | 腾讯云 CCR 登录密码 |
| `TAG` | 否 | `latest` | 镜像标签，如 `v1.2.3` |
| `ROLLOUT_TIMEOUT` | 否 | `120s` | 滚动更新超时时间 |

**使用示例：**
```bash
# 默认 latest 标签
CCR_PASSWORD=xxx ./scripts/deploy-ui.sh

# 指定版本标签（推荐用于生产）
TAG=v1.2.3 CCR_PASSWORD=xxx ./scripts/deploy-ui.sh

# 自定义超时
ROLLOUT_TIMEOUT=300s CCR_PASSWORD=xxx ./scripts/deploy-ui.sh
```

**核心设计：latest 标签 vs 版本标签**

- `latest` 标签：镜像名不变，需执行 `rollout restart` 触发重新拉取（配合 `imagePullPolicy: Always`）
- 版本标签（如 `v1.2.3`）：`kubectl apply` 更新 image 字段后，Deployment 控制器自动触发滚动更新

---

### 2.2 `deploy-nginx.sh` —— Nginx 反向代理部署

**支持两种模式：**

#### 模式 A：仅更新配置（默认，不重建镜像）

触发条件：不加 `--build` 参数时。

```
流程：
[1/7] 确保 namespace/llmops 存在
[2/7] 创建/更新 CCR imagePullSecret
[3/7] 创建/更新 TLS Secret (nginx-tls)
         ├── 读取 nginx/ssl/www.ailiwen.com.cn.pem
         └── 读取 nginx/ssl/www.ailiwen.com.cn.key
[4/7] 应用 ConfigMap (nginx 配置)
         比较 resourceVersion → 如果变化则标记 CONFIGMAP_CHANGED=true
[5/7] 应用后端 Service (确保 upstream DNS 可解析)
[6/7] 应用 Deployment + Service
         ├── ConfigMap 变化 → rollout restart
         └── ConfigMap 无变化 → 不做操作
[7/7] 等待就绪 + 状态汇总 + 外部验证
```

**适用场景：** 修改路由规则、添加新 location、调整超时时间、更新 SSL 证书 等纯配置变更。

#### 模式 B：构建镜像 + 更新配置（`--build`）

触发条件：加 `--build` 参数。

```
额外执行：
[build] 登录 CCR
[build] docker build -t nginx-llmops:latest ./nginx
[build] docker push
然后继续模式 A 的全部步骤
```

**适用场景：** Nginx 本身需要升级（如 Alpine base image 安全更新）、添加新模块、修改 nginx.conf 主配置结构。

**命令行参数：**

| 参数 | 说明 |
|------|------|
| `--build` | 构建并推送新的 Nginx 镜像 |
| `--tag <tag>` | 指定镜像标签（默认 latest） |
| 无参数 | 仅更新 ConfigMap + 重启 |

**关键设计：智能重启判断**

脚本通过比较 ConfigMap 的 `resourceVersion` 判断配置是否真的变化，只在以下条件才触发 `rollout restart`：
1. ConfigMap 内容发生变化
2. 通过 `--build` 构建了新镜像且标签为 `latest`

避免了无意义的 Pod 重启。

**创建的 K8S 资源：**

| 步骤 | 资源 | 说明 |
|------|------|------|
| 2/7 | `Secret/ccr-registry` | Docker registry 凭据，供 Deployment 拉取私有镜像 |
| 3/7 | `Secret/nginx-tls` | TLS 证书，从本地 `nginx/ssl/` 读取 |
| 4/7 | `ConfigMap/nginx-config` | Nginx 配置 |
| 5/7 | `Service/llmops-ui`, `Service/llmops-api` | 后端 Service 占位 |
| 6/7 | `Deployment/nginx`, `Service/nginx` | 核心部署 |

**使用示例：**
```bash
# 仅更新配置（最常用）
./scripts/deploy-nginx.sh

# 构建镜像 + 更新配置
CCR_PASSWORD=xxx ./scripts/deploy-nginx.sh --build

# 构建镜像 + 指定版本标签
CCR_PASSWORD=xxx ./scripts/deploy-nginx.sh --build --tag v1.0.1
```

---

## 三、部署依赖关系图

```
首次部署顺序:
─────────────────

1. ./scripts/deploy-nginx.sh --build     # 构建 nginx 镜像, 创建 namespace/secret/service/configmap/deployment
        ↓
2. ./scripts/deploy-ui.sh                # 构建前端镜像, 部署 UI Deployment
        ↓
   整体就绪 ✅

后续更新:
─────────────────

仅更新前端:
  修改 llmops-ui 代码 → 构建 dist/ → ./scripts/deploy-ui.sh

仅更新 Nginx 配置:
  修改 k8s/nginx-configmap.yaml → ./scripts/deploy-nginx.sh

更新 SSL 证书:
  替换 nginx/ssl/*.pem + *.key → ./scripts/deploy-nginx.sh

更新 Nginx 镜像:
  ./scripts/deploy-nginx.sh --build
```

## 四、关键设计决策总结

| 决策 | 原因 |
|------|------|
| Nginx 配置存为 ConfigMap | 改路由/超时不需要重建镜像，改完 configmap 重启即可 |
| subPath 挂载 + rollout restart | ConfigMap subPath 不自动热更新，需显式重启 Pod |
| 变量 proxy_pass + resolver | Pod IP 动态变化，静态 upstream 无法应对 |
| 后端 Service 占位先创建 | Nginx 启动时需 upstream DNS 可解析，否则 crash |
| LoadBalancer → Nginx → ClusterIP | 单入口 TLS 终结，内网走 ClusterIP 更简单安全 |
| control-plane 节点亲和性 | 避免跨节点网络开销，且 control-plane 不跑业务 Pod |
| imagePullPolicy: Always | latest 标签配合 Always 才能拉到最新镜像 |
| CCR 私有镜像 + imagePullSecrets | 安全存储镜像，不暴露到公网 |
