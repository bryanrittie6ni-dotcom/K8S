#!/bin/bash
set -euo pipefail

REGISTRY="ccr.ccs.tencentyun.com"
NAMESPACE="my-app-20"
IMAGE_NAME="nginx-llmops"
TAG="${TAG:-latest}"

FULL_IMAGE="${REGISTRY}/${NAMESPACE}/${IMAGE_NAME}:${TAG}"

echo "==> Building image: ${FULL_IMAGE}"
docker build -t "${FULL_IMAGE}" "$(dirname "$0")/../nginx"

echo "==> Pushing image: ${FULL_IMAGE}"
docker push "${FULL_IMAGE}"

echo "==> Done. Image: ${FULL_IMAGE}"
