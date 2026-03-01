#!/usr/bin/env bash
# ArgoCD Installation
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== ArgoCD Installation ==="

helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm repo update argo

helm upgrade --install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  --version 9.4.5 \
  --values "${SCRIPT_DIR}/values.yaml" \
  --wait --timeout 300s

# Wait for ArgoCD to be ready
kubectl wait --for=condition=Ready pods -l app.kubernetes.io/name=argocd-server \
  -n argocd --timeout=180s

# Get initial admin password
ARGOCD_PW=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" 2>/dev/null | base64 -d)

echo ""
echo "[OK] ArgoCD installation complete."
echo ""
echo "  URL:      http://localhost:8080  (after port-forward)"
echo "  Username: admin"
echo "  Password: ${ARGOCD_PW}"
