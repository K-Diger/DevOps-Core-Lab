#!/usr/bin/env bash
# Istio Ambient Mode Installation
# Requires: Cilium CNI already running
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Istio Ambient Mode Installation ==="

# Verify Cilium is ready
echo "[INFO] Verifying Cilium is running..."
kubectl wait --for=condition=Ready pods -l k8s-app=cilium -n kube-system --timeout=120s

# Add Istio Helm repo
helm repo add istio https://istio-release.storage.googleapis.com/charts 2>/dev/null || true
helm repo update istio

# Step 1: Install Istio Base (CRDs)
echo "[INFO] Step 1/3: Installing Istio Base CRDs..."
helm upgrade --install istio-base istio/base \
  --namespace istio-system --create-namespace \
  --version 1.29.0 \
  --values "${SCRIPT_DIR}/values-base.yaml" \
  --wait

# Step 2: Install istiod + Istio CNI
echo "[INFO] Step 2/3: Installing istiod (Ambient profile)..."
helm upgrade --install istiod istio/istiod \
  --namespace istio-system \
  --version 1.29.0 \
  --values "${SCRIPT_DIR}/values-istiod.yaml" \
  --wait --timeout 300s

helm upgrade --install istio-cni istio/cni \
  --namespace istio-system \
  --version 1.29.0 \
  --values "${SCRIPT_DIR}/values-cni.yaml" \
  --wait

# Step 3: Install ztunnel
echo "[INFO] Step 3/3: Installing ztunnel..."
helm upgrade --install ztunnel istio/ztunnel \
  --namespace istio-system \
  --version 1.29.0 \
  --values "${SCRIPT_DIR}/values-ztunnel.yaml" \
  --wait

# Step 4: Apply security policies (PeerAuthentication STRICT, etc.)
echo "[INFO] Step 4/4: Applying Istio security policies..."
# Apply mesh-wide policies (istio-system namespace — always exists)
kubectl apply -f "${SCRIPT_DIR}/policies/peer-authentication.yaml"
kubectl apply -f "${SCRIPT_DIR}/policies/telemetry.yaml"
# AuthorizationPolicy targets demo namespace (created later in Step 8)
# Apply with || true to avoid blocking; re-applied after demo namespace exists
kubectl apply -f "${SCRIPT_DIR}/policies/authz-policy.yaml" 2>/dev/null || {
  echo "[WARN] authz-policy skipped (demo namespace not yet created). Will be applied after demo-app deployment."
}

# Step 5: Add ambient mesh label to kong namespace (for mTLS with STRICT PeerAuthentication)
echo "[INFO] Step 5: Labeling kong namespace for ambient mesh..."
kubectl label ns kong istio.io/dataplane-mode=ambient --overwrite 2>/dev/null || true

# Step 6: Kong Gateway — allow external plaintext on proxy ports (NodePort traffic)
echo "[INFO] Step 6: Applying Kong PeerAuthentication (PERMISSIVE on proxy ports)..."
kubectl apply -f "${SCRIPT_DIR}/policies/kong-peer-authentication.yaml"

# Verify
echo ""
echo "[INFO] Istio Pods:"
kubectl get pods -n istio-system
echo ""
echo "[INFO] PeerAuthentication:"
kubectl get peerauthentication -A
echo ""
echo "[OK] Istio Ambient Mode installation complete."
