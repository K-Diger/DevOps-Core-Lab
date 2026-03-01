#!/usr/bin/env bash
# OPA Gatekeeper Installation + 4 Policies
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== OPA Gatekeeper Installation ==="

helm repo add gatekeeper https://open-policy-agent.github.io/gatekeeper/charts 2>/dev/null || true
helm repo update gatekeeper

helm upgrade --install gatekeeper gatekeeper/gatekeeper \
  --namespace gatekeeper-system --create-namespace \
  --version 3.21.1 \
  --values "${SCRIPT_DIR}/values.yaml" \
  --wait --timeout 300s

# Wait for webhook to be ready
echo "[INFO] Waiting for Gatekeeper webhook..."
kubectl wait --for=condition=Ready pods -l control-plane=controller-manager \
  -n gatekeeper-system --timeout=120s
sleep 5  # Allow webhook to register

# Apply policies (template first, then constraint after CRD registration)
echo "[INFO] Applying ConstraintTemplates..."
for policy_dir in "${SCRIPT_DIR}"/policies/*/; do
    policy_name=$(basename "${policy_dir}")
    echo "  - ${policy_name} (template)"
    kubectl apply -f "${policy_dir}/template.yaml"
done

echo "[INFO] Waiting for CRDs to register..."
sleep 10

echo "[INFO] Applying Constraints..."
for policy_dir in "${SCRIPT_DIR}"/policies/*/; do
    policy_name=$(basename "${policy_dir}")
    if [ -f "${policy_dir}/constraint.yaml" ]; then
        echo "  - ${policy_name} (constraint)"
        kubectl apply -f "${policy_dir}/constraint.yaml"
    fi
done

echo ""
echo "[OK] Gatekeeper + 4 policies installed."
kubectl get constrainttemplates
kubectl get constraints
