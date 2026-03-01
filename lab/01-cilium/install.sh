#!/usr/bin/env bash
# Cilium CNI Installation on Kind
# After this, nodes transition from NotReady to Ready.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="${1:-lab-dev}"
CILIUM_VERSION="1.19.1"

echo "=== Cilium ${CILIUM_VERSION} Installation ==="

# Detect Kind control plane API server IP
API_SERVER_IP=$(docker inspect "${CLUSTER_NAME}-control-plane" \
  --format '{{ .NetworkSettings.Networks.kind.IPAddress }}' 2>/dev/null) || {
    echo "[ERROR] Cluster '${CLUSTER_NAME}' not found. Run cluster/setup-cluster.sh first."
    exit 1
}
echo "[INFO] API Server IP: ${API_SERVER_IP}"

# Add Cilium Helm repo
helm repo add cilium https://helm.cilium.io/ 2>/dev/null || true
helm repo update cilium

# Install Cilium
helm upgrade --install cilium cilium/cilium \
  --version "${CILIUM_VERSION}" \
  --namespace kube-system \
  --values "${SCRIPT_DIR}/values.yaml" \
  --set k8sServiceHost="${API_SERVER_IP}"

# Wait for nodes to become Ready
echo "[INFO] Waiting for nodes to become Ready (timeout: 300s)..."
kubectl wait --for=condition=Ready nodes --all --timeout=300s

# Verify Cilium status
echo ""
echo "[INFO] Cilium status:"
cilium status --wait 2>/dev/null || echo "[WARN] cilium-cli not installed, skipping status check"

echo ""
echo "[OK] Cilium installation complete. All nodes are Ready."
