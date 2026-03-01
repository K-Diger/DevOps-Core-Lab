# K8s Lab - 로컬 실습 환경

Kubernetes 핸즈온 실습 환경.
Kind(Kubernetes in Docker)로 운영 환경과 동일한 스택을 로컬에서 실습한다.

## 아키텍처

```
Kind Cluster (3 nodes: 1 CP + 2 Worker)
├── Cilium CNI       ← L3/L4 네트워크 정책, kube-proxy 대체, Hubble 가시성
├── Istio Ambient    ← L7 mTLS, AuthorizationPolicy (사이드카 없음)
├── ArgoCD           ← GitOps 배포 (자동 동기화, selfHeal)
├── Gatekeeper       ← OPA 정책 (리소스제한, 권한컨테이너차단, 필수라벨)
├── LGTM Stack       ← Mimir(메트릭) + Loki(로그) + Tempo(트레이스) + Grafana
│   └── Alloy        ← 텔레메트리 수집 에이전트 (DaemonSet)
└── Demo App         ← Backend(httpbin) + Frontend(curl) + LoadGenerator
```

## Production 매핑

| Lab 컴포넌트        | Production 대응   | 비고                           |
|-----------------|-----------------|------------------------------|
| Kind cluster    | kubeadm 클러스터    | Air-gap, 3 master + N worker |
| Cilium CNI      | Cilium CNI      | 동일 설정, WireGuard 암호화         |
| Istio Ambient   | Istio Ambient   | 동일 (ztunnel 기반 mTLS)         |
| ArgoCD          | ArgoCD          | ApplicationSet 사용            |
| Gatekeeper      | Gatekeeper      | 동일 정책 + 추가 프로덕션 정책           |
| LGTM (단일)       | LGTM (분산)       | 프로덕션은 S3/분산 모드               |
| Alloy DaemonSet | Alloy DaemonSet | 동일 구조                        |

## 빠른 시작

```bash
# 1. 사전 요구사항 확인
bash scripts/check-prerequisites.sh

# 2. 전체 설치 (약 10-15분)
bash setup.sh

# 3. 경량 모드 (16GB 이하 머신)
bash setup.sh --light

# 4. 선택적 설치
bash setup.sh --skip-istio          # Istio 제외
bash setup.sh --skip-lgtm           # LGTM 제외
bash setup.sh --light --skip-istio  # 최소 설치
```

## 필수 도구

| 도구             | 최소 버전 | 설치                           |
|----------------|-------|------------------------------|
| Docker Desktop | 4.x   | brew install --cask docker   |
| kubectl        | 1.28+ | brew install kubectl         |
| Helm           | 3.12+ | brew install helm            |
| Kind           | 0.20+ | brew install kind            |
| Cilium CLI     | 0.15+ | brew install cilium-cli (선택) |
| istioctl       | 1.22+ | brew install istioctl (선택)   |
| jq             | 1.6+  | brew install jq (선택)         |

**시스템 요구사항**: Docker Desktop 메모리 8GB 이상 (16GB 권장)

## 디렉토리 구조

```
lab/
├── setup.sh                    # 전체 설치 (원샷)
├── teardown.sh                 # 전체 정리
├── verify-all.sh               # 전체 검증
├── README.md
├── cluster/
│   ├── kind-config.yaml        # Kind 3노드 클러스터 설정
│   └── setup-cluster.sh        # 클러스터 생성
├── 01-cilium/
│   ├── install.sh              # Cilium + Hubble 설치
│   ├── values.yaml             # Helm values (운영 동일 설정)
│   ├── verify.sh               # 검증
│   └── policies/               # CiliumNetworkPolicy 예제
├── 02-istio/
│   ├── install.sh              # Istio Ambient 설치 (3단계)
│   ├── values-base.yaml        # Base CRD
│   ├── values-istiod.yaml      # istiod + CNI
│   ├── values-cni.yaml         # CNI chaining
│   ├── values-ztunnel.yaml     # ztunnel
│   ├── verify.sh               # 검증
│   └── policies/               # PeerAuth, AuthzPolicy, Telemetry
├── 03-argocd/
│   ├── install.sh              # ArgoCD 설치
│   ├── values.yaml             # Helm values
│   ├── verify.sh               # 검증
│   └── apps/demo-app/          # 샘플 Helm chart (ArgoCD Application)
├── 04-gatekeeper/
│   ├── install.sh              # Gatekeeper + 정책 적용
│   ├── values.yaml             # Helm values
│   ├── verify.sh               # 검증 (정책 테스트 포함)
│   └── policies/               # 4개 OPA 정책
│       ├── require-resource-limits/
│       ├── deny-privileged-container/
│       ├── require-non-root/
│       └── require-labels/
├── 05-lgtm/
│   ├── install.sh              # LGTM 전체 설치
│   ├── values-grafana.yaml     # 사전구성 데이터소스 + 대시보드
│   ├── values-mimir.yaml       # 메트릭 백엔드
│   ├── values-loki.yaml        # 로그 백엔드
│   ├── values-tempo.yaml       # 트레이스 백엔드
│   ├── values-alloy.yaml       # 수집 에이전트
│   ├── alloy/config.alloy      # Alloy 파이프라인 설정
│   └── verify.sh               # 검증
├── 06-demo-app/
│   ├── deploy.sh               # 데모 앱 배포
│   ├── namespace.yaml          # demo 네임스페이스 (Istio ambient 라벨)
│   ├── backend/deployment.yaml # httpbin (Gatekeeper 정책 준수)
│   ├── frontend/deployment.yaml# curl 클라이언트
│   └── load-generator/job.yaml # 부하 생성 Job
└── scripts/
    ├── common.sh               # 공통 유틸리티 (색상, 로깅)
    ├── check-prerequisites.sh  # 사전 도구 확인
    ├── port-forward-all.sh     # 포트 포워딩 일괄
    └── resource-check.sh       # 리소스 사용량 확인
```

## 실습 가이드

### Lab 1: Cilium 네트워크 정책

```bash
# Cilium 상태 확인
cilium status
cilium connectivity test

# Hubble로 트래픽 관찰
hubble observe --namespace demo

# 네트워크 정책 적용
kubectl apply -f 01-cilium/policies/deny-external-egress.yaml
kubectl exec -n demo deploy/frontend -- curl -s --max-time 3 https://httpbin.org/get
# → 타임아웃 (외부 트래픽 차단됨)
```

### Lab 2: Istio mTLS 검증

```bash
# mTLS 상태 확인
istioctl x describe pod -n demo $(kubectl get pod -n demo -l app=backend -o name | head -1)

# AuthorizationPolicy 테스트
kubectl exec -n demo deploy/frontend -- curl -s http://backend.demo.svc/get
# → 200 OK (frontend SA 허용)
```

### Lab 3: ArgoCD GitOps

```bash
# ArgoCD 접속
ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
echo "Password: ${ARGOCD_PASS}"
# https://localhost:8080 에서 로그인

# Application 동기화 확인
kubectl get applications -n argocd
```

### Lab 4: Gatekeeper 정책

```bash
# 정책 위반 테스트
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: bad-pod
  namespace: demo
spec:
  containers:
  - name: bad
    image: nginx
    securityContext:
      privileged: true
EOF
# → Error: privileged 컨테이너 거부됨

# 감사 결과 확인
kubectl get k8srequireresourcelimits -o yaml | grep -A5 violations
```

### Lab 5: LGTM 옵저빌리티

```bash
# 부하 생성
kubectl apply -f 06-demo-app/load-generator/job.yaml

# Grafana 접속 (http://localhost:3000, admin/패스워드)
# → Explore > Loki: {namespace="demo"} 로그 조회
# → Explore > Tempo: demo 네임스페이스 트레이스 검색
# → Dashboards > Kubernetes Overview
```

## 문제 해결

| 증상              | 원인            | 해결                                                   |
|-----------------|---------------|------------------------------------------------------|
| Pod Pending     | 리소스 부족        | `bash scripts/resource-check.sh` 확인, `--light` 모드 사용 |
| Cilium NotReady | eBPF 마운트 누락   | `docker exec` 로 Kind 노드 진입 후 `/sys/fs/bpf` 확인        |
| Istio 설치 실패     | Cilium CNI 충돌 | `cni.exclusive: false` 확인                            |
| Grafana 데이터 없음  | Alloy 미실행     | `kubectl get ds -n monitoring` 확인                    |
| ArgoCD 접속 불가    | 포트 포워딩        | `bash scripts/port-forward-all.sh` 실행                |

## 관련 문서

- [K8s 생태계 기술 선택 가이드](../../docs/kubernetes/06-kubernetes-ecosystem-guide.md)
- [로컬 실습 상세 가이드](../../docs/kubernetes/07-local-practice-guide.md)
- [마이그레이션 개요](../../docs/kubernetes/01-migration-overview.md)
- [K8s 인프라 스크립트](../README.md)
