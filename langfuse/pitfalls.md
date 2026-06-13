# 部署坑点与解决方案

## 1. 跨节点 Pod 网络不通 ⚠️ 最严重

### 现象
- 部署在 worker 节点 (`lsltidysqg`) 的 Pod 无法解析 DNS
- `langfuse-web` 报错：`Can't reach database server at 'postgres:5432'`
- 从 worker 节点 ping 不通 control-plane 节点上的 Pod (10.42.0.x)

### 根因
K3s Flannel 使用 **`host-gw`** (Host Gateway) 模式，要求所有节点在同一 L2 网络。

但实际架构：
- `vm-0-10-ubuntu` (control-plane): 公网 IP `124.223.14.26`
- `lsltidysqg` (worker): 内网 IP `192.168.0.2`

两者不在同一 L2 网段，`host-gw` 无法建立跨节点路由。

### 解决方案
所有 Pod 强制调度到 control-plane 节点 (`vm-0-10-ubuntu`)：

```yaml
nodeSelector:
  kubernetes.io/hostname: vm-0-10-ubuntu
```

### 长期方案
- 将 Flannel 后端切换为 `vxlan` 或 `wireguard`
- 或确保所有节点在同一内网（如腾讯云 VPC 内）

---

## 2. 镜像拉取失败

### 现象
- `ErrImagePull` / `ImagePullBackOff`
- `pull access denied, repository does not exist or may require authorization`

### 根因
Docker Hub 从国内不可达，公共镜像源不稳定。

### 解决方案
所有镜像提前推送到腾讯云 CCR (`ccr.ccs.tencentyun.com/my-app-20/`)，配合 `imagePullSecrets: ccr-registry`。

---

## 3. PostgreSQL 版本不兼容

### 现象
```
FATAL: database files are incompatible with server
DETAIL: The data directory was initialized by PostgreSQL version 15,
         which is not compatible with this version 17.
```

### 根因
旧 PVC 中有 PG15 初始化的数据，新镜像用 PG17 无法读取。

### 解决方案
删除旧 PVC 重建（适用于无重要数据的场景）：
```bash
kubectl delete pvc -n llmops postgres-data
```
**升级数据库版本的正确方式：pg_dump → 升级 → pg_restore**

---

## 4. MinIO 权限问题

### 现象
```
FATAL Unable to initialize backend: Unable to write to the backend
file access denied, drive may be faulty
```

### 根因
CCR 上的 MinIO 镜像是 **Chainguard** 构建的，以非 root 用户 `uid 65532` 运行。PVC 挂载的 `/data` 目录默认 owner 为 root，MinIO 进程无写入权限。

### 解决方案
```yaml
securityContext:
  fsGroup: 65532
initContainers:
  - name: fix-permissions
    image: ccr.ccs.tencentyun.com/my-app-20/minio-mc:latest
    command: ["sh", "-c", "chown -R 65532:65532 /data && chmod -R u+rwx /data"]
    volumeMounts:
      - name: data
        mountPath: /data
```

---

## 5. ClickHouse 迁移 URL 未配置

### 现象
```
Error: CLICKHOUSE_MIGRATION_URL is not configured.
error: failed to open database: unknown driver http (forgotten import?)
```

### 根因
Langfuse 需要单独的 `CLICKHOUSE_MIGRATION_URL` 环境变量进行数据库迁移。且必须使用 ClickHouse Native 协议 (`clickhouse://`)，不能用 HTTP (`http://`)。

### 解决方案
```yaml
CLICKHOUSE_MIGRATION_URL: "clickhouse://clickhouse:9000"
```

---

## 6. 节点资源不足

### 现象
```
0/2 nodes are available: 1 Insufficient cpu
```

### 根因
control-plane 节点只有 2 CPU，所有 Pod 的 CPU requests 总和超过可用量。

### 解决方案
降低非关键 Pod 的 CPU requests：
- `langfuse-web`: 500m → 200m
- `langfuse-worker`: 500m → 200m

---

## 7. kubectl exec/logs 到 Worker 节点失败

### 现象
```
proxy error from 127.0.0.1:6443 while dialing 192.168.0.2:10250, code 502: 502 Bad Gateway
```

### 根因
K3s server 通过 `docker0` 网桥 (172.17.0.0/16) 隧道连接 agent 的 kubelet。但 `docker0` 接口状态为 `DOWN`/`NO-CARRIER`，隧道不通。

### 影响
- 无法 `kubectl exec` / `kubectl logs` 到 worker 节点上的 Pod
- Pod 调度和运行不受影响（通过 CNI 通信）
- 部署到 control-plane 节点后不再有此问题

---

## 8. 容器内无 curl/wget 等调试工具

### 现象
无法通过 `kubectl exec -- curl` 测试服务连通性。

### 解决方案
使用 `kubectl run` 启动临时测试 Pod：
```bash
kubectl run test --image=ccr.ccs.tencentyun.com/my-app-20/redis:7 --rm -it --restart=Never -- sh
```
