#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../scripts/common.sh"

header "Gatekeeper 검증"

# 1. Pod status
info "Gatekeeper Pod 상태 확인..."
kubectl get pods -n gatekeeper-system
echo ""

# 2. ConstraintTemplate
info "ConstraintTemplate 목록:"
kubectl get constrainttemplates
echo ""

# 3. Constraints
info "Constraint 목록:"
for crd in k8srequireresourcelimits k8sdenyprivileged k8srequirenonroot k8srequirelabels; do
  if kubectl get crd "${crd}.constraints.gatekeeper.sh" &>/dev/null; then
    kubectl get "$crd" 2>/dev/null || true
  fi
done
echo ""

# 4. Test: privileged container (should be denied)
info "정책 테스트: privileged 컨테이너 (거부 예상)..."
if kubectl apply --dry-run=server -f - <<'EOF' 2>&1 | grep -q "denied"; then
apiVersion: v1
kind: Pod
metadata:
  name: test-privileged
  namespace: demo
  labels:
    app: test
    env: dev
    team: platform
spec:
  securityContext:
    runAsNonRoot: true
  containers:
    - name: test
      image: nginx:alpine
      securityContext:
        privileged: true
      resources:
        limits:
          cpu: 100m
          memory: 128Mi
        requests:
          cpu: 50m
          memory: 64Mi
EOF
  success "privileged 컨테이너 정상 거부됨"
else
  warn "privileged 컨테이너 거부 실패 (정책 미적용 가능)"
fi

# 5. Test: missing labels (should be denied)
info "정책 테스트: 필수 라벨 누락 (거부 예상)..."
if kubectl apply --dry-run=server -f - <<'EOF' 2>&1 | grep -q "denied"; then
apiVersion: v1
kind: Pod
metadata:
  name: test-no-labels
  namespace: demo
spec:
  securityContext:
    runAsNonRoot: true
  containers:
    - name: test
      image: nginx:alpine
      resources:
        limits:
          cpu: 100m
          memory: 128Mi
        requests:
          cpu: 50m
          memory: 64Mi
EOF
  success "라벨 누락 정상 거부됨"
else
  warn "라벨 누락 거부 실패 (정책 미적용 가능)"
fi

# 6. Audit violations
info "감사(Audit) 위반 목록:"
kubectl get k8srequireresourcelimits -o json 2>/dev/null | jq -r '.items[].status.violations[]? // empty' || echo "  (위반 없음)"

success "Gatekeeper 검증 완료"
