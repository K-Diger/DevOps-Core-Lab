#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/scripts/common.sh"

header "K8s Lab 전체 검증"

TOTAL=0
PASSED=0

check() {
  TOTAL=$((TOTAL + 1))
  # set +o pipefail: grep -q closes stdin early → SIGPIPE to upstream → pipeline fails with pipefail
  if (set +o pipefail; eval "$1") &>/dev/null; then
    success "$2"
    PASSED=$((PASSED + 1))
  else
    error "$2"
  fi
}

# Cluster
info "=== 클러스터 ==="
check "kubectl cluster-info" "클러스터 접근 가능"
EXPECTED_NODES=$(kubectl get nodes --no-headers | wc -l | tr -d ' ')
check "kubectl get nodes --no-headers | grep -c Ready | grep -q ${EXPECTED_NODES}" "노드 ${EXPECTED_NODES}개 Ready"
echo ""

# Cilium
info "=== Cilium CNI ==="
check "kubectl get pods -n kube-system -l app.kubernetes.io/name=cilium-agent --no-headers | grep -c Running | grep -qv 0" "Cilium Agent 실행 중"
check "kubectl get pods -n kube-system -l app.kubernetes.io/name=cilium-operator --no-headers | grep -q Running" "Cilium Operator 실행 중"
check "kubectl get pods -n kube-system -l app.kubernetes.io/name=hubble-ui --no-headers | grep -q Running" "Hubble UI 실행 중"
echo ""

# Kong Gateway
info "=== Kong Gateway ==="
check "kubectl get pods -n kong -l app.kubernetes.io/instance=kong --no-headers | grep -q Running" "Kong Ingress Controller 실행 중"
check "kubectl get gateway -n kong kong-gateway -o jsonpath='{.status.conditions[?(@.type==\"Accepted\")].status}' | grep -q True" "Gateway 리소스 Accepted"
check "kubectl get httproutes --all-namespaces --no-headers 2>/dev/null | wc -l | grep -qv 0" "HTTPRoute 등록됨"
# Kong → Backend connectivity test (North-South)
check "kubectl exec -n demo deploy/frontend -- curl -sf -H 'Host: api.lab-dev.local' http://kong-gateway-proxy.kong.svc/status/200" "Kong → Backend N-S 라우팅 정상"
echo ""

# Istio
info "=== Istio Ambient ==="
if kubectl get namespace istio-system &>/dev/null; then
  check "kubectl get pods -n istio-system -l app=istiod --no-headers | grep -q Running" "istiod 실행 중"
  check "kubectl get pods -n istio-system -l app=ztunnel --no-headers | grep -c Running | grep -qv 0" "ztunnel 실행 중"
  check "kubectl get peerauthentication -n istio-system --no-headers 2>/dev/null | grep -q STRICT" "mTLS STRICT 설정됨"
else
  warn "Istio 미설치 (생략)"
fi
echo ""

# ArgoCD
info "=== ArgoCD ==="
check "kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-server --no-headers | grep -q Running" "ArgoCD Server 실행 중"
check "kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-repo-server --no-headers | grep -q Running" "Repo Server 실행 중"
check "kubectl get svc -n argocd argocd-server -o jsonpath='{.spec.type}' | grep -q ClusterIP" "ArgoCD Service: ClusterIP (Kong 경유)"
echo ""

# Gatekeeper
info "=== Gatekeeper ==="
check "kubectl get pods -n gatekeeper-system --no-headers | grep -c Running | grep -qv 0" "Gatekeeper 실행 중"
check "kubectl get constrainttemplates --no-headers 2>/dev/null | wc -l | grep -qv 0" "ConstraintTemplate 등록됨"
echo ""

# LGTM
info "=== LGTM Stack ==="
if kubectl get namespace monitoring &>/dev/null; then
  check "kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana --no-headers | grep -q Running" "Grafana 실행 중"
  check "kubectl get svc -n monitoring grafana -o jsonpath='{.spec.type}' | grep -q ClusterIP" "Grafana Service: ClusterIP (Kong 경유)"
  check "kubectl get pods -n monitoring -l app.kubernetes.io/name=loki --no-headers | grep -q Running" "Loki 실행 중"
  check "kubectl get pods -n monitoring -l app.kubernetes.io/name=tempo --no-headers | grep -q Running" "Tempo 실행 중"
  check "kubectl get pods -n monitoring -l app.kubernetes.io/name=alloy --no-headers | grep -c Running | grep -qv 0" "Alloy 실행 중"
else
  warn "LGTM 미설치 (생략)"
fi
echo ""

# Demo App
info "=== 데모 애플리케이션 ==="
check "kubectl get pods -n demo -l app=backend --no-headers | grep -q Running" "Backend 실행 중"
check "kubectl get pods -n demo -l app=frontend --no-headers | grep -q Running" "Frontend 실행 중"
# E-W connectivity test
check "kubectl exec -n demo deploy/frontend -- curl -sf http://backend.demo.svc/status/200" "Frontend → Backend E-W 통신 정상"
echo ""

# Summary
header "검증 결과"
echo -e "  통과: ${GREEN}${PASSED}${NC} / 전체: ${TOTAL}"
echo ""
if [ "$PASSED" -eq "$TOTAL" ]; then
  success "모든 검증 통과! Lab 환경이 정상입니다."
else
  FAILED=$((TOTAL - PASSED))
  warn "${FAILED}개 항목이 실패했습니다. 개별 verify.sh로 상세 확인하세요."
fi
