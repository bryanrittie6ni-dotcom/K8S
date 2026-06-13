# 跨节点网络问题分析

## 集群拓扑

```
┌─────────────────────────────────────────────────────────────────┐
│ K3s Cluster                                                     │
│                                                                 │
│  ┌── vm-0-10-ubuntu (control-plane) ──────────────────────┐    │
│  │  公网 IP: 124.223.14.26           内网: (云 VPC)       │    │
│  │  Pod CIDR: 10.42.0.0/24                                │    │
│  │  ┌─────────┐ ┌──────┐ ┌──────────┐ ┌──────┐          │    │
│  │  │ CoreDNS │ │nginx │ │llmops-ui │ │  ... │          │    │
│  │  │10.42.0.4│ │.0.22 │ │  .0.21   │ │      │          │    │
│  │  └─────────┘ └──────┘ └──────────┘ └──────┘          │    │
│  └──────────────────────────────────────────────────────────┘    │
│                                                                 │
│  ┌── lsltidysqg (worker/agent) ───────────────────────────┐    │
│  │  内网 IP: 192.168.0.2                                    │    │
│  │  Pod CIDR: 10.42.2.0/24                                  │    │
│  │  (当前无 Pod — 全部迁至 control-plane)                    │    │
│  └──────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
```

## Flannel 网络模式

K3s 内嵌 Flannel 作为 CNI 插件：

```json
{
  "Network": "10.42.0.0/16",
  "Backend": {
    "Type": "host-gw"
  }
}
```

### host-gw 模式工作原理

```
Pod A (10.42.0.x) on Node1
    │
    ▼ cni0 bridge
Node1 (物理 IP: A.A.A.A)
    │
    │ L2 直连 (同网段)
    │ 对端节点必须能 ARP 解析
    ▼
Node2 (物理 IP: B.B.B.B)
    │
    ▼ cni0 bridge
Pod B (10.42.2.x) on Node2
```

### 为什么 host-gw 在此环境中失败

| 节点 | IP | 网段 |
|------|-----|------|
| vm-0-10-ubuntu | 124.223.14.26 (公网) | 云服务商 VPC |
| lsltidysqg | 192.168.0.2 (内网) | 本地局域网 |

两个节点 **不在同一二层网络**：
- L2 不通 → ARP 无法解析对端 MAC
- 路由不对 → `10.42.0.0/24` 的数据包走默认网关 `192.168.0.1`，无法到达 control-plane 节点

### 验证命令

```bash
# worker 节点上查看路由
ip route get 10.42.0.4
# 输出: 10.42.0.4 via 192.168.0.1 dev eth0 src 192.168.0.2
# ← 走默认网关，但网关不知道 10.42.0.0/24 在哪里

# ping CoreDNS (跨节点)
ping 10.42.0.4
# 输出: 100% packet loss
```

## 解决方案对比

### 方案 A：全部调度到同一节点（当前采用）

```yaml
nodeSelector:
  kubernetes.io/hostname: vm-0-10-ubuntu
```

| 优点 | 缺点 |
|------|------|
| 立即生效，无需改集群配置 | 单点故障 |
| 不需要节点间网络 | 所有资源竞争同一节点 |
| DNS/Service 解析完全正常 | 无法水平扩展 |

### 方案 B：切换 Flannel 后端为 vxlan

修改 K3s server 配置：
```yaml
# /etc/rancher/k3s/config.yaml
flannel-backend: vxlan
```

或 wireguard（加密隧道）：
```yaml
flannel-backend: wireguard-native
```

| 优点 | 缺点 |
|------|------|
| 跨节点通信正常 | 需要重启集群 |
| 支持水平扩展 | 有性能开销（封装/解封装） |
| 生产环境标准方案 | 需要节点间 UDP 端口互通 |

### 方案 C：将两个节点放入同一 VPC

将所有节点加入腾讯云 VPC，分配同网段内网 IP，`host-gw` 即可正常工作。

| 优点 | 缺点 |
|------|------|
| 性能最优（无隧道开销） | 需要迁移节点 |
| 架构最简单 | 混合云场景不适用 |

## 当前影响

| 影响 | 状态 |
|------|------|
| Pod 间通信 (同节点) | ✅ 正常 (cni0 bridge) |
| Service ClusterIP 访问 | ✅ 正常 (kube-proxy iptables) |
| DNS 解析 (同节点) | ✅ 正常 (CoreDNS 在同节点) |
| DNS 解析 (跨节点) | ❌ 不通 |
| kubectl exec/logs (本节点) | ✅ 正常 |
| kubectl exec/logs (worker) | ❌ 隧道不通 |
| 外部访问 (nginx LB) | ✅ 正常 |

## 建议

如果后续需要扩展（添加更多 worker 节点），**推荐方案 B（vxlan）**：

1. 修改 K3s server 的 `/etc/rancher/k3s/config.yaml` 添加 `flannel-backend: vxlan`
2. 重启 K3s server
3. 新节点加入时会自动使用 vxlan
4. 已有 Pod 不需要修改
