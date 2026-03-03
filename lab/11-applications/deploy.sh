#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== MIS 애플리케이션 배포 ==="

# Harbor credentials
HARBOR_REGISTRY="${HARBOR_REGISTRY:-dev-mis-registry.smiledev.net}"
HARBOR_USER="${HARBOR_USER:-}"
HARBOR_PASS="${HARBOR_PASS:-}"

if [ -z "$HARBOR_USER" ] || [ -z "$HARBOR_PASS" ]; then
  echo "[WARN] Harbor credentials not set. Set HARBOR_USER and HARBOR_PASS environment variables."
  echo "  Example: HARBOR_USER=robot_tlm HARBOR_PASS=xxx bash 11-applications/deploy.sh"
  echo ""
  read -p "Harbor Username: " HARBOR_USER
  read -sp "Harbor Password: " HARBOR_PASS
  echo ""
fi

# 1. Create namespace
echo "[INFO] Creating mis-dev namespace..."
kubectl apply -f "${SCRIPT_DIR}/namespace.yaml"

# 2. Create image pull secret
echo "[INFO] Creating Harbor pull secret..."
kubectl create secret docker-registry harbor-pull-secret \
  --docker-server="${HARBOR_REGISTRY}" \
  --docker-username="${HARBOR_USER}" \
  --docker-password="${HARBOR_PASS}" \
  --namespace mis-dev \
  --dry-run=client -o yaml | kubectl apply -f -

# 3. Deploy applications
for APP_DIR in eam tlm gea itg common observer; do
  if [ -d "${SCRIPT_DIR}/${APP_DIR}" ]; then
    echo "[INFO] Deploying ${APP_DIR}..."
    kubectl apply -f "${SCRIPT_DIR}/${APP_DIR}/deployment.yaml"
  fi
done

# 4. Wait for pods (with timeout, don't fail on timeout)
echo "[INFO] Waiting for pods to start (timeout 5min)..."
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/part-of=mis-platform \
  -n mis-dev --timeout=300s 2>/dev/null || {
  echo "[WARN] Some pods may still be starting. Check status:"
  kubectl get pods -n mis-dev -o wide
}

echo ""
echo "[OK] MIS application deployment complete."
echo "[INFO] Pod status:"
kubectl get pods -n mis-dev -o wide
echo ""
echo "[INFO] Services:"
kubectl get svc -n mis-dev
