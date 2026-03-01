# Istio Ambient Mode 실습 가이드

> **목적**: Istio Ambient Mode의 핵심 기능(mTLS, AuthorizationPolicy, 텔레메트리)을 직접 확인하고, "왜 Ambient Mode인가?"를 동작 원리 수준에서 설명할
> 수 있도록 한다.

---

## 목차

1. [사전 준비](#1-사전-준비)
2. [Lab 1: mTLS 동작 확인 (tcpdump)](#2-lab-1-mtls-동작-확인)
3. [Lab 2: PeerAuthentication STRICT 효과](#3-lab-2-peerauthentication-strict-효과)
4. [Lab 3: AuthorizationPolicy 접근 제어](#4-lab-3-authorizationpolicy-접근-제어)
5. [Lab 4: Ambient vs Sidecar 리소스 비교](#5-lab-4-ambient-vs-sidecar-리소스-비교)
6. [Lab 5: ztunnel 로그에서 HBONE 터널 확인](#6-lab-5-ztunnel-로그에서-hbone-터널-확인)
7. [Q&A 종합](#7-qa-종합)

---

## 1. 사전 준비

### 클러스터 및 Istio 설치

```bash
# Istio Ambient Mode 설치 (base → cni → istiod → ztunnel 순서)
./install.sh

# 설치 검증
./verify.sh
```

### 테스트용 워크로드 확인

```bash
# setup.sh가 demo 네임스페이스에 frontend / backend를 이미 배포함
# demo 네임스페이스에는 ambient 라벨이 적용되어 ztunnel이 mTLS를 자동 처리
kubectl get pods -n demo
# → frontend, backend 모두 Running 확인

# 기본 연결 테스트
kubectl exec -n demo deploy/frontend -- curl -s -o /dev/null -w "%{http_code}" http://backend.demo/status/200
# → 200
```

---

## 2. Lab 1: mTLS 동작 확인

### 목표

ztunnel 로그를 통해 Pod 간 mTLS 암호화가 실제로 적용되는지 확인한다.

### 동작 원리

```
[frontend Pod] → [ztunnel (source)] ==mTLS/HBONE==> [ztunnel (dest)] → [backend Pod]
                  포트 15008에서                      포트 15008에서
                  TLS origination                     TLS termination
```

Ambient Mode에서 mTLS 흐름:

1. frontend Pod이 backend:80으로 평문 요청 전송
2. 같은 노드의 ztunnel이 트래픽을 인터셉트 (CNI가 리다이렉트)
3. ztunnel이 대상 노드의 ztunnel과 HBONE(mTLS + HTTP/2 CONNECT) 연결
4. 대상 ztunnel이 TLS를 종료하고 평문으로 backend Pod에 전달

### 실습 단계

```bash
# 1. 트래픽 생성
kubectl exec -n demo deploy/frontend -- curl -s -o /dev/null -w "%{http_code}" http://backend.demo/get
# → 200

# 2. ztunnel 로그에서 mTLS 연결 확인 (outbound: source ztunnel)
echo "=== Outbound 연결 (source → destination HBONE 터널) ==="
kubectl logs -n istio-system -l app=ztunnel --tail=50 | grep "outbound" | tail -5
# → src.identity="spiffe://cluster.local/ns/demo/sa/frontend" 포함

# 3. ztunnel 로그에서 mTLS 연결 확인 (inbound: destination ztunnel)
echo "=== Inbound 연결 (HBONE 터널에서 backend로 전달) ==="
kubectl logs -n istio-system -l app=ztunnel --tail=50 | grep "inbound" | tail -5
# → dst 주소와 SPIFFE identity가 로그에 표시됨

# 4. SPIFFE ID 기반 인증 확인
echo "=== SPIFFE ID ==="
kubectl logs -n istio-system -l app=ztunnel --tail=100 | grep -i "spiffe" | tail -5
# → spiffe://cluster.local/ns/demo/sa/frontend 형태의 ID 확인
```

### 검증 포인트

```bash
# HBONE 포트(15008) 연결이 ztunnel 로그에 기록되는지 확인
kubectl logs -n istio-system -l app=ztunnel --tail=50 | grep "15008"

# mTLS 없이 직접 연결 시도 (mesh 외부에서) — 거부 확인
# → Lab 2에서 상세 테스트
```

### 핵심 Q&A

> **Q: "Ambient Mode에서 mTLS는 누가 처리하나요?"**
>
> A: 각 노드의 ztunnel DaemonSet이 처리한다. Sidecar Mode에서는 Pod마다 Envoy가 mTLS를 수행하지만, Ambient Mode에서는 노드당 하나의 ztunnel이 해당 노드의
> 모든 Pod에 대한 mTLS를 담당한다. ztunnel은 Rust로 구현되어 Envoy보다 가볍고(~10MB vs ~50MB), istiod로부터 SPIFFE 인증서를 발급받아 자동으로 로테이션한다.

> **Q: "mTLS 인증서는 어떻게 관리되나요?"**
>
> A: istiod가 내장 CA로 동작하여 각 ztunnel에 SPIFFE X.509 인증서를 발급한다. 기본 24시간 주기로 자동 로테이션되며, 인증서의 SAN(Subject Alternative Name)에는
`spiffe://cluster.local/ns/<namespace>/sa/<service-account>` 형식의 SPIFFE ID가 포함된다. 프로덕션에서는 cert-manager나 Vault와 연동하여 외부
> CA를 사용할 수도 있다.

---

## 3. Lab 2: PeerAuthentication STRICT 효과

### 목표

STRICT mTLS 모드에서 mesh 외부의 평문 트래픽이 거부되는 것을 확인한다.

### 실습 단계

```bash
# 1. 현재 PeerAuthentication 확인
kubectl get peerauthentication -n istio-system default -o yaml

# 2. mesh 내부에서 요청 (성공해야 함 — ztunnel이 자동으로 mTLS 적용)
kubectl exec -n demo deploy/frontend -- curl -s -o /dev/null -w "%{http_code}" http://backend.demo/get
# 예상: 200

# 3. PeerAuthentication 효과만 격리 테스트하기 위해 AuthorizationPolicy 일시 제거
#    (install.sh에서 적용된 상태이므로 잠시 삭제 — Lab 종료 후 복원)
kubectl delete authorizationpolicy backend-allow-frontend-only -n demo 2>/dev/null

# 4. mesh 외부에서 직접 요청 테스트
#    ambient 라벨이 없는 네임스페이스에서 시도
kubectl create namespace non-mesh --dry-run=client -o yaml | kubectl apply -f -
# 주의: non-mesh 네임스페이스에는 ambient 라벨 미적용 (Gatekeeper 범위 밖)

kubectl run curl-test --namespace non-mesh --image=curlimages/curl:8.5.0 \
  --restart=Never --command -- sleep infinity
kubectl wait --for=condition=ready pod/curl-test -n non-mesh --timeout=60s

# mesh 외부에서 backend로 요청 (STRICT이면 거부)
kubectl exec -n non-mesh curl-test -- curl -s -o /dev/null -w "%{http_code}" \
  http://backend.demo.svc.cluster.local/get --max-time 5
# 예상: 연결 실패 또는 56 (connection reset) — STRICT mTLS가 평문 거부

# 5. PERMISSIVE로 변경 후 비교 테스트
kubectl patch peerauthentication default -n istio-system --type merge \
  -p '{"spec":{"mtls":{"mode":"PERMISSIVE"}}}'
sleep 3  # 정책 전파 대기

# 다시 시도 (PERMISSIVE면 평문도 허용)
kubectl exec -n non-mesh curl-test -- curl -s -o /dev/null -w "%{http_code}" \
  http://backend.demo.svc.cluster.local/get --max-time 5
# 예상: 200

# 6. ★ 반드시 STRICT으로 복원 + AuthorizationPolicy 복원
kubectl apply -f policies/peer-authentication.yaml
kubectl apply -f policies/authz-policy.yaml

# 정리
kubectl delete pod curl-test -n non-mesh
kubectl delete namespace non-mesh
```

### 핵심 Q&A

> **Q: "STRICT과 PERMISSIVE의 차이는?"**
>
> A: STRICT은 mTLS가 없는 평문 트래픽을 거부한다. PERMISSIVE는 mTLS와 평문 모두 허용한다. 마이그레이션 단계에서는 PERMISSIVE로 시작하여 모든 워크로드가 mesh에 포함된 후
> STRICT으로 전환하는 것이 Best Practice다. 프로덕션에서 PERMISSIVE를 유지하면 보안 감사에서 지적 대상이 된다.

> **Q: "PeerAuthentication을 네임스페이스 레벨로 다르게 설정할 수 있나요?"**
>
> A: 그렇다. istio-system에 적용하면 mesh-wide 기본값이 되고, 특정 네임스페이스에 별도 PeerAuthentication을 생성하면 해당 네임스페이스만 오버라이드된다. 우선순위는
> workload-specific > namespace > mesh-wide 순이다.

---

## 4. Lab 3: AuthorizationPolicy 접근 제어

### 목표

SPIFFE ID 기반 L4 AuthorizationPolicy로 서비스 간 접근을 제어한다.

### 실습 단계

```bash
# 1. AuthorizationPolicy 효과 확인을 위해 일시 제거
#    (install.sh에서 이미 적용됨 — before/after를 비교하기 위해 삭제 후 재적용)
kubectl delete authorizationpolicy backend-allow-frontend-only -n demo 2>/dev/null

# 2. AuthorizationPolicy 없이: attacker도 backend에 접근 가능
kubectl apply -n demo -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: attacker
---
apiVersion: v1
kind: Pod
metadata:
  name: attacker
  labels:
    app: attacker
    env: dev
    team: platform
spec:
  serviceAccountName: attacker
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
  containers:
    - name: curl
      image: curlimages/curl:8.5.0
      command: ["sleep", "infinity"]
      resources:
        limits:
          cpu: 100m
          memory: 64Mi
EOF

kubectl wait --for=condition=ready pod/attacker -n demo --timeout=60s

# AuthorizationPolicy 없이 attacker → backend (성공)
kubectl exec -n demo attacker -- curl -s -o /dev/null -w "%{http_code}" \
  http://backend.demo/get --max-time 5
# 예상: 200 (AuthorizationPolicy가 없으므로 mTLS만 통과하면 접근 가능)

# 3. AuthorizationPolicy 적용 (frontend + Kong SA만 허용)
kubectl apply -f policies/authz-policy.yaml
sleep 2  # 정책 전파 대기

# 4. frontend → backend (허용: frontend SA가 principals에 포함)
kubectl exec -n demo deploy/frontend -- curl -s -o /dev/null -w "%{http_code}" http://backend.demo/get
# 예상: 200

# 5. attacker → backend (거부: attacker SA가 principals에 없음)
kubectl exec -n demo attacker -- curl -s -o /dev/null -w "%{http_code}" \
  http://backend.demo/get --max-time 5
# 예상: 000 (연결 거부, exit 56) — ztunnel이 401 Unauthorized로 차단

# 6. ztunnel 로그에서 RBAC 거부 확인
kubectl logs -n istio-system -l app=ztunnel --tail=100 | grep -i "denied\|unauthorized\|attacker"

# 정리
kubectl delete pod attacker -n demo
kubectl delete sa attacker -n demo
```

### 핵심 Q&A

> **Q: "AuthorizationPolicy와 NetworkPolicy의 차이는?"**
>
> A: NetworkPolicy(Cilium 등 CNI가 처리)는 L3/L4 레벨에서 IP/Port 기반으로 동작한다. AuthorizationPolicy(Istio)는 SPIFFE ID 기반으로 서비스
> 아이덴티티 레벨에서 동작한다. Pod IP가 변경되어도 ServiceAccount 기반이므로 정책이 유지된다. Best Practice는 두 가지를 함께 사용하는 Defense in Depth 전략이다.

> **Q: "Ambient Mode에서 L7 AuthorizationPolicy(HTTP path 기반)를 사용하려면?"**
>
> A: ztunnel은 L4만 처리하므로 L7 정책에는 waypoint proxy가 필요하다. `istio.io/use-waypoint` 라벨을 서비스에 추가하고 Gateway API로 waypoint를 배포하면
> 된다. waypoint는 Envoy 기반이므로 HTTP method, path, header 기반 정책을 처리할 수 있다.

---

## 5. Lab 4: Ambient vs Sidecar 리소스 비교

### 목표

Ambient Mode와 Sidecar Mode의 메모리/CPU 사용량을 비교하여 운영 효율성을 수치로 확인한다.

### 실습 단계

```bash
# 1. Ambient Mode 리소스 확인
echo "=== Ambient Mode: ztunnel 리소스 (노드당) ==="
kubectl top pod -n istio-system -l app=ztunnel 2>/dev/null || \
  kubectl get pod -n istio-system -l app=ztunnel -o jsonpath='{range .items[*]}{.metadata.name}: requests={.spec.containers[0].resources.requests}{"\n"}{end}'

# 2. demo 네임스페이스 Pod 확인 — sidecar 없음!
echo ""
echo "=== demo Pod 컨테이너 수 (Ambient: 1개만 있어야 함) ==="
kubectl get pods -n demo -o custom-columns='NAME:.metadata.name,CONTAINERS:.spec.containers[*].name,READY:.status.containerStatuses[*].ready'

# 3. 비교 데이터 계산
echo ""
echo "=== 리소스 비교 (예상) ==="
echo "Sidecar Mode (100 Pods):"
echo "  Envoy sidecar: 100 x 50MB = 5,000MB (5GB)"
echo "  Envoy sidecar: 100 x 100m CPU = 10,000m (10 CPU)"
echo ""
echo "Ambient Mode (100 Pods, 3 Nodes):"
echo "  ztunnel: 3 x 10MB = 30MB"
echo "  ztunnel: 3 x 50m CPU = 150m (0.15 CPU)"
echo ""
echo "절약: RAM ~4.97GB, CPU ~9.85 cores"

# 4. Pod 시작 시간 비교
echo ""
echo "=== Pod 시작 시간 (Ambient: sidecar init 없음) ==="
# Ambient Mode에서는 istio-init 컨테이너가 없으므로 시작이 빠름
kubectl get pod -n demo -l app=frontend -o jsonpath='{range .items[*]}{.metadata.name}: initContainers={.spec.initContainers[*].name}, startTime={.status.startTime}{"\n"}{end}'
```

### 리소스 비교 표

| 항목             | Sidecar Mode           | Ambient Mode             |
|----------------|------------------------|--------------------------|
| 프록시 위치         | Pod당 Envoy sidecar     | 노드당 ztunnel DaemonSet    |
| 메모리 (100 Pods) | ~5GB (50MB x 100)      | ~30MB (10MB x 3 nodes)   |
| CPU (100 Pods) | ~10 CPU (100m x 100)   | ~150m (50m x 3 nodes)    |
| Pod 시작 시간 영향   | +2~5초 (init container) | 영향 없음                    |
| L7 기능          | 기본 포함                  | waypoint proxy 추가 필요     |
| 장애 격리          | Pod 단위                 | 노드 단위 (blast radius 더 큼) |

### 핵심 Q&A

> **Q: "Ambient Mode의 단점은?"**
>
> A: 첫째, ztunnel은 L4만 처리하므로 L7 기능(HTTP 라우팅, 재시도, 서킷브레이커)이 필요하면 waypoint proxy를 별도 배포해야 한다. 둘째, ztunnel이 노드 레벨에서 동작하므로
> 하나의 ztunnel 장애 시 해당 노드의 모든 Pod에 영향을 준다(blast radius가 sidecar보다 큼). 셋째, 아직 GA 된 지 얼마 안 되어 프로덕션 레퍼런스가 sidecar 대비 적다.

> **Q: "1000개 Pod 클러스터에서 Ambient Mode를 도입하면 어떤 이점이 있나요?"**
>
> A: Sidecar Mode 대비 약 49.7GB RAM(1000 x 50MB - nodes x 10MB), 99.5 CPU(1000 x 100m - nodes x 50m)를 절약할 수 있다. 또한
> sidecar injection으로 인한 Pod 시작 지연이 없어지고, 앱 Deployment 업데이트 시 sidecar 버전 호환성을 신경 쓸 필요가 없어 운영 부담이 크게 줄어든다. Salesforce가
> 10만+ Pod 환경에서 이런 이유로 Ambient Mode를 채택했다.

---

## 6. Lab 5: ztunnel 로그에서 HBONE 터널 확인

### 목표

ztunnel 로그를 통해 HBONE(HTTP-Based Overlay Network Environment) 프로토콜의 동작을 확인한다.

### HBONE 프로토콜 이해

```
┌─────────────┐                              ┌─────────────┐
│ frontend Pod │                              │ backend Pod  │
│  (평문 요청)  │                              │  (평문 수신)  │
└──────┬──────┘                              └──────▲──────┘
       │ CNI redirect                               │ CNI redirect
┌──────▼──────┐    포트 15008 (HBONE)        ┌──────┴──────┐
│   ztunnel    │ ═══ mTLS + HTTP/2 CONNECT ═══▶  ztunnel    │
│  (source)    │    SPIFFE cert 교환           │  (dest)     │
└─────────────┘                              └─────────────┘
```

HBONE 구성요소:

- **mTLS**: SPIFFE X.509 인증서로 상호 인증
- **HTTP/2 CONNECT**: 터널링 프로토콜 (바이너리 스트림 전달)
- **포트 15008**: ztunnel 간 HBONE 전용 포트

### 실습 단계

```bash
# 1. ztunnel 로그 레벨 확인 및 트래픽 생성
FRONTEND_POD=$(kubectl get pod -n demo -l app=frontend -o jsonpath='{.items[0].metadata.name}')

# 트래픽 생성
for i in $(seq 1 5); do
  kubectl exec -n demo ${FRONTEND_POD} -- curl -s -o /dev/null http://backend.demo/get
  sleep 1
done

# 2. ztunnel 로그에서 HBONE 연결 확인
echo "=== ztunnel 로그 (HBONE 터널 관련) ==="
kubectl logs -n istio-system -l app=ztunnel --tail=50 | grep -E "inbound|outbound|HBONE|15008|connection"

# 3. source ztunnel 로그 (outbound)
echo ""
echo "=== Outbound 연결 (source ztunnel) ==="
kubectl logs -n istio-system -l app=ztunnel --tail=50 | grep "outbound" | tail -5

# 4. destination ztunnel 로그 (inbound)
echo ""
echo "=== Inbound 연결 (destination ztunnel) ==="
kubectl logs -n istio-system -l app=ztunnel --tail=50 | grep "inbound" | tail -5

# 5. SPIFFE ID 확인 — 인증서에 포함된 서비스 아이덴티티
echo ""
echo "=== SPIFFE ID 확인 ==="
kubectl logs -n istio-system -l app=ztunnel --tail=100 | grep -i "spiffe\|identity\|certificate" | tail -5

# 6. ztunnel이 관리하는 워크로드 목록 (istioctl 사용 가능 시)
istioctl ztunnel-config workloads 2>/dev/null || echo "(istioctl 미설치)"
```

### 로그 해석 가이드

```
# 예상되는 ztunnel 로그 형태:
# outbound 연결 (source → destination)
2025-01-01T00:00:00Z info  outbound connection: src=10.244.1.5:43210 dst=10.244.2.8:80
  hbone_addr=10.244.2.1:15008 identity=spiffe://cluster.local/ns/demo/sa/frontend

# inbound 연결 (destination에서 수신)
2025-01-01T00:00:00Z info  inbound connection: src=10.244.1.1:15008 dst=10.244.2.8:80
  identity=spiffe://cluster.local/ns/demo/sa/frontend
```

로그에서 확인할 핵심 항목:

- `hbone_addr`: HBONE 터널의 대상 주소 (포트 15008)
- `identity`: SPIFFE ID (서비스 아이덴티티)
- `inbound`/`outbound`: 트래픽 방향

### 핵심 Q&A

> **Q: "HBONE 프로토콜이 뭔가요?"**
>
> A: HTTP-Based Overlay Network Environment의 약자로, Istio Ambient Mode에서 ztunnel 간 통신에 사용하는 터널링 프로토콜이다. mTLS로 암호화된 HTTP/2
> CONNECT 터널을 통해 L4 트래픽을 전달한다. 포트 15008을 사용하며, 기존 Sidecar Mode의 직접 mTLS 연결과 달리 HTTP/2 CONNECT를 사용하여 향후 L7 프록시(waypoint)
> 연동이 용이하다.

> **Q: "ztunnel은 왜 Envoy 대신 Rust로 구현했나요?"**
>
> A: ztunnel은 L4만 처리하므로 Envoy의 L7 기능이 불필요하다. Rust로 구현하여 메모리 안전성을 확보하면서도 C++ Envoy 대비 더 작은 바이너리(~10MB vs ~50MB)와 낮은 메모리
> 사용량을 달성했다. DaemonSet으로 노드당 하나만 실행되지만, 해당 노드의 모든 Pod 트래픽을 처리하므로 경량화가 중요하다.

---

## 7. Q&A 종합

### Ambient Mode 아키텍처

| 질문               | 핵심 답변                                                     |
|------------------|-----------------------------------------------------------|
| Ambient Mode란?   | Sidecar 없이 노드당 ztunnel(L4) + 선택적 waypoint(L7)로 mesh 기능 제공 |
| 왜 도입하나?          | Sidecar의 리소스 오버헤드/운영 복잡성 제거, Pod 시작 시간 영향 없음              |
| ztunnel의 역할?     | mTLS 터미네이션/오리지네이션, L4 AuthZ, SPIFFE ID 기반 인증              |
| waypoint는 언제 필요? | HTTP 라우팅, 재시도, 서킷브레이커 등 L7 기능이 필요할 때                      |

### 보안

| 질문                                    | 핵심 답변                                                              |
|---------------------------------------|--------------------------------------------------------------------|
| STRICT vs PERMISSIVE?                 | STRICT=mTLS 필수, PERMISSIVE=평문 허용. 프로덕션은 반드시 STRICT                 |
| REGISTRY_ONLY의 목적?                    | 미등록 외부 서비스 접근 차단, C&C 통신 방지                                        |
| AuthorizationPolicy vs NetworkPolicy? | AuthZ=SPIFFE ID 기반(mesh), NP=IP/Port 기반(CNI). 함께 사용이 Best Practice |
| mTLS 인증서 로테이션?                        | istiod CA가 자동 발급, 기본 24시간 주기 로테이션                                  |

### 운영

| 질문                 | 핵심 답변                                                    |
|--------------------|----------------------------------------------------------|
| 설치 순서가 중요한 이유?     | CRD → CNI → istiod → ztunnel. Race Condition 방지          |
| Cilium과 공존 방법?     | CNI chaining (chained=true) + Cilium cni.exclusive=false |
| 장애 시 blast radius? | Sidecar=Pod 단위, Ambient=노드 단위. Ambient가 더 넓음             |
| 1000 Pod에서의 절약?    | RAM ~49GB, CPU ~99 cores (Sidecar 대비)                    |

### 참고 문서

- [Istio Ambient Mode 공식 문서](https://istio.io/latest/docs/ambient/overview/)
- [Ambient Mode Helm 설치 가이드](https://istio.io/latest/docs/ambient/install/helm/)
- [PeerAuthentication 레퍼런스](https://istio.io/latest/docs/reference/config/security/peer_authentication/)
- [AuthorizationPolicy 레퍼런스](https://istio.io/latest/docs/reference/config/security/authorization-policy/)
- [HBONE 프로토콜 설계](https://istio.io/latest/docs/ambient/architecture/hbone/)
- [ztunnel 아키텍처](https://istio.io/latest/docs/ambient/architecture/data-plane/)
