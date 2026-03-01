#!/bin/bash
# Common utilities for lab scripts

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

header() { echo -e "\n${CYAN}========================================${NC}"; echo -e "${CYAN} $1${NC}"; echo -e "${CYAN}========================================${NC}\n"; }
info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; }

wait_for_pods() {
  local namespace=$1
  local label=$2
  local timeout=${3:-120}
  info "${namespace}/${label} Pod 준비 대기 (최대 ${timeout}s)..."
  if kubectl wait --for=condition=ready pod -l "$label" -n "$namespace" --timeout="${timeout}s" 2>/dev/null; then
    success "Pod 준비 완료"
  else
    warn "일부 Pod가 아직 준비되지 않았습니다"
    kubectl get pods -n "$namespace" -l "$label"
  fi
}
