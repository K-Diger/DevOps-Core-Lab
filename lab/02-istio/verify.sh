#!/usr/bin/env bash
# Istio Ambient Verification
set -euo pipefail

echo "=== Istio Ambient Verification ==="

echo ""
echo "--- 1. istiod status ---"
kubectl get pods -n istio-system -l app=istiod

echo ""
echo "--- 2. ztunnel DaemonSet ---"
kubectl get pods -n istio-system -l app=ztunnel -o wide

echo ""
echo "--- 3. Istio CNI ---"
kubectl get pods -n istio-system -l k8s-app=istio-cni-node

echo ""
echo "--- 4. PeerAuthentication ---"
kubectl get peerauthentication -A 2>/dev/null || echo "No PeerAuthentication found"

echo ""
echo "[OK] Istio Ambient verification complete."
