#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# ==================== 配置 ====================
REGISTRY="ccr.ccs.tencentyun.com"       # Docker 镜像仓库地址
REGISTRY_NS="my-app-20"                 # 仓库命名空间
IMAGE_NAME="llmops-ui"                  # 镜像名称
K8S_NS="llmops"                         # Kubernetes 命名空间

# 镜像标签：默认 latest，可通过环境变量覆盖
#   TAG=v1.2.3 ./scripts/deploy-ui.sh   → 使用指定版本
#   TAG=$(date +%Y%m%d-%H%M%S) ./scripts/deploy-ui.sh → 使用时间戳
TAG="${TAG:-latest}"

FULL_IMAGE="${REGISTRY}/${REGISTRY_NS}/${IMAGE_NAME}:${TAG}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-120s}"

# ==================== 前置检查 ====================
echo "==> [preflight] 检查依赖"
for cmd in docker kubectl; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: $cmd 未安装或不在 PATH 中"
    exit 1
  fi
done

if [ ! -d "${ROOT_DIR}/llmops-ui/dist" ]; then
  echo "ERROR: 前端构建产物目录不存在: ${ROOT_DIR}/llmops-ui/dist"
  echo "       请先构建前端项目，确保 dist/ 目录已生成"
  exit 1
fi

if [ -z "${CCR_PASSWORD:-}" ]; then
  echo "ERROR: 环境变量 CCR_PASSWORD 未设置"
  echo "      用法: CCR_PASSWORD=xxx ./scripts/deploy-ui.sh"
  exit 1
fi

# ==================== Step 1: CCR 登录 ====================
echo "==> [1/5] 登录 CCR (${REGISTRY})"
echo "$CCR_PASSWORD" | sudo docker login "${REGISTRY}" --username="100028762684" --password-stdin

# ==================== Step 2: 构建镜像 ====================
echo "==> [2/5] 构建镜像: ${FULL_IMAGE}"
sudo docker build -t "${FULL_IMAGE}" "${ROOT_DIR}/llmops-ui"

# ==================== Step 3: 推送镜像 ====================
echo "==> [3/5] 推送镜像: ${FULL_IMAGE}"
sudo docker push "${FULL_IMAGE}"

# ==================== Step 4: K8S 部署 ====================
echo "==> [4/5] 应用 K8S Deployment"
DEPLOY_EXISTS=$(kubectl get deployment llmops-ui -n "${K8S_NS}" -o name 2>/dev/null || echo "")

# 如果镜像标签是 latest 且 Deployment 已存在，需要触发滚动更新
# （imagePullPolicy: Always 会在新 Pod 上拉取最新镜像，但旧 Pod 不会自动重建）
RESTART_NEEDED=false
if [ "$TAG" = "latest" ] && [ -n "$DEPLOY_EXISTS" ]; then
  RESTART_NEEDED=true
fi

kubectl apply -f "${ROOT_DIR}/k8s/llmops-ui-deployment.yaml"

# 如果 Deployment 已存在且用 latest 标签，imagePullPolicy: Always 配合
# rollout restart 才能保证新镜像被拉取。
# 如果用版本标签（非 latest），apply 更新 image 字段后会自动触发滚动更新。
if [ "$RESTART_NEEDED" = true ]; then
  echo "    latest 标签 → 触发滚动重启以确保拉取最新镜像"
  kubectl rollout restart deployment/llmops-ui -n "${K8S_NS}"
fi

# ==================== Step 5: 等待就绪 ====================
echo ""
echo "==> [5/5] 等待 Deployment 就绪 (timeout=${ROLLOUT_TIMEOUT})"
if kubectl rollout status deployment/llmops-ui -n "${K8S_NS}" --timeout="${ROLLOUT_TIMEOUT}"; then
  echo ""
  echo "=============================================="
  echo "  llmops-ui 部署成功"
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
kubectl get pods -n "${K8S_NS}" -l app=llmops-ui -o wide
echo ""
echo "--- Service ---"
kubectl get svc -n "${K8S_NS}" llmops-ui
echo ""
echo "--- Endpoints ---"
kubectl get endpoints -n "${K8S_NS}" llmops-ui

# ==================== 连通性验证 ====================
echo ""
echo "--- 连通性验证 ---"
POD_NAME=$(kubectl get pods -n "${K8S_NS}" -l app=llmops-ui -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "$POD_NAME" ]; then
  echo "Pod: ${POD_NAME}"
  HTTP_CODE=$(kubectl exec -n "${K8S_NS}" "${POD_NAME}" -- wget -qO- --timeout=5 http://localhost:3000/ 2>&1 | head -1 || echo "FAIL")
  if echo "$HTTP_CODE" | grep -q '<!DOCTYPE html>'; then
    echo "  自检 (localhost:3000) → HTTP 200 ✅"
  else
    echo "  自检 (localhost:3000) → FAIL ❌"
  fi
fi

# 通过 nginx 反向代理验证
LB_IP=$(kubectl get svc nginx -n "${K8S_NS}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
if [ "$LB_IP" != "" ] && [ "$LB_IP" != "<pending>" ]; then
  EXT_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "https://${LB_IP}/" 2>/dev/null || echo "000")
  if [ "$EXT_CODE" = "200" ]; then
    echo "  外部 (https://${LB_IP}/) → HTTP ${EXT_CODE} ✅"
  else
    echo "  外部 (https://${LB_IP}/) → HTTP ${EXT_CODE} ❌"
  fi
fi

echo ""
echo "镜像: ${FULL_IMAGE}"
echo "提示: 后续仅更新前端包时，重新运行本脚本即可"
echo "      CCR_PASSWORD=xxx ./scripts/deploy-ui.sh"
echo "      TAG=v1.2.3 ./scripts/deploy-ui.sh  # 使用版本标签（推荐用于生产）"
