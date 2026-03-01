#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../scripts/common.sh"

header "LGTM Stack 설치 (OTel Collector + Mimir + Loki + Tempo + Alloy + Grafana + AlertManager)"

# 1. Namespace
info "monitoring 네임스페이스 생성..."
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

# 2. Add Helm repos
info "Helm 저장소 추가..."
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo update grafana

# 3. Mimir (Metrics backend)
info "Step 1/7: Mimir 설치 (메트릭 백엔드)..."
# Copy alert/recording rules to Mimir
kubectl create configmap mimir-rules \
  --from-file=alerts.yml="${SCRIPT_DIR}/mimir-rules/alerts.yml" \
  --from-file=recordings.yml="${SCRIPT_DIR}/mimir-rules/recordings.yml" \
  --namespace monitoring \
  --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install mimir grafana/mimir-distributed \
  --namespace monitoring \
  --version 6.0.5 \
  --values "${SCRIPT_DIR}/values-mimir.yaml" \
  --wait --timeout 5m

# 4. Loki (Logs backend)
info "Step 2/7: Loki 설치 (로그 백엔드)..."
helm upgrade --install loki grafana/loki \
  --namespace monitoring \
  --version 6.53.0 \
  --values "${SCRIPT_DIR}/values-loki.yaml" \
  --wait --timeout 5m

# 5. Tempo (Traces backend)
info "Step 3/7: Tempo 설치 (트레이스 백엔드)..."
helm upgrade --install tempo grafana/tempo \
  --namespace monitoring \
  --version 1.24.4 \
  --values "${SCRIPT_DIR}/values-tempo.yaml" \
  --wait --timeout 5m

# 6. AlertManager
info "Step 4/7: AlertManager 설치..."
kubectl create configmap alertmanager-config \
  --from-file=alertmanager.yml="${SCRIPT_DIR}/alertmanager/alertmanager-config.yaml" \
  --namespace monitoring \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f "${SCRIPT_DIR}/alertmanager/deployment.yaml"
kubectl wait --for=condition=ready pod -l app=alertmanager -n monitoring --timeout=120s

# 7. OTel Collector Gateway (production-identical pipeline)
info "Step 5/7: OTel Collector Gateway 설치 (tail_sampling + trace enrichment)..."
kubectl create configmap otel-collector-config \
  --from-file=otel-collector-config.yaml="${SCRIPT_DIR}/otel-collector/otel-collector-config.yaml" \
  --namespace monitoring \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f "${SCRIPT_DIR}/otel-collector/deployment.yaml"
kubectl wait --for=condition=ready pod -l app=otel-collector -n monitoring --timeout=120s

# 8. Alloy (Log/Metric collector - DaemonSet)
info "Step 6/7: Alloy 설치 (로그/메트릭 수집 에이전트)..."
kubectl create configmap alloy-config \
  --from-file=config.alloy="${SCRIPT_DIR}/alloy/config.alloy" \
  --namespace monitoring \
  --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install alloy grafana/alloy \
  --namespace monitoring \
  --version 1.6.0 \
  --values "${SCRIPT_DIR}/values-alloy.yaml" \
  --wait --timeout 5m

# 9. Grafana (Dashboard)
info "Step 7/7: Grafana 설치 (대시보드 + 데이터소스 상관관계 연동)..."
helm upgrade --install grafana grafana/grafana \
  --namespace monitoring \
  --version 10.5.15 \
  --values "${SCRIPT_DIR}/values-grafana.yaml" \
  --wait --timeout 5m

# 10. Summary
GRAFANA_PASS=$(kubectl get secret -n monitoring grafana -o jsonpath="{.data.admin-password}" | base64 -d)
success "LGTM Stack 설치 완료"
echo ""
info "컴포넌트 상태:"
echo "  OTel Collector: tail_sampling (ERROR 100%, slow>2s 100%, normal 10%)"
echo "  Tempo:          metrics_generator (service-graph + span-metrics) → Mimir"
echo "  Loki:           TSDB v13, OTLP native, retention 168h"
echo "  Mimir:          Ruler (alert rules + recording rules) → AlertManager"
echo "  Grafana:        trace↔log↔metrics 상관관계 연동 완료"
echo ""
info "Grafana 접속 정보:"
echo "  URL:      http://grafana.lab-dev.local (Kong Gateway 경유)"
echo "  Username: admin"
echo "  Password: ${GRAFANA_PASS}"
echo ""
info "OTel Collector Endpoint (앱에서 사용):"
echo "  gRPC: otel-collector.monitoring.svc:4317"
echo "  HTTP: otel-collector.monitoring.svc:4318"
