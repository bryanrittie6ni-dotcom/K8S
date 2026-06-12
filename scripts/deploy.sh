#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

REGISTRY="ccr.ccs.tencentyun.com"
NAMESPACE="my-app-20"

# ==================== Step 1: namespace ====================
echo "==> Creating namespace llmops (if not exists)"
kubectl apply -f "${ROOT_DIR}/k8s/namespace.yaml"

# ==================== Step 2: imagePullSecret (CCR) ====================
echo "==> Creating imagePullSecret for CCR"
kubectl create secret docker-registry ccr-registry \
  --docker-server="${REGISTRY}" \
  --docker-username="100028762684" \
  --docker-password="${CCR_PASSWORD:-}" \
  -n llmops \
  --dry-run=client -o yaml | kubectl apply -f -

# ==================== Step 3: TLS Secret ====================
echo "==> Creating TLS secret nginx-tls (from local SSL files)"
kubectl create secret tls nginx-tls \
  --cert="${ROOT_DIR}/nginx/ssl/www.ailiwen.com.cn.pem" \
  --key="${ROOT_DIR}/nginx/ssl/www.ailiwen.com.cn.key" \
  -n llmops \
  --dry-run=client -o yaml | kubectl apply -f -

# ==================== Step 4: ConfigMap ====================
echo "==> Applying ConfigMap"
kubectl apply -f "${ROOT_DIR}/k8s/nginx-configmap.yaml"

# ==================== Step 5: Deployment ====================
echo "==> Applying Deployment"
kubectl apply -f "${ROOT_DIR}/k8s/nginx-deployment.yaml"

# ==================== Step 6: Service ====================
echo "==> Applying Service"
kubectl apply -f "${ROOT_DIR}/k8s/nginx-service.yaml"

# ==================== Step 7: Verify ====================
echo ""
echo "==> Deployment status:"
kubectl get pods -n llmops -l app=nginx
echo ""
echo "==> Service status:"
kubectl get svc -n llmops nginx
echo ""
echo "==> Waiting for LoadBalancer IP..."
echo "    (run: kubectl get svc nginx -n llmops -w)"
