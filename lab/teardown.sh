#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/scripts/common.sh"

# Parse arguments
ENV="dev"

while [[ $# -gt 0 ]]; do
  case $1 in
    --env)
      ENV="${2:-dev}"
      if [[ ! "$ENV" =~ ^(dev|stg|live)$ ]]; then
        error "--env must be dev, stg, or live"
        exit 1
      fi
      shift 2
      ;;
    --help|-h)
      echo "Usage: $0 [--env dev|stg|live]"
      exit 0
      ;;
    *) shift ;;
  esac
done

CLUSTER_NAME="lab-${ENV}"

header "K8s Lab 환경 정리 (${CLUSTER_NAME})"

# Confirmation
echo -e "${YELLOW}주의: Kind 클러스터 '${CLUSTER_NAME}'와 모든 리소스가 삭제됩니다.${NC}"
read -r -p "계속하시겠습니까? (y/N): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[yY]$ ]]; then
  info "취소됨"
  exit 0
fi

# Kill port-forwards
info "포트 포워딩 종료..."
pkill -f "kubectl port-forward" 2>/dev/null || true

# Delete Kind cluster
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  info "Kind 클러스터 '${CLUSTER_NAME}' 삭제..."
  kind delete cluster --name "${CLUSTER_NAME}"
  success "클러스터 삭제 완료"
else
  warn "Kind 클러스터 '${CLUSTER_NAME}'가 존재하지 않습니다"
fi

# Clean up kubeconfig context
info "kubeconfig 컨텍스트 정리..."
kubectl config delete-context "kind-${CLUSTER_NAME}" 2>/dev/null || true
kubectl config delete-cluster "kind-${CLUSTER_NAME}" 2>/dev/null || true

success "Lab 환경 정리 완료"
echo ""
info "다시 시작: bash ${SCRIPT_DIR}/setup.sh --env ${ENV}"
