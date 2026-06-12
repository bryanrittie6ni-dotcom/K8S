#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# ==================== 配置 ====================
REGISTRY="ccr.ccs.tencentyun.com"       # Docker 镜像仓库地址
REGISTRY_NS="my-app-20"                 # 仓库命名空间（镜像路径前缀）
K8S_NS="llmops"                         # Kubernetes 命名空间
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-120s}"

# ==================== 前置检查 ====================
echo "==> [preflight] 检查依赖"
for cmd in kubectl; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: $cmd 未安装或不在 PATH 中"
    exit 1
  fi
done

# 检查 CCR 密码（imagePullSecret 需要）
if [ -z "${CCR_PASSWORD:-}" ]; then
  echo "WARN: 环境变量 CCR_PASSWORD 未设置，imagePullSecret 将使用空密码"
  echo "      用法: CCR_PASSWORD=xxx sudo -E ./scripts/deploy.sh"
fi

# ==================== Step 1: Namespace ====================
echo "==> [1/8] 确保 namespace/${K8S_NS} 存在"
kubectl apply -f "${ROOT_DIR}/k8s/namespace.yaml"

# ==================== Step 2: imagePullSecret ====================
echo "==> [2/8] 创建/更新 imagePullSecret (CCR)"
kubectl create secret docker-registry ccr-registry \
  --docker-server="${REGISTRY}" \
  --docker-username="100028762684" \
  --docker-password="${CCR_PASSWORD:-}" \
  -n "${K8S_NS}" \
  --dry-run=client -o yaml | kubectl apply -f -

# ==================== Step 3: TLS Secret ====================
echo "==> [3/8] 创建/更新 TLS Secret nginx-tls"
TLS_CERT="${ROOT_DIR}/nginx/ssl/www.ailiwen.com.cn.pem"
TLS_KEY="${ROOT_DIR}/nginx/ssl/www.ailiwen.com.cn.key"
if [ ! -f "$TLS_CERT" ] || [ ! -f "$TLS_KEY" ]; then
  echo "ERROR: SSL 证书文件缺失: ${TLS_CERT} 或 ${TLS_KEY}"
  exit 1
fi
kubectl create secret tls nginx-tls \
  --cert="$TLS_CERT" \
  --key="$TLS_KEY" \
  -n "${K8S_NS}" \
  --dry-run=client -o yaml | kubectl apply -f -

# ==================== Step 4: ConfigMap ====================
echo "==> [4/8] 应用 ConfigMap (nginx 配置)"
CONFIGMAP_BEFORE=$(kubectl get configmap nginx-config -n "${K8S_NS}" -o jsonpath='{.metadata.resourceVersion}' 2>/dev/null || echo "NEW")
kubectl apply -f "${ROOT_DIR}/k8s/nginx-configmap.yaml"
CONFIGMAP_AFTER=$(kubectl get configmap nginx-config -n "${K8S_NS}" -o jsonpath='{.metadata.resourceVersion}' 2>/dev/null)
CONFIGMAP_CHANGED=false
if [ "$CONFIGMAP_BEFORE" = "NEW" ] || [ "$CONFIGMAP_BEFORE" != "$CONFIGMAP_AFTER" ]; then
  CONFIGMAP_CHANGED=true
  echo "    ConfigMap 已更新 (resourceVersion: ${CONFIGMAP_BEFORE} -> ${CONFIGMAP_AFTER})"
else
  echo "    ConfigMap 无变化，跳过"
fi

# ==================== Step 5: Backend Services ====================
echo "==> [5/8] 应用后端占位 Service (nginx upstream 需要 DNS 可解析)"
kubectl apply -f "${ROOT_DIR}/k8s/backend-services.yaml"

# ==================== Step 6: Deployment ====================
echo "==> [6/8] 应用 Deployment"
DEPLOY_EXISTS=$(kubectl get deployment nginx -n "${K8S_NS}" -o name 2>/dev/null || echo "")
kubectl apply -f "${ROOT_DIR}/k8s/nginx-deployment.yaml"

# 如果 ConfigMap 有更新，必须重启 Pod（subPath 挂载不会自动热更新）
if [ "$CONFIGMAP_CHANGED" = true ] && [ -n "$DEPLOY_EXISTS" ]; then
  echo "    ConfigMap 变更 + subPath 挂载 → 触发滚动重启"
  kubectl rollout restart deployment/nginx -n "${K8S_NS}"
fi

# ==================== Step 7: Service ====================
echo "==> [7/8] 应用 nginx Service (LoadBalancer)"
kubectl apply -f "${ROOT_DIR}/k8s/nginx-service.yaml"

# ==================== Step 8: 等待就绪 ====================
echo ""
echo "==> [8/8] 等待 Deployment 就绪 (timeout=${ROLLOUT_TIMEOUT})"
if kubectl rollout status deployment/nginx -n "${K8S_NS}" --timeout="${ROLLOUT_TIMEOUT}"; then
  echo ""
  echo "=============================================="
  echo "  部署成功"
  echo "=============================================="
else
  echo ""
  echo "=============================================="
  echo "  WARN: rollout 超时，请手动检查"
  echo "=============================================="
fi

# ==================== 状态汇总 ====================
echo ""
echo "--- Pods ---"
kubectl get pods -n "${K8S_NS}" -l app=nginx -o wide
echo ""
echo "--- Services ---"
kubectl get svc -n "${K8S_NS}"
echo ""
echo "--- Endpoints ---"
kubectl get endpoints -n "${K8S_NS}" nginx
echo ""
LB_IP=$(kubectl get svc nginx -n "${K8S_NS}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "<pending>")
echo "LoadBalancer IP: ${LB_IP}"
if [ "$LB_IP" != "<pending>" ]; then
  echo "  https://${LB_IP}/"
  echo "  http://${LB_IP}/  (→ 301 https)"
fi
echo ""
echo "提示: 后续更新 nginx 配置只需修改 ConfigMap YAML 后重新运行本脚本，"
echo "      脚本会自动检测 ConfigMap 变更并触发 Pod 滚动重启。"
