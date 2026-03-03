#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== ArgoCD ApplicationSet 설정 ==="

# Ensure ArgoCD namespace exists
kubectl get ns argocd > /dev/null 2>&1 || {
  echo "[ERROR] ArgoCD not installed. Run setup.sh first."
  exit 1
}

# Ensure mis-dev namespace exists
kubectl get ns mis-dev > /dev/null 2>&1 || {
  echo "[ERROR] mis-dev namespace not found. Run 11-applications/deploy.sh first."
  exit 1
}

# 1. Register the local git repo (or use directory-based)
echo "[INFO] Creating ArgoCD ApplicationSet..."
kubectl apply -f "${SCRIPT_DIR}/applicationset.yaml"

echo ""
echo "[OK] ArgoCD ApplicationSet created."
echo "[INFO] Applications:"
kubectl get applications -n argocd 2>/dev/null || echo "  (ApplicationSet will generate apps momentarily)"
echo ""
echo "[INFO] Access ArgoCD UI:"
echo "  URL: https://argocd.lab-dev.local"
ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null || echo "unknown")
echo "  Password: ${ARGOCD_PASS}"
