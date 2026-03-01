#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

header "사전 요구사항 확인"

PASS=true

# Docker
if command -v docker &>/dev/null; then
  DOCKER_VER=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "unknown")
  success "Docker: ${DOCKER_VER}"

  # Memory check
  DOCKER_MEM=$(docker info --format '{{.MemTotal}}' 2>/dev/null | tr -dc '0-9' || echo "0")
  DOCKER_MEM=${DOCKER_MEM:-0}
  DOCKER_MEM_GB=$((DOCKER_MEM / 1073741824))
  if [ "$DOCKER_MEM_GB" -ge 4 ]; then
    success "Docker 메모리: ${DOCKER_MEM_GB}GB"
  else
    warn "Docker 메모리: ${DOCKER_MEM_GB}GB (최소 4GB 필요)"
    info "Docker Desktop > Settings > Resources > Memory 에서 조정"
  fi
else
  error "Docker가 설치되지 않았습니다"
  PASS=false
fi

# kubectl
if command -v kubectl &>/dev/null; then
  KUBECTL_VER=$(kubectl version --client -o json 2>/dev/null | grep -o '"gitVersion":[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4 || echo "unknown")
  success "kubectl: ${KUBECTL_VER}"
else
  error "kubectl이 설치되지 않았습니다"
  info "설치: brew install kubectl"
  PASS=false
fi

# Helm
if command -v helm &>/dev/null; then
  HELM_VER=$(helm version --short 2>/dev/null)
  success "Helm: ${HELM_VER}"
else
  error "Helm이 설치되지 않았습니다"
  info "설치: brew install helm"
  PASS=false
fi

# Kind
if command -v kind &>/dev/null; then
  KIND_VER=$(kind version 2>/dev/null)
  success "Kind: ${KIND_VER}"
else
  error "Kind가 설치되지 않았습니다"
  info "설치: brew install kind"
  PASS=false
fi

# Cilium CLI (optional)
if command -v cilium &>/dev/null; then
  CILIUM_VER=$(cilium version --client 2>/dev/null | head -1)
  success "Cilium CLI: ${CILIUM_VER}"
else
  warn "Cilium CLI 미설치 (선택사항)"
  info "설치: brew install cilium-cli"
fi

# istioctl (optional)
if command -v istioctl &>/dev/null; then
  ISTIO_VER=$(istioctl version --remote=false 2>/dev/null || echo "unknown")
  success "istioctl: ${ISTIO_VER}"
else
  warn "istioctl 미설치 (선택사항)"
  info "설치: brew install istioctl"
fi

# jq
if command -v jq &>/dev/null; then
  success "jq: $(jq --version 2>/dev/null)"
else
  warn "jq 미설치 (일부 검증 스크립트에 필요)"
  info "설치: brew install jq"
fi

echo ""
if [ "$PASS" = true ]; then
  success "모든 필수 도구가 설치되어 있습니다. 실습을 시작하세요!"
else
  error "필수 도구가 누락되었습니다. 위 안내에 따라 설치해주세요."
  exit 1
fi
