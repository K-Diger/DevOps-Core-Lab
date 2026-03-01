#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

header "클러스터 리소스 사용량"

# Node resources
info "노드별 리소스 사용량:"
kubectl top nodes 2>/dev/null || warn "metrics-server가 설치되지 않았습니다 (kubectl top 사용 불가)"
echo ""

# Namespace resource summary
info "네임스페이스별 Pod 수:"
for ns in kube-system cilium-system istio-system argocd gatekeeper-system monitoring demo; do
  COUNT=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  RUNNING=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | grep -c "Running" || echo "0")
  if [ "$COUNT" -gt 0 ]; then
    echo "  ${ns}: ${RUNNING}/${COUNT} Running"
  fi
done
echo ""

# Pod resource usage
info "Pod별 리소스 사용량 (상위 10개):"
kubectl top pods -A --sort-by=memory 2>/dev/null | head -11 || warn "metrics-server 필요"
echo ""

# PVC usage
info "PersistentVolumeClaim 현황:"
kubectl get pvc -A --no-headers 2>/dev/null | while read -r ns name status vol capacity access sc age; do
  echo "  ${ns}/${name}: ${status} (${capacity})"
done
if [ "$(kubectl get pvc -A --no-headers 2>/dev/null | wc -l)" -eq 0 ]; then
  echo "  (PVC 없음)"
fi
echo ""

# Total resource requests
info "전체 리소스 요청량:"
CPU_REQ=$(kubectl get pods -A -o jsonpath='{.items[*].spec.containers[*].resources.requests.cpu}' 2>/dev/null | tr ' ' '\n' | grep -v '^$' | sed 's/m$//' | awk '{s+=$1} END {printf "%.0f", s}')
MEM_REQ=$(kubectl get pods -A -o jsonpath='{.items[*].spec.containers[*].resources.requests.memory}' 2>/dev/null | tr ' ' '\n' | grep -v '^$' | sed 's/Mi$//' | sed 's/Gi$/\*1024/' | bc 2>/dev/null | awk '{s+=$1} END {printf "%.0f", s}')
echo "  CPU 요청: ${CPU_REQ:-0}m"
echo "  메모리 요청: ${MEM_REQ:-0}Mi"

echo ""
success "리소스 확인 완료"
