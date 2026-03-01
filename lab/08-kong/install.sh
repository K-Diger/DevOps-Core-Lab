#!/usr/bin/env bash
# Kong Ingress Controller + Gateway API CRDs Installation
#
# Installs:
#   1. Gateway API CRDs (standard channel)
#   2. Kong Ingress Controller (DB-less mode, Gateway API enabled)
#   3. Gateway resource + HTTPRoutes for all services
#
# Traffic flow:
#   Client → localhost:80 → Kind NodePort 30080 → Kong Proxy → HTTPRoute → Service
#
# References:
#   - https://docs.konghq.com/kubernetes-ingress-controller/latest/
#   - https://gateway-api.sigs.k8s.io/
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Kong Ingress Controller Installation ==="

# 1. Install Gateway API CRDs (--server-side: idempotent, handles pre-existing CRDs)
echo "[INFO] Installing Gateway API CRDs (standard channel)..."
kubectl apply --server-side --force-conflicts \
  -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.0/standard-install.yaml

# 2. Create kong namespace
kubectl create namespace kong --dry-run=client -o yaml | kubectl apply -f -

# 3. Add Kong Helm repo
echo "[INFO] Adding Kong Helm repository..."
helm repo add kong https://charts.konghq.com 2>/dev/null || true
helm repo update kong

# 4. Install Kong Ingress Controller
echo "[INFO] Installing Kong Ingress Controller (DB-less mode)..."
helm upgrade --install kong kong/ingress \
  --namespace kong \
  --version 0.22.0 \
  --values "${SCRIPT_DIR}/values.yaml" \
  --wait --timeout 5m

# 5. Wait for Kong pods to be ready
echo "[INFO] Waiting for Kong pods..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=kong -n kong --timeout=180s

# 6. Apply Gateway resource
echo "[INFO] Applying Gateway resource..."
kubectl apply -f "${SCRIPT_DIR}/gateway.yaml"

# 7. Apply HTTPRoutes (namespaces may not exist yet; errors are expected and retried by setup.sh)
echo "[INFO] Applying HTTPRoutes (namespace가 없는 route는 이후 단계에서 재적용)..."
for ROUTE in "${SCRIPT_DIR}"/routes/*.yaml; do
  if [[ -f "$ROUTE" ]]; then
    if kubectl apply -f "$ROUTE" 2>/dev/null; then
      echo "  Applied: $(basename "$ROUTE")"
    else
      echo "  Skipped (namespace not yet created): $(basename "$ROUTE")"
    fi
  fi
done

echo ""
echo "[OK] Kong Ingress Controller installation complete."
echo "[INFO] External access:"
echo "  HTTP:  http://localhost:80  (Kong Gateway)"
echo "  HTTPS: https://localhost:443 (Kong Gateway)"
