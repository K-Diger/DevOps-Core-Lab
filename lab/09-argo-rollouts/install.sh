#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Argo Rollouts Installation ==="

# Add Argo Helm repo
helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm repo update argo

# Install Argo Rollouts
helm upgrade --install argo-rollouts argo/argo-rollouts \
  --namespace argo-rollouts \
  --create-namespace \
  --values "${SCRIPT_DIR}/values.yaml" \
  --wait --timeout 5m

echo "[INFO] Waiting for Argo Rollouts controller..."
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=argo-rollouts \
  -n argo-rollouts --timeout=120s

# Install kubectl plugin info
echo ""
echo "[INFO] Creating AnalysisTemplate for Prometheus-based canary analysis..."

# Create AnalysisTemplate
cat <<'EOF' | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: ClusterAnalysisTemplate
metadata:
  name: success-rate
spec:
  args:
    - name: service-name
    - name: namespace
  metrics:
    - name: success-rate
      interval: 30s
      count: 3
      successCondition: result[0] >= 0.95
      failureLimit: 1
      provider:
        prometheus:
          address: http://mimir-gateway.monitoring.svc:80/prometheus
          query: |
            sum(rate(http_server_requests_seconds_count{service_name="{{args.service-name}}",namespace="{{args.namespace}}",http_response_status_code!~"5.."}[2m]))
            /
            sum(rate(http_server_requests_seconds_count{service_name="{{args.service-name}}",namespace="{{args.namespace}}"}[2m]))
---
apiVersion: argoproj.io/v1alpha1
kind: ClusterAnalysisTemplate
metadata:
  name: latency-p99
spec:
  args:
    - name: service-name
    - name: namespace
  metrics:
    - name: latency-p99
      interval: 30s
      count: 3
      successCondition: result[0] <= 2000
      failureLimit: 1
      provider:
        prometheus:
          address: http://mimir-gateway.monitoring.svc:80/prometheus
          query: |
            histogram_quantile(0.99,
              sum(rate(http_server_requests_seconds_bucket{service_name="{{args.service-name}}",namespace="{{args.namespace}}"}[2m])) by (le)
            ) * 1000
EOF

echo ""
echo "[OK] Argo Rollouts installation complete."
echo "[INFO] Dashboard: kubectl argo rollouts dashboard -n argo-rollouts"
