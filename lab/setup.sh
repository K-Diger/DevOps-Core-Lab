#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/scripts/common.sh"

# Parse arguments
LIGHT_PROFILE=false
SKIP_LGTM=false
SKIP_ISTIO=false
ENV="dev"

while [[ $# -gt 0 ]]; do
  case $1 in
    --light)      LIGHT_PROFILE=true; shift ;;
    --skip-lgtm)  SKIP_LGTM=true; shift ;;
    --skip-istio) SKIP_ISTIO=true; shift ;;
    --env)
      ENV="${2:-dev}"
      if [[ ! "$ENV" =~ ^(dev|stg|live)$ ]]; then
        error "--env must be dev, stg, or live"
        exit 1
      fi
      shift 2
      ;;
    --help|-h)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --env ENV     환경 선택: dev|stg|live (기본값: dev)"
      echo "  --light       경량 프로필 (16GB 이하 머신용, worker 1개)"
      echo "  --skip-lgtm   LGTM 스택 설치 생략"
      echo "  --skip-istio  Istio 설치 생략"
      echo "  -h, --help    도움말"
      exit 0
      ;;
    *) error "Unknown option: $1"; exit 1 ;;
  esac
done

CLUSTER_NAME="lab-${ENV}"

header "K8s Lab 환경 전체 설치 (env: ${ENV}, cluster: ${CLUSTER_NAME})"

START_TIME=$(date +%s)

# 0. Prerequisites
info "사전 요구사항 확인..."
bash "${SCRIPT_DIR}/scripts/check-prerequisites.sh"
echo ""

# 1. Cluster
info "Step 1/9: Kind 클러스터 생성 (${CLUSTER_NAME})..."
CLUSTER_ARGS="--env ${ENV}"
if [ "$LIGHT_PROFILE" = true ]; then
  CLUSTER_ARGS="${CLUSTER_ARGS} --light"
fi
bash "${SCRIPT_DIR}/cluster/setup-cluster.sh" ${CLUSTER_ARGS}
echo ""

# 2. Cilium CNI
info "Step 2/9: Cilium CNI 설치..."
bash "${SCRIPT_DIR}/01-cilium/install.sh" "${CLUSTER_NAME}"
echo ""

# 3. Kong Ingress Controller + Gateway API
info "Step 3/9: Kong Ingress Controller + Gateway API 설치..."
bash "${SCRIPT_DIR}/08-kong/install.sh"
echo ""

# 4. Istio (optional)
if [ "$SKIP_ISTIO" = true ]; then
  warn "Step 4/9: Istio 설치 생략 (--skip-istio)"
else
  info "Step 4/9: Istio Ambient 설치..."
  bash "${SCRIPT_DIR}/02-istio/install.sh"
fi
echo ""

# 5. ArgoCD
info "Step 5/9: ArgoCD 설치..."
bash "${SCRIPT_DIR}/03-argocd/install.sh"
echo ""

# 6. Gatekeeper
info "Step 6/9: Gatekeeper 설치..."
bash "${SCRIPT_DIR}/04-gatekeeper/install.sh"
echo ""

# 7. LGTM (optional)
if [ "$SKIP_LGTM" = true ]; then
  warn "Step 7/9: LGTM Stack 설치 생략 (--skip-lgtm)"
else
  info "Step 7/9: LGTM Stack 설치 (OTel Collector + Mimir + Loki + Tempo + Alloy + Grafana + AlertManager)..."
  bash "${SCRIPT_DIR}/05-lgtm/install.sh"
fi
echo ""

# 8. Demo App (namespace must exist before platform resources)
info "Step 8/9: 데모 애플리케이션 배포..."
bash "${SCRIPT_DIR}/06-demo-app/deploy.sh"
echo ""

# 9. Platform Resources (ResourceQuota, LimitRange, PDB → demo namespace)
info "Step 9/9: 플랫폼 리소스 적용 (PriorityClass, ResourceQuota, LimitRange, PDB)..."
kubectl apply -f "${SCRIPT_DIR}/07-platform/namespace.yaml"
echo ""

# Re-apply Istio AuthorizationPolicy (demo namespace now exists)
if [ "$SKIP_ISTIO" != true ]; then
  info "Istio AuthorizationPolicy 재적용 (demo namespace 생성 완료)..."
  kubectl apply -f "${SCRIPT_DIR}/02-istio/policies/authz-policy.yaml"
fi

# Re-apply Kong HTTPRoutes (namespaces now exist)
info "Kong HTTPRoutes 재적용 (모든 namespace 생성 완료)..."
for ROUTE in "${SCRIPT_DIR}"/08-kong/routes/*.yaml; do
  kubectl apply -f "$ROUTE" 2>/dev/null || true
done
echo ""

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

header "설치 완료"
success "전체 설치 시간: $((ELAPSED / 60))분 $((ELAPSED % 60))초"
echo ""
info "접속 정보 (Kong Gateway 경유):"
echo "  Grafana:   http://grafana.lab-${ENV}.local"
echo "  ArgoCD:    https://argocd.lab-${ENV}.local"
echo "  Hubble UI: http://hubble.lab-${ENV}.local"
echo "  Demo API:  http://api.lab-${ENV}.local"
echo ""
info "/etc/hosts 설정 필요:"
echo "  127.0.0.1 grafana.lab-${ENV}.local argocd.lab-${ENV}.local hubble.lab-${ENV}.local api.lab-${ENV}.local"
echo ""
info "운영 환경 동일 구성:"
echo "  Kong Gateway:   Gateway API HTTPRoute 기반 트래픽 라우팅"
echo "  OTel Collector: tail_sampling (ERROR 100%, slow>2s 100%, normal 10%)"
echo "  Tempo:          metrics_generator (service-graph, span-metrics) → Mimir"
echo "  Loki:           TSDB v13, OTLP native, retention 168h, limits 동일"
echo "  Mimir:          Ruler (alert + recording rules) → AlertManager"
echo "  Grafana:        trace↔log↔metrics 상관관계 연동 완료"
echo "  Gatekeeper:     auditInterval=60s, auditFromCache=true"
echo "  Platform:       ResourceQuota, LimitRange, PDB, PriorityClass"
echo ""
info "포트 포워딩 (Kong 불가 시 fallback): bash ${SCRIPT_DIR}/scripts/port-forward-all.sh"
info "전체 검증:   bash ${SCRIPT_DIR}/verify-all.sh"
info "환경 정리:   bash ${SCRIPT_DIR}/teardown.sh --env ${ENV}"
