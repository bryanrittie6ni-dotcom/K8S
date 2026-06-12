#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# ==================== 配置 ====================
REGISTRY="ccr.ccs.tencentyun.com"
REGISTRY_NS="my-app-20"
IMAGE_NAME="nginx-llmops"
K8S_NS="llmops"
TAG="${TAG:-latest}"
FULL_IMAGE="${REGISTRY}/${REGISTRY_NS}/${IMAGE_NAME}:${TAG}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-120s}"

# ==================== 参数解析 ====================
BUILD_IMAGE=false
while [ $# -gt 0 ]; do
  case "$1" in
    --build)
      BUILD_IMAGE=true
      shift
      ;;
    --tag)
      TAG="$2"
      FULL_IMAGE="${REGISTRY}/${REGISTRY_NS}/${IMAGE_NAME}:${TAG}"
      shift 2
      ;;
    *)
      echo "用法: $0 [--build] [--tag <tag>]"
      echo "  --build    重新构建并推送 nginx 镜像（新增模块/升级 base image 时用）"
      echo "  --tag      指定镜像标签（默认 latest）"
      echo ""
      echo "  不加 --build 时只更新 ConfigMap + 重启，不碰镜像"
      echo "  改路由地址、超时、location 块等都不需要 rebuild"
      exit 1
      ;;
  esac
done

# ==================== 前置检查 ====================
echo "==> [preflight] 检查依赖"
for cmd in kubectl; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: $cmd 未安装或不在 PATH 中"
    exit 1
  fi
done

# ==================== Step 1: CCR 登录 & 构建镜像（可选） ====================
if [ "$BUILD_IMAGE" = true ]; then
  if [ -z "${CCR_PASSWORD:-}" ]; then
    echo "ERROR: --build 需要 CCR_PASSWORD 环境变量"
    echo "      用法: CCR_PASSWORD=xxx $0 --build"
    exit 1
  fi
  if ! command -v docker &>/dev/null; then
    echo "ERROR: --build 需要 docker，但未安装"
    exit 1
  fi

  echo "==> [build] 登录 CCR"
  echo "$CCR_PASSWORD" | sudo docker login "${REGISTRY}" --username="100028762684" --password-stdin

  echo "==> [build] 构建镜像: ${FULL_IMAGE}"
  sudo docker build -t "${FULL_IMAGE}" "${ROOT_DIR}/nginx"

  echo "==> [build] 推送镜像: ${FULL_IMAGE}"
  sudo docker push "${FULL_IMAGE}"

  echo "==> [build] 镜像已更新"
else
  echo "==> [skip] 跳过镜像构建（改 nginx 配置不需要 rebuild，加 --build 可强制）"
fi

# ==================== Step 2: Namespace ====================
echo "==> [1/7] 确保 namespace/${K8S_NS} 存在"
kubectl apply -f "${ROOT_DIR}/k8s/namespace.yaml"

# ==================== Step 3: imagePullSecret ====================
echo "==> [2/7] 创建/更新 imagePullSecret (CCR)"
if [ -z "${CCR_PASSWORD:-}" ]; then
  echo "    WARN: CCR_PASSWORD 未设置，secret 将使用空密码"
fi
kubectl create secret docker-registry ccr-registry \
  --docker-server="${REGISTRY}" \
  --docker-username="100028762684" \
  --docker-password="${CCR_PASSWORD:-}" \
  -n "${K8S_NS}" \
  --dry-run=client -o yaml | kubectl apply -f -

# ==================== Step 4: TLS Secret ====================
echo "==> [3/7] 创建/更新 TLS Secret nginx-tls"
TLS_CERT="${ROOT_DIR}/nginx/ssl/www.ailiwen.com.cn.pem"
TLS_KEY="${ROOT_DIR}/nginx/ssl/www.ailiwen.com.cn.key"
if [ ! -f "$TLS_CERT" ] || [ ! -f "$TLS_KEY" ]; then
  echo "    WARN: SSL 证书文件缺失，跳过 TLS Secret"
  echo "          ${TLS_CERT}"
  echo "          ${TLS_KEY}"
else
  kubectl create secret tls nginx-tls \
    --cert="$TLS_CERT" \
    --key="$TLS_KEY" \
    -n "${K8S_NS}" \
    --dry-run=client -o yaml | kubectl apply -f -
fi

# ==================== Step 5: ConfigMap ====================
echo "==> [4/7] 应用 ConfigMap (nginx 配置)"
CONFIGMAP_BEFORE=$(kubectl get configmap nginx-config -n "${K8S_NS}" -o jsonpath='{.metadata.resourceVersion}' 2>/dev/null || echo "NEW")
kubectl apply -f "${ROOT_DIR}/k8s/nginx-configmap.yaml"
CONFIGMAP_AFTER=$(kubectl get configmap nginx-config -n "${K8S_NS}" -o jsonpath='{.metadata.resourceVersion}' 2>/dev/null)
CONFIGMAP_CHANGED=false
if [ "$CONFIGMAP_BEFORE" = "NEW" ] || [ "$CONFIGMAP_BEFORE" != "$CONFIGMAP_AFTER" ]; then
  CONFIGMAP_CHANGED=true
  echo "    ConfigMap 已更新 (resourceVersion: ${CONFIGMAP_BEFORE} -> ${CONFIGMAP_AFTER})"
else
  echo "    ConfigMap 无变化"
fi

# ==================== Step 6: 后端 Services ====================
echo "==> [5/7] 应用后端 Service（确保 upstream DNS 可解析）"
kubectl apply -f "${ROOT_DIR}/k8s/backend-services.yaml"

# ==================== Step 7: Deployment + Service ====================
echo "==> [6/7] 应用 Deployment + Service"
DEPLOY_EXISTS=$(kubectl get deployment nginx -n "${K8S_NS}" -o name 2>/dev/null || echo "")
kubectl apply -f "${ROOT_DIR}/k8s/nginx-deployment.yaml"
kubectl apply -f "${ROOT_DIR}/k8s/nginx-service.yaml"

# 触发重启的条件：
# 1. ConfigMap 有变化（subPath 挂载不会自动热更新）
# 2. 构建了新镜像 + latest 标签（镜像内容变了但 tag 没变）
NEED_RESTART=false
if [ "$CONFIGMAP_CHANGED" = true ] && [ -n "$DEPLOY_EXISTS" ]; then
  echo "    ConfigMap 变更 → 需要滚动重启"
  NEED_RESTART=true
fi
if [ "$BUILD_IMAGE" = true ] && [ "$TAG" = "latest" ] && [ -n "$DEPLOY_EXISTS" ]; then
  echo "    latest 镜像已更新 → 需要滚动重启拉取新镜像"
  NEED_RESTART=true
fi

if [ "$NEED_RESTART" = true ]; then
  kubectl rollout restart deployment/nginx -n "${K8S_NS}"
fi

# ==================== Step 8: 等待就绪 ====================
echo ""
echo "==> [7/7] 等待 Deployment 就绪 (timeout=${ROLLOUT_TIMEOUT})"
if kubectl rollout status deployment/nginx -n "${K8S_NS}" --timeout="${ROLLOUT_TIMEOUT}"; then
  echo ""
  echo "=============================================="
  echo "  nginx 部署成功"
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
  EXT_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "https://${LB_IP}/" 2>/dev/null || echo "000")
  echo "  外部访问 → HTTP ${EXT_CODE}"
fi
echo ""
echo "提示: 新增路由/改配置只需修改 k8s/nginx-configmap.yaml 然后："
echo "      $0                    # 只更新配置 + 重启"
echo "      $0 --build            # 需要重建镜像时"
