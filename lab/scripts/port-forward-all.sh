#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

header "포트 포워딩 (Kong Gateway 불가 시 fallback)"
warn "Kong Gateway 경유 접속이 권장됩니다. 이 스크립트는 fallback용입니다."
echo ""

# Kill existing port-forwards
info "기존 포트 포워딩 종료..."
pkill -f "kubectl port-forward" 2>/dev/null || true
sleep 1

# Grafana
if kubectl get svc -n monitoring grafana &>/dev/null; then
  info "Grafana → localhost:3000"
  kubectl port-forward -n monitoring svc/grafana 3000:80 &>/dev/null &
fi

# ArgoCD
if kubectl get svc -n argocd argocd-server &>/dev/null; then
  info "ArgoCD → localhost:8080"
  kubectl port-forward -n argocd svc/argocd-server 8080:443 &>/dev/null &
fi

# Hubble UI
if kubectl get svc -n kube-system hubble-ui &>/dev/null; then
  info "Hubble UI → localhost:12000"
  kubectl port-forward -n kube-system svc/hubble-ui 12000:80 &>/dev/null &
fi

# Hubble Relay
if kubectl get svc -n kube-system hubble-relay &>/dev/null; then
  info "Hubble Relay → localhost:4245"
  kubectl port-forward -n kube-system svc/hubble-relay 4245:80 &>/dev/null &
fi

echo ""
success "포트 포워딩 시작됨 (fallback 모드)"
echo ""
echo "  Grafana:     http://localhost:3000"
echo "  ArgoCD:      https://localhost:8080"
echo "  Hubble UI:   http://localhost:12000"
echo ""
warn "권장: Kong Gateway 경유 접속"
echo "  Grafana:     http://grafana.lab-dev.local"
echo "  ArgoCD:      https://argocd.lab-dev.local"
echo "  Hubble UI:   http://hubble.lab-dev.local"
echo "  Demo API:    http://api.lab-dev.local"
echo ""
info "종료: pkill -f 'kubectl port-forward'"
echo ""

# Wait for user interrupt
wait
