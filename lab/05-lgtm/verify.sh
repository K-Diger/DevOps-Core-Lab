#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../scripts/common.sh"

header "LGTM Stack 검증"

# 1. Pod status
info "monitoring 네임스페이스 Pod 상태..."
kubectl get pods -n monitoring
echo ""

# 2. Mimir
info "Mimir 상태 확인..."
if kubectl get pods -n monitoring -l app.kubernetes.io/name=mimir -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q "Running"; then
  success "Mimir 정상 실행 중"
else
  warn "Mimir가 아직 준비되지 않았습니다"
fi

# 3. Loki
info "Loki 상태 확인..."
if kubectl get pods -n monitoring -l app.kubernetes.io/name=loki -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q "Running"; then
  success "Loki 정상 실행 중"
else
  warn "Loki가 아직 준비되지 않았습니다"
fi

# 4. Tempo
info "Tempo 상태 확인..."
if kubectl get pods -n monitoring -l app.kubernetes.io/name=tempo -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q "Running"; then
  success "Tempo 정상 실행 중"
else
  warn "Tempo가 아직 준비되지 않았습니다"
fi

# 5. Alloy
info "Alloy DaemonSet 상태 확인..."
DESIRED=$(kubectl get daemonset -n monitoring -l app.kubernetes.io/name=alloy -o jsonpath='{.items[0].status.desiredNumberScheduled}' 2>/dev/null || echo "0")
READY=$(kubectl get daemonset -n monitoring -l app.kubernetes.io/name=alloy -o jsonpath='{.items[0].status.numberReady}' 2>/dev/null || echo "0")
if [ "$DESIRED" = "$READY" ] && [ "$DESIRED" != "0" ]; then
  success "Alloy DaemonSet: ${READY}/${DESIRED} 노드 실행 중"
else
  warn "Alloy DaemonSet: ${READY}/${DESIRED} 노드"
fi

# 6. Grafana
info "Grafana 상태 확인..."
if kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q "Running"; then
  success "Grafana 정상 실행 중"
  GRAFANA_PASS=$(kubectl get secret -n monitoring grafana -o jsonpath="{.data.admin-password}" 2>/dev/null | base64 -d || echo "unknown")
  echo "  URL:      http://localhost:3000 (NodePort 30300)"
  echo "  Username: admin"
  echo "  Password: ${GRAFANA_PASS}"
else
  warn "Grafana가 아직 준비되지 않았습니다"
fi

# 7. Datasource connectivity test
info "Grafana 데이터소스 연결 테스트..."
GRAFANA_POD=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "$GRAFANA_POD" ]; then
  for ds in mimir loki tempo; do
    if kubectl exec -n monitoring "$GRAFANA_POD" -- wget -qO- "http://localhost:3000/api/datasources/uid/${ds}" 2>/dev/null | grep -q "\"uid\""; then
      success "  ${ds} 데이터소스 등록 확인"
    else
      warn "  ${ds} 데이터소스 미확인"
    fi
  done
fi

echo ""
success "LGTM Stack 검증 완료"
