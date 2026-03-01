#!/usr/bin/env bash
set -euo pipefail
echo "=== ArgoCD Verification ==="
echo ""
echo "--- Pods ---"
kubectl get pods -n argocd
echo ""
echo "--- Applications ---"
kubectl get applications -n argocd 2>/dev/null || echo "No applications found"
echo ""
echo "[OK] ArgoCD verification complete."
