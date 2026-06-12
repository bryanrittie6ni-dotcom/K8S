#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# ==================== 配置 ====================
REGISTRY="ccr.ccs.tencentyun.com"       # Docker 镜像仓库地址
REGISTRY_NS="my-app-20"                 # 仓库命名空间
IMAGE_NAME="nginx-llmops"               # 镜像名称
TAG="${TAG:-latest}"                    # 镜像标签，可通过环境变量覆盖

FULL_IMAGE="${REGISTRY}/${REGISTRY_NS}/${IMAGE_NAME}:${TAG}"

# ==================== CCR 登录 ====================
echo "==> 登录 CCR (${REGISTRY})"
if [ -z "${CCR_PASSWORD:-}" ]; then
  echo "ERROR: 环境变量 CCR_PASSWORD 未设置"
  echo "      用法: CCR_PASSWORD=xxx ./scripts/build-and-push.sh"
  exit 1
fi
echo "$CCR_PASSWORD" | docker login "${REGISTRY}" --username="100028762684" --password-stdin

# ==================== 构建 ====================
echo "==> 构建镜像: ${FULL_IMAGE}"
docker build -t "${FULL_IMAGE}" "${ROOT_DIR}/nginx"

# ==================== 推送 ====================
echo "==> 推送镜像: ${FULL_IMAGE}"
docker push "${FULL_IMAGE}"

echo ""
echo "==> 完成: ${FULL_IMAGE}"
echo "    下一步: CCR_PASSWORD=xxx sudo -E ./scripts/deploy.sh"
