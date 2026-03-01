#!/usr/bin/env bash
# Cilium Verification
set -euo pipefail

echo "=== Cilium Verification ==="

echo ""
echo "--- 1. kube-proxy replacement ---"
RESULT=$(cilium status 2>/dev/null | grep KubeProxyReplacement || echo "unknown")
echo "KubeProxyReplacement: ${RESULT}"

echo ""
echo "--- 2. No kube-proxy pods ---"
KPROXY=$(kubectl get pods -n kube-system -l k8s-app=kube-proxy --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "${KPROXY}" == "0" ]]; then
    echo "[OK] No kube-proxy pods found (expected)"
else
    echo "[WARN] Found ${KPROXY} kube-proxy pod(s)"
fi

echo ""
echo "--- 3. Cilium pods ---"
kubectl get pods -n kube-system -l k8s-app=cilium -o wide

echo ""
echo "--- 4. Encryption status ---"
cilium status 2>/dev/null | grep -i encrypt || echo "Encryption info not available"

echo ""
echo "--- 5. Node status ---"
kubectl get nodes -o wide

echo ""
echo "[OK] Cilium verification complete."
