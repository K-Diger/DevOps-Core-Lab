#!/usr/bin/env bash
# Kind Cluster Setup
# Creates a Kind cluster with kube-proxy disabled and CNI disabled.
# Nodes will remain NotReady until Cilium CNI is installed (next step).
#
# Usage:
#   setup-cluster.sh [--env dev|stg|live] [--light]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse arguments
ENV="dev"
PROFILE="standard"

while [[ $# -gt 0 ]]; do
  case $1 in
    --env)
      ENV="${2:-dev}"
      if [[ ! "$ENV" =~ ^(dev|stg|live)$ ]]; then
        echo "[ERROR] --env must be dev, stg, or live"
        exit 1
      fi
      shift 2
      ;;
    --light|light)
      PROFILE="light"
      shift
      ;;
    *)
      # Backward compatibility: positional args
      if [[ -z "${_POS1:-}" ]]; then
        _POS1="$1"
      elif [[ -z "${_POS2:-}" ]]; then
        PROFILE="$1"
      fi
      shift
      ;;
  esac
done

CLUSTER_NAME="lab-${ENV}"

# Check if cluster already exists
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    echo "[INFO] Cluster '${CLUSTER_NAME}' already exists."
    kubectl cluster-info --context "kind-${CLUSTER_NAME}"
    exit 0
fi

CONFIG_FILE="${SCRIPT_DIR}/kind-config.yaml"

# Light profile: remove Worker 2 for 16GB machines
if [[ "${PROFILE}" == "light" ]]; then
    echo "[INFO] Light profile: creating 2-node cluster (1 control-plane + 1 worker)"
    TEMP_CONFIG=$(mktemp)
    grep -v "LIGHT_PROFILE_REMOVE_MARKER" "${CONFIG_FILE}" > "${TEMP_CONFIG}"
    CONFIG_FILE="${TEMP_CONFIG}"
else
    echo "[INFO] Standard profile: creating 3-node cluster (1 control-plane + 2 workers)"
fi

echo "[INFO] Creating Kind cluster '${CLUSTER_NAME}' (env: ${ENV})..."
kind create cluster --name "${CLUSTER_NAME}" --config "${CONFIG_FILE}"

# Cleanup temp file
[[ "${PROFILE}" == "light" ]] && rm -f "${TEMP_CONFIG}"

# Apply environment labels to all nodes
echo "[INFO] Applying node labels (env=${ENV}, team=platform)..."
for NODE in $(kubectl get nodes -o name); do
  kubectl label "${NODE}" env="${ENV}" team=platform --overwrite
done

echo ""
echo "[INFO] Cluster created. Node status:"
kubectl get nodes -o wide --show-labels
echo ""
echo "[NOTE] Nodes are NotReady — this is expected. Cilium CNI installation is next."
