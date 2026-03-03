#!/usr/bin/env bash
set -euo pipefail

echo "=== Monitoring Extras Installation ==="

# 1. metrics-server (for HPA/VPA)
echo "[INFO] Step 1/4: Installing metrics-server..."
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ 2>/dev/null || true
helm repo update metrics-server

helm upgrade --install metrics-server metrics-server/metrics-server \
  --namespace kube-system \
  --set args[0]="--kubelet-insecure-tls" \
  --set resources.requests.cpu=50m \
  --set resources.requests.memory=64Mi \
  --set resources.limits.cpu=200m \
  --set resources.limits.memory=128Mi \
  --wait --timeout 3m

echo "[OK] metrics-server installed"

# 2. kube-state-metrics (cluster state → Prometheus metrics)
echo "[INFO] Step 2/4: Installing kube-state-metrics..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo update prometheus-community

helm upgrade --install kube-state-metrics prometheus-community/kube-state-metrics \
  --namespace monitoring \
  --set resources.requests.cpu=50m \
  --set resources.requests.memory=64Mi \
  --set resources.limits.cpu=200m \
  --set resources.limits.memory=128Mi \
  --wait --timeout 3m

echo "[OK] kube-state-metrics installed"

# 3. node-exporter (node metrics)
echo "[INFO] Step 3/4: Installing node-exporter..."
helm upgrade --install node-exporter prometheus-community/prometheus-node-exporter \
  --namespace monitoring \
  --set resources.requests.cpu=50m \
  --set resources.requests.memory=32Mi \
  --set resources.limits.cpu=100m \
  --set resources.limits.memory=64Mi \
  --wait --timeout 3m

echo "[OK] node-exporter installed"

# 4. Reloader (auto-restart on ConfigMap/Secret changes)
echo "[INFO] Step 4/4: Installing Reloader..."
helm repo add stakater https://stakater.github.io/stakater-charts 2>/dev/null || true
helm repo update stakater

helm upgrade --install reloader stakater/reloader \
  --namespace monitoring \
  --set reloader.watchGlobally=true \
  --set resources.requests.cpu=50m \
  --set resources.requests.memory=64Mi \
  --set resources.limits.cpu=100m \
  --set resources.limits.memory=128Mi \
  --wait --timeout 3m

echo "[OK] Reloader installed"

echo ""
echo "=== Verification ==="
echo "[INFO] metrics-server:"
kubectl top nodes 2>/dev/null || echo "  (needs ~60s to collect initial metrics)"
echo ""
echo "[INFO] kube-state-metrics:"
kubectl get pods -n monitoring -l app.kubernetes.io/name=kube-state-metrics -o wide
echo ""
echo "[INFO] node-exporter:"
kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus-node-exporter -o wide
echo ""
echo "[INFO] reloader:"
kubectl get pods -n monitoring -l app=reloader-reloader -o wide

echo ""
echo "[OK] All monitoring extras installed."
