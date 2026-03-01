#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../scripts/common.sh"

header "데모 애플리케이션 배포"

# 1. Namespace
info "demo 네임스페이스 생성..."
kubectl apply -f "${SCRIPT_DIR}/namespace.yaml"

# 2. Backend
info "Backend (httpbin) 배포..."
kubectl apply -f "${SCRIPT_DIR}/backend/deployment.yaml"

# 3. Frontend
info "Frontend (curl client) 배포..."
kubectl apply -f "${SCRIPT_DIR}/frontend/deployment.yaml"

# 4. Wait for ready
info "Pod 준비 대기..."
kubectl wait --for=condition=ready pod -l app=backend -n demo --timeout=120s
kubectl wait --for=condition=ready pod -l app=frontend -n demo --timeout=120s

success "데모 애플리케이션 배포 완료"
echo ""
info "테스트 명령어:"
echo "  # Frontend에서 Backend 호출"
echo "  kubectl exec -n demo deploy/frontend -- curl -s http://backend.demo.svc/get"
echo ""
echo "  # 트래픽 부하 생성 (Grafana에서 확인)"
echo "  kubectl apply -f ${SCRIPT_DIR}/load-generator/job.yaml"
