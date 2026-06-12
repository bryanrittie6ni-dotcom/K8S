# K8S 注意事项

> 整理自 2026-06-12 nginx 部署排障过程。

---

## 1. nginx `proxy_pass` 静态 DNS 解析导致启动崩溃

**现象**：Pod 状态 `CrashLoopBackOff`，容器 Exit Code 1，nginx 几秒内退出。

**根因**：nginx 对字面量 `proxy_pass http://<upstream>:<port>` 会在**启动时**解析 DNS。如果目标 Service 尚不存在，nginx 直接退出：

```
host not found in upstream "llmops-ui" in /etc/nginx/conf.d/default.conf:27
nginx: configuration file /etc/nginx/nginx.conf test failed
```

**修复**：改用变量 + `resolver`，让 nginx 在**请求时**才解析 DNS（运行时解析）：

```nginx
# ❌ 启动时解析 — upstream 不存在则 nginx 崩溃
location / {
    proxy_pass http://llmops-ui:3000;
}

# ✅ 运行时解析 — upstream 不存在时 nginx 仍能正常启动
location / {
    resolver kube-dns.kube-system.svc.cluster.local valid=30s ipv6=off;
    set $ui_host llmops-ui;
    proxy_pass http://$ui_host:3000;
}
```

> 这个模式在 API location 中已经正确使用了，UI location 遗漏了。

---

## 2. 排障技巧：Shell 包装会掩盖错误

**陷阱**：用 `sh -c "nginx -t; ...; nginx -g 'daemon off;'; sleep 5"` 诊断时，
即使 nginx 中途失败，shell 会继续执行后续命令并返回**最后一条命令的退出码**。

- 看到 `exitCode: 0` + `phase: Succeeded` → 容易误以为 nginx 启动成功
- 实际是 `sleep 5` 成功退出了，nginx 早就崩溃了

**正确做法**：使用 `set -e` 让 shell 在任何命令失败时立即退出：

```yaml
command: ["sh", "-c"]
args:
  - |
    set -e
    nginx -t
    exec nginx -g 'daemon off;'
```

---

## 3. kubelet 日志代理 502

**现象**：`kubectl logs` / `kubectl exec` 报错：

```
proxy error from 127.0.0.1:6443 while dialing 192.168.0.2:10250, code 502: 502 Bad Gateway
```

API Server 无法代理到远程节点（lsltidysqg 192.168.0.2）的 kubelet（10250 端口）。

**可能原因**：
- 节点间防火墙/安全组未放行 kubelet 端口（10250）
- k3s 的 API Server 使用了错误的 kubelet 地址类型
- 节点间网络不通

**绕过方法**：
- 将 Pod 调度到 API Server 所在节点（`nodeName` / `nodeSelector`），本地 kubelet 通常可达
- 或 SSH 到目标节点用 `crictl` / `nerdctl` 直接查看容器日志

---

## 4. 节点兼容性差异

**现象**：相同镜像、相同配置在节点 A（vm-0-10-ubuntu）正常运行，在节点 B（lsltidysqg）崩溃（Exit Code 1）。

| 维度 | vm-0-10-ubuntu（✅） | lsltidysqg（❌） |
|------|---------------------|------------------|
| 角色 | control-plane,master | worker |
| OS | Ubuntu 22.04.5 | Ubuntu 24.04.1 |
| 内核 | 5.15.0-171 | 6.8.0-71 |
| containerd | 1.7.23-k3s2 | 1.7.23-k3s2 |

**可能原因**（未最终确认）：
- 内核差异导致的 seccomp/AppArmor 策略不同
- k3s worker 节点的安全策略限制
- 共享内存（`ssl_session_cache shared:SSL:10m;`）在不同内核上的行为差异

**兜底方案**：暂用 `nodeSelector` 调度到已验证可用的节点。

---

## 5. ConfigMap `subPath` 挂载注意事项

```yaml
volumeMounts:
  - name: nginx-config
    mountPath: /etc/nginx/conf.d/default.conf
    subPath: default.conf
```

- `subPath` 挂载只替换**单个文件**，不影响目录中其他文件
- `subPath` 挂载的文件**不会自动更新** — ConfigMap 更新后需重启 Pod 才能生效
- 非 `subPath` 目录挂载会在 ConfigMap 更新后自动同步（有延迟）

---

## 6. K8S TLS Secret 文件名约定  

```bash
kubectl create secret tls nginx-tls --cert=xxx.pem --key=xxx.key -n llmops
```

Secret 内部文件名固定为：
- `tls.crt` — 证书（无论你 `--cert` 传什么文件名）
- `tls.key` — 私钥（无论你 `--key` 传什么文件名）

nginx 配置中必须引用这两个固定名称：

```nginx
ssl_certificate     /etc/ssl/tls.crt;
ssl_certificate_key /etc/ssl/tls.key;
```

---

## 7. imagePullSecret 环境变量

```bash
# ❌ 忘记 export CCR_PASSWORD 导致密码为空，kubectl 报错
kubectl create secret docker-registry ccr-registry \
  --docker-password="${CCR_PASSWORD:-}" ...

# ✅ 正确使用
CCR_PASSWORD=Qq289848 sudo -E ./scripts/deploy-nginx.sh
```

`-E` 保留当前用户环境变量传递给 `sudo`。脚本中不应硬编码凭据。

---

## 8. 内存限制建议

nginx 开启 SSL 后需要更多内存（特别是 `ssl_session_cache shared:SSL:10m`）：

```yaml
# ❌ 太紧 — 导致 OOM Kill
resources:
  requests: {memory: "64Mi"}
  limits:   {memory: "128Mi"}

# ✅ SSL + 代理场景下更安全
resources:
  requests: {memory: "128Mi"}
  limits:   {memory: "512Mi"}
```

---

## 9. 探针配置

```yaml
# initialDelaySeconds 太短 + nginx 启动慢 = 还没起来就被 kill
livenessProbe:
  tcpSocket: {port: 443}
  initialDelaySeconds: 10   # ❌ 太短
  periodSeconds: 30

# 更稳健的配置
livenessProbe:
  tcpSocket: {port: 443}
  initialDelaySeconds: 15   # ✅ 留足启动时间
  periodSeconds: 30
  failureThreshold: 3       # 30s × 3 = 90s 后才重启
```

---

## 快速排障清单

1. `kubectl describe pod` → 看 Events（OOMKilled？BackOff？）
2. `kubectl get pod -o yaml` → 看 `containerStatuses.state.terminated.exitCode`
3. 如果 `kubectl logs` 不通 → 创建诊断 Pod 到同节点，用 `set -e` + `nginx -t` 捕获错误输出
4. 跨节点日志不通 → 在**本地节点**创建诊断 Pod 获取日志
5. `nginx -t` 通过 ≠ nginx 能启动 → 某些错误只在 `daemon off` 时才发生
