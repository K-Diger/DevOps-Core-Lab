# 03. Security — 기술 심화 가이드

> **지원자**: 1년차 DevOps Engineer (스마일게이트, 1인 DevOps)
> **핵심 키워드**: Zero Trust, Cilium eBPF, Istio Ambient Mode, OPA Gatekeeper, Pod Security Context
> **리뷰어 관점**: 11년차 DevOps 팀 리드 + 6명 팀원 (인프라/SRE/보안/플랫폼/CI·CD/EM)

---

## 1. 보안 아키텍처 Overview

### Zero Trust 계층 구조

```
┌─────────────────────────────────────────────────────────────┐
│                    Pod Security Context                      │
│              (runAsNonRoot, drop ALL, readOnly)               │
├─────────────────────────────────────────────────────────────┤
│                    Policy Layer (OPA Gatekeeper)              │
│        (Admission Control, Audit, 거버넌스 정책 강제)          │
├─────────────────────────────────────────────────────────────┤
│                Transport Layer (Istio Ambient mTLS)           │
│   (ztunnel L4 mTLS, HBONE 터널, PeerAuthentication STRICT)   │
├─────────────────────────────────────────────────────────────┤
│                 Network Layer (Cilium eBPF)                   │
│   (kube-proxy 대체, WireGuard 노드간 암호화, L3/L4 정책)      │
└─────────────────────────────────────────────────────────────┘
```

**설계 철학**: "Never Trust, Always Verify" — 네트워크 위치가 아닌 **서비스 ID 기반 인증**. 각 계층이 독립적으로 보안을 담당하므로, 한 계층이 뚫려도 다음 계층이 방어한다.

### 계층별 역할 분담

| 계층            | 도구                   | 보호 대상         | 암호화 범위                            |
|---------------|----------------------|---------------|-----------------------------------|
| L3/L4 Network | Cilium + WireGuard   | 노드 간 모든 트래픽   | 노드-to-노드 (51871/udp)              |
| L4 Transport  | Istio ztunnel        | Pod 간 서비스 트래픽 | Pod-to-Pod mTLS (15008/tcp HBONE) |
| Admission     | OPA Gatekeeper       | 리소스 배포 시점     | N/A (정책 강제)                       |
| Runtime       | Pod Security Context | 컨테이너 런타임      | N/A (권한 최소화)                      |

### 방화벽 포트 정리

```
[Cilium]
  8472/udp  — VXLAN 오버레이
  6081/udp  — Geneve 터널
  4240/tcp  — 노드 간 Health Check
  4244/tcp  — Hubble Relay
  4245/tcp  — Hubble UI
  51871/udp — WireGuard 암호화 터널

[Istio Ambient]
  15001     — ztunnel outbound (Pod → 외부)
  15006     — ztunnel inbound plaintext passthrough
  15008/tcp — HBONE mTLS 터널 (핵심)
  15012/tcp — istiod xDS (control plane)
  15014/tcp — istiod monitoring
  15017/tcp — istiod webhook
```

---

## 2. 핵심 설정 해설

### 2.1 Cilium eBPF + kube-proxy 대체

#### 왜 kube-proxy를 제거했는가

kube-proxy는 iptables 규칙을 선형 탐색(O(n))하여 서비스 라우팅을 처리한다. 서비스 수가 늘어나면 규칙 수가 기하급수적으로 증가하고, 모든 패킷이 전체 규칙 체인을 순회해야 하므로 **레이턴시와
CPU 사용량이 비례적으로 증가**한다.

Cilium은 eBPF 해시 테이블을 사용하여 O(1) 룩업으로 서비스를 라우팅한다. 커널 내에서 직접 패킷을 처리하므로 conntrack 서브시스템도 우회하며, 일반적인 배포에서 **CPU 사용량 25~40% 감소
** 효과가 있다.

```yaml
# Cilium Helm values
kubeProxyReplacement: "true"   # iptables 완전 제거
```

**핵심 원리**:

- **eBPF 프로그램**: 커널에 동적 로드, 패킷 레벨에서 라우팅/정책 결정 직접 수행
- **해시 테이블 기반**: 서비스 수 증가에도 성능 일정 (iptables의 O(n) vs eBPF의 O(1))
- **conntrack 우회**: eBPF 맵에서 자체 연결 추적, 커널 conntrack 부하 제거

**핵심 포인트**: "kube-proxy를 왜 제거했냐"는 질문에 단순히 "성능" 이라고 답하면 안 된다. **iptables의 선형 탐색 구조적 한계**를 설명하고, eBPF가 이를 해시 테이블로 대체하는 원리를
말해야 한다.

> 참고: [Cilium 공식 — Kubernetes Without kube-proxy](https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/)

---

### 2.2 WireGuard 노드간 암호화

#### 왜 IPSec이 아닌 WireGuard인가

```yaml
encryption:
  enabled: true
  type: wireguard   # IPSec 대신 WireGuard 선택
```

| 항목     | WireGuard                | IPSec                         |
|--------|--------------------------|-------------------------------|
| 코드베이스  | ~4,000줄 (커널 모듈)          | ~400,000줄                     |
| 암호화    | ChaCha20-Poly1305 (고정)   | 협상 가능 (IKE)                   |
| 키 교환   | Noise Protocol Framework | IKE v1/v2                     |
| 동작 위치  | 리눅스 커널 내장 (5.6+)         | 커널 + userspace (strongSwan 등) |
| 처리량    | ~15% 높은 throughput       | 기준                            |
| 레이턴시   | ~20% 낮음                  | 기준                            |
| 설정 복잡도 | 키 쌍만 교환                  | SA, SP, IKE 프로파일, 암호 스위트      |

**WireGuard 선택 이유**:

1. **단순성**: 암호 스위트 협상이 없어 공격 표면이 작음 (ChaCha20 고정)
2. **커널 네이티브**: Linux 5.6+ 내장, 별도 데몬 불필요
3. **Cilium 통합**: `encryption.type=wireguard` 한 줄로 전체 클러스터 노드간 암호화 활성화
4. **성능**: IPSec 대비 throughput 15% 향상, latency 20% 감소

**언제 필요한가**: mTLS는 Pod-to-Pod 서비스 레이어 암호화이고, WireGuard는 **노드-to-노드 인프라 레이어** 암호화다. ARP spoofing, 물리 네트워크 탭 등 인프라 레벨 공격
방어에 필요하다. 특히 멀티 테넌트 환경이나 공유 네트워크 인프라에서 필수적이다.

>
참고: [Cilium 공식 — WireGuard Transparent Encryption](https://docs.cilium.io/en/stable/security/network/encryption-wireguard/)

---

### 2.3 Istio Ambient Mode vs Sidecar Mode

#### 왜 Ambient Mode를 선택했는가

**Sidecar Mode의 문제점**:

1. **리소스 오버헤드**: Pod마다 Envoy sidecar (~128Mi 메모리, ~100m CPU)가 붙음 → Pod 100개 = Envoy 100개
2. **배포 복잡도**: sidecar injection → Pod 재시작 필수, 순서 의존성 (istio-init → app)
3. **레이턴시**: 모든 트래픽이 Envoy 2번 통과 (source sidecar → dest sidecar)
4. **업그레이드 난이도**: Istio 업그레이드 시 모든 Pod 롤링 재시작 필요

**Ambient Mode 아키텍처**:

```
[Ambient Mode - L4 Only]

  Node A                              Node B
  ┌──────────────────┐               ┌──────────────────┐
  │  Pod A (app only) │               │  Pod B (app only) │
  │  (sidecar 없음)   │               │  (sidecar 없음)   │
  └────────┬─────────┘               └────────┬─────────┘
           │                                   │
  ┌────────▼─────────┐               ┌────────▼─────────┐
  │    ztunnel        │◄──HBONE mTLS──►│    ztunnel        │
  │  (DaemonSet,      │   15008/tcp    │  (DaemonSet,      │
  │   Rust 기반,      │               │   Rust 기반,      │
  │   ~50m/~64Mi)     │               │   ~50m/~64Mi)     │
  └──────────────────┘               └──────────────────┘
```

**ztunnel (Zero Trust Tunnel)**:

- **Rust 기반** 경량 L4 프록시 (Envoy가 아님!)
- 노드당 1개 DaemonSet으로 해당 노드의 모든 Pod 트래픽 처리
- 리소스: ~50m CPU, ~64Mi 메모리 (sidecar 대비 **~95% 절약**)
- 역할: mTLS 핸드셰이크, L4 인증, L4 텔레메트리, HBONE 터널링

**HBONE (HTTP-Based Overlay Network Encapsulation)**:

- HTTP CONNECT 기반 mTLS 터널링 프로토콜
- HTTP/2 멀티플렉싱으로 단일 mTLS 연결에 다수의 TCP 스트림 전송
- source-dest 쌍당 1개 HBONE 터널, 내부에서 다중 앱 연결 처리

**네임스페이스 등록**: Pod 재시작 없이 레이블만으로 등록/해제 가능

```yaml
# Ambient Mesh 등록
kubectl label namespace <ns> istio.io/dataplane-mode=ambient

  # Ambient Mesh 제외 (kong-system, monitoring, kube-system)
kubectl label namespace <ns> istio.io/dataplane-mode=none
```

**istiod HA 구성**:

```yaml
istiod:
  replicaCount: 2
  env:
    PILOT_ENABLE_AMBIENT: "true"
  meshConfig:
    outboundTrafficPolicy:
      mode: REGISTRY_ONLY   # 미등록 외부 서비스 차단
```

>
참고: [Istio 공식 — Ambient Mode Overview](https://istio.io/latest/docs/ambient/overview/), [Istio 공식 — Ambient Data Plane](https://istio.io/latest/docs/ambient/architecture/data-plane/)

---

### 2.4 PeerAuthentication STRICT mTLS

```yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: istio-system   # mesh-wide 적용
spec:
  mtls:
    mode: STRICT   # 평문 통신 전면 제거
```

**STRICT vs PERMISSIVE**:

- `PERMISSIVE`: mTLS + 평문 모두 수용 → 마이그레이션 중에만 사용
- `STRICT`: mTLS만 수용 → **평문 요청은 즉시 거부**

**암호화되는 트래픽**:

- Ambient Mode 등록된 네임스페이스 간 모든 Pod-to-Pod 통신
- ztunnel이 HBONE(15008/tcp)으로 자동 mTLS 래핑

**암호화되지 않는 트래픽**:

- `istio.io/dataplane-mode=none` 레이블이 붙은 네임스페이스 (kong-system, monitoring, kube-system)
- 이 네임스페이스들은 WireGuard(51871/udp)가 노드 레벨에서 암호화

**핵심 포인트**: "모든 트래픽이 암호화됩니까?"라는 질문에 "네, mTLS로요"라고만 답하면 부족하다. **Ambient에서 제외된 네임스페이스는 Cilium WireGuard가 노드 레벨에서 보호**한다는
계층적 방어 설계를 설명해야 한다.

---

### 2.5 Cilium + Istio CNI 체이닝

#### 왜 체이닝이 필요한가

Cilium과 Istio CNI는 각각 다른 계층의 역할을 수행한다:

- **Cilium CNI**: L3/L4 네트워크 연결, eBPF 서비스 로드밸런싱, WireGuard 암호화
- **Istio CNI**: Pod 네트워크 네임스페이스에서 ztunnel로 트래픽 리다이렉트

```yaml
# Cilium Helm values (Istio 공존 설정)
cni:
  exclusive: false     # 다른 CNI 플러그인 삭제 방지 (기본값 true!)
  chained: true        # CNI 체이닝 활성화
socketLB:
  hostNamespaceOnly: true  # host namespace에서만 소켓 LB 적용
  # → Pod namespace에서 Istio가 트래픽 제어 가능
```

**체이닝 순서**: `Cilium CNI → Istio CNI`

1. Pod 생성 시 Cilium CNI가 먼저 veth 인터페이스 생성, IP 할당
2. Istio CNI가 Pod 네트워크 네임스페이스에 iptables 규칙 삽입 → ztunnel로 리다이렉트
3. ztunnel이 mTLS 처리 후 Cilium의 eBPF 데이터패스를 통해 실제 네트워크 전송

**주의사항**:

- `cni.exclusive=false` 미설정 시 Cilium이 Istio CNI 설정 파일을 삭제함
- `socketLB.hostNamespaceOnly=true` 미설정 시 Cilium이 Pod 네임스페이스에서도 소켓 LB를 수행하여 Istio의 트래픽 리다이렉트를 우회
- `bpf.masquerade=true`는 Istio Ambient과 호환되지 않음 (link-local IP 문제로 health check 실패)

>
참고: [Cilium 공식 — Integration with Istio](https://docs.cilium.io/en/latest/network/servicemesh/istio/), [Istio 공식 — Platform Prerequisites](https://istio.io/latest/docs/ambient/install/platform-prerequisites/)

---

### 2.6 OPA Gatekeeper 정책

#### Admission Control 아키텍처

```
kubectl apply
    │
    ▼
API Server → Authentication → Authorization → Mutating Webhooks
                                                      │
                                                      ▼
                                              Validating Webhooks
                                              (OPA Gatekeeper 여기서 개입)
                                                      │
                                                ┌─────▼─────┐
                                                │ 정책 위반? │
                                                └─────┬─────┘
                                                  Yes │ No
                                                  │   │
                                              거부 ◄   ▼ etcd 저장
```

```yaml
# Gatekeeper Helm values
replicas: 2
audit:
  auditInterval: 60           # 60초마다 기존 리소스 감사
  auditFromCache: true         # API Server 직접 조회 대신 캐시 사용
  # → API Server 부하 대폭 감소
emitAdmissionEvents: true      # admission 결정을 Kubernetes Event로 발행
emitAuditEvents: true          # audit 결과를 Kubernetes Event로 발행
```

**auditFromCache=true의 의미**:

- Gatekeeper가 내부 캐시(OPA 데이터 스토어)에 리소스를 복제하여 보관
- audit 수행 시 API Server에 LIST 요청을 보내지 않고 캐시에서 직접 조회
- API Server 부하 감소, 특히 대규모 클러스터에서 중요

**정책 예시**:

```yaml
# 1. 리소스 제한 필수 (resources.limits/requests 없으면 거부)
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: k8srequiredresources
spec:
  crd:
    spec:
      names:
        kind: K8sRequiredResources
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package k8srequiredresources
        violation[{"msg": msg}] {
          container := input.review.object.spec.containers[_]
          not container.resources.limits
          msg := sprintf("Container %v has no resource limits", [container.name])
        }

# 2. 특권 컨테이너 금지
# securityContext.privileged=true인 컨테이너 배포 차단
```

>
참고: [OPA Gatekeeper 공식 문서](https://open-policy-agent.github.io/gatekeeper/website/), [Kubernetes — OPA Gatekeeper Policy and Governance](https://kubernetes.io/blog/2019/08/06/opa-gatekeeper-policy-and-governance-for-kubernetes/)

---

### 2.7 Pod Security Context

```yaml
# 모든 Helm 차트 공통 설정
securityContext:
  runAsNonRoot: true              # root 실행 금지
  allowPrivilegeEscalation: false # setuid 비트 등 권한 상승 차단
  capabilities:
    drop:
      - ALL                       # 모든 Linux capabilities 제거
  readOnlyRootFilesystem: true    # 루트 파일시스템 읽기 전용
  seccompProfile:
    type: RuntimeDefault          # 시스템콜 필터링
```

**readOnlyRootFilesystem + Spring Boot**:

Spring Boot는 `/tmp`에 세션/캐시 파일을 쓰므로 readOnly 시 CrashLoopBackOff 발생. 해결:

```yaml
volumeMounts:
  - name: tmp-dir
    mountPath: /tmp
volumes:
  - name: tmp-dir
    emptyDir:
      sizeLimit: 100Mi   # tmpdir 크기 제한
```

**왜 drop ALL인가**:

- Linux capabilities는 약 40개 (CAP_NET_RAW, CAP_SYS_ADMIN 등)
- 필요한 것만 add하는 **화이트리스트 방식**이 안전 (기본은 전부 제거)
- 대부분의 애플리케이션은 capabilities 없이 정상 동작
- 필요 시 `add: [NET_BIND_SERVICE]` 등 최소한만 추가

---

## 3. 심화 Q&A — 팀 토론 결과

---

### 팀원1: 박준혁 — 인프라 엔지니어 (7년차)

> "1인 DevOps에서 이 보안 스택을 운영한다는 건, 각 컴포넌트의 역할 분담과 장애 시 영향 범위를 정확히 이해하고 있어야 한다."

#### Q1. Cilium에서 kubeProxyReplacement=true로 설정한 이유와, 이 설정이 클러스터에 미치는 영향은?

**의도**: kube-proxy 대체가 단순 성능 개선인지, 아키텍처적 판단인지 확인

**키포인트**:

1. **iptables의 구조적 한계**: 서비스 수 증가 시 O(n) 선형 탐색으로 레이턴시 증가. 1,000개 서비스 기준 iptables 규칙 수만 개 → 모든 패킷이 전체 체인 순회
2. **eBPF 해시 테이블**: O(1) 룩업으로 서비스 수와 무관한 일정 성능. conntrack도 eBPF 맵에서 자체 처리하여 커널 conntrack 서브시스템 우회
3. **운영 단순화**: kube-proxy DaemonSet 제거로 관리 포인트 감소. iptables 규칙 디버깅 불필요 (대신 `cilium bpf lb list`로 eBPF 맵 직접 조회)

**꼬리질문 1**: kubeProxyReplacement=true 상태에서 Cilium이 죽으면 어떤 일이 발생하나요?

> kube-proxy가 없으므로 **서비스 라우팅 자체가 불가능**. ClusterIP, NodePort 모두 동작하지 않는다. 이것이 Cilium을 SPOF로 만들기 때문에, Cilium Agent의
> liveness probe, PodDisruptionBudget, 그리고 노드 레벨 모니터링이 필수적이다. `cilium status`와 Hubble 메트릭을 통한 실시간 감시가 중요하다.

**꼬리질문 2**: eBPF 프로그램이 커널에서 동작한다면, 커널 버전에 대한 의존성은 어떻게 관리하나요?

> Cilium은 최소 커널 버전을 요구한다 (4.19+, 권장 5.10+). WireGuard는 5.6+ 필요. 노드 OS 업그레이드 시 커널 호환성 확인이 선행되어야 하며, Cilium 버전별 지원 커널
> 매트릭스를 반드시 확인해야 한다. 이것이 노드 이미지 표준화가 중요한 이유 중 하나이다.

---

#### Q2. WireGuard 노드간 암호화를 활성화한 이유는? mTLS와 중복 아닌가요?

**의도**: 계층별 암호화 범위 차이를 이해하는지, 과잉 설계인지 판단 가능한지 확인

**키포인트**:

1. **보호 범위가 다르다**: mTLS는 서비스 메시에 등록된 Pod-to-Pod 트래픽만 암호화. WireGuard는 노드를 오가는 **모든 트래픽** (kubelet, etcd 동기화, DNS,
   Ambient에서 제외된 네임스페이스 포함) 암호화
2. **방어 계층이 다르다**: mTLS는 애플리케이션 레이어 (L4/L7), WireGuard는 네트워크 인프라 레이어 (L3). 물리 네트워크 탭, ARP spoofing 등 인프라 공격은 mTLS로 방어 불가
3. **실제 수치**: WireGuard는 IPSec 대비 throughput ~15% 향상, latency ~20% 감소. 코드베이스 ~4,000줄 vs IPSec ~400,000줄로 공격 표면이 극히 작음

**꼬리질문 1**: WireGuard 암호화가 네트워크 throughput에 미치는 영향은 어느 정도인가요?

> WireGuard는 커널 내에서 동작하므로 userspace VPN 대비 오버헤드가 작지만, 암호화 없는 클러스터 대비 throughput이 감소한다. 그러나 Cilium IPSec이나 Linkerd
> mTLS보다는 throughput이 높다. 실제 프로덕션에서 체감 가능한 성능 저하는 대부분의 워크로드에서 미미하다.

**꼬리질문 2**: WireGuard 포트(51871/udp)가 방화벽에서 차단되면 어떤 증상이 나타나나요?

> 다른 노드의 Pod로 가는 트래픽이 전부 드롭된다. 같은 노드 내 Pod 간 통신은 정상이나, cross-node 통신이 전면 실패. Hubble에서 `drop` 이벤트가 급증하고,
`cilium encrypt status`에서 WireGuard 피어 연결 실패를 확인할 수 있다. 이것이 방화벽 규칙에 51871/udp를 반드시 포함해야 하는 이유이다.

---

#### Q3. Hubble에서 dns,drop,tcp,flow,icmp,http 메트릭을 모두 수집하는 이유는?

**의도**: 관측성 설계의 의도성, 메트릭 선택 기준을 확인

**키포인트**:

1. **drop 메트릭**: 네트워크 정책 위반, 라우팅 실패 등 비정상 트래픽 감지. 보안 사고의 첫 번째 시그널
2. **dns 메트릭**: DNS 기반 exfiltration 탐지, 서비스 디스커버리 문제 진단 (coredns 장애 시 dns latency 급증)
3. **flow + tcp + http**: 서비스 간 통신 패턴 시각화 → NetworkPolicy 화이트리스트 설계의 기초 데이터. "어떤 서비스가 어디와 통신하는지" 모르면 정책을 작성할 수 없다

**꼬리질문 1**: Hubble 메트릭을 Prometheus로 노출할 때 카디널리티 폭발 문제는 어떻게 관리하나요?

> Hubble 메트릭은 source/destination pod, namespace, identity 등 라벨이 많아 카디널리티가 빠르게 증가한다. `prometheus.enabled=true`로 전체를 노출하되,
> Prometheus의 `metric_relabel_configs`로 불필요한 라벨을 드롭하거나, 필요한 메트릭만 선별 수집해야 한다. 대기업 규모에서는 Thanos/Mimir 등 장기 스토리지에 다운샘플링하여
> 저장한다.

**꼬리질문 2**: Hubble이 장애를 일으킬 경우 데이터패스(실제 네트워크 트래픽)에 영향이 있나요?

> Hubble은 eBPF 이벤트를 **관측만** 하는 컴포넌트로, 데이터패스와 분리되어 있다. Hubble Relay나 UI가 다운되어도 실제 네트워크 트래픽은 정상 동작한다. 이것이 Cilium 아키텍처의
> 장점으로, 관측성 레이어 장애가 네트워킹 레이어에 영향을 미치지 않는다.

---

### 팀원2: 이서연 — SRE (8년차)

> "보안 설정이 운영 안정성을 해치지 않는지, 장애 시 디버깅이 가능한지가 SRE 관점에서 가장 중요하다."

#### Q1. outboundTrafficPolicy.mode=REGISTRY_ONLY로 설정한 이유와 운영 시 겪은 문제점은?

**의도**: 보안과 운영 편의성 사이의 트레이드오프를 이해하는지 확인

**키포인트**:

1. **REGISTRY_ONLY 의미**: ServiceEntry로 명시적 등록되지 않은 외부 서비스로의 아웃바운드 트래픽 전면 차단. "화이트리스트" 방식
2. **보안 목적**: 공급망 공격, 데이터 exfiltration 방어. 컨테이너가 탈취되어도 미등록 C&C 서버로 통신 불가
3. **운영 이슈**: 새로운 외부 API 연동 시 반드시 ServiceEntry 사전 등록 필요 → 배포 파이프라인에 ServiceEntry 관리 포함 필수. 초기에 누락으로 인한 장애 가능성 존재

**꼬리질문 1**: 개발팀이 REGISTRY_ONLY 때문에 외부 API 연동이 안 된다고 불만을 제기하면 어떻게 대응하나요?

> ServiceEntry 등록을 셀프서비스로 제공하되, OPA 정책으로 허용된 도메인/IP 범위만 등록 가능하게 제한한다. "편의성을 위해 ALLOW_ANY로 바꾸자"는 요청은 보안 원칙 후퇴이므로 거부하되, 등록
> 프로세스를 자동화하여 마찰을 최소화하는 것이 답이다.

**꼬리질문 2**: REGISTRY_ONLY 환경에서 DNS 해석은 어떻게 동작하나요?

> DNS 해석 자체는 정상 동작한다 (CoreDNS → 외부 DNS 포워딩). 단, ztunnel이 아웃바운드 연결을 시도할 때 ServiceEntry에 등록되지 않은 목적지이면 연결을 거부한다. 즉, DNS는
> 성공하지만 TCP 연결이 실패하는 형태. 디버깅 시 `istioctl proxy-config` 대신 ztunnel 로그에서 확인해야 한다는 점이 Sidecar Mode와 다르다.

---

#### Q2. PeerAuthentication STRICT mTLS 적용 시 Ambient에서 제외된 네임스페이스(kong-system, monitoring, kube-system)와의 통신은 어떻게 처리되나요?

**의도**: 메시 경계에서의 트래픽 흐름 이해, STRICT 모드의 실제 동작 범위 확인

**키포인트**:

1. **Ambient 제외 네임스페이스**: `istio.io/dataplane-mode=none` 라벨 → ztunnel이 트래픽을 가로채지 않음 → 평문 통신
2. **STRICT과의 관계**: STRICT는 "메시 내부에서 mTLS만 수용"이므로, 메시 밖(none 라벨)에서 메시 안으로 들어오는 평문 요청은 거부됨
3. **해결 방법**: kong-system(인그레스)은 메시 외부 → 메시 내부 통신이므로, Kong이 직접 업스트림에 mTLS로 연결하거나, 또는 Kong 자체를 Ambient에 등록해야 함.
   monitoring(Prometheus scrape)은 mTLS가 아닌 경로로 /metrics 노출이 필요하여 제외

**꼬리질문 1**: monitoring 네임스페이스를 Ambient에서 제외한 구체적 이유는?

> Prometheus가 각 Pod의 /metrics 엔드포인트를 scrape할 때, ztunnel을 통과하면 mTLS 인증이 필요해진다. Prometheus에 Istio mTLS 인증서를 설정하거나
> PeerAuthentication을 PERMISSIVE로 전환해야 하는데, 이는 복잡도를 크게 높인다. monitoring 트래픽은 WireGuard가 노드 레벨에서 암호화하므로, 실용적 판단으로 제외한 것이다.

**꼬리질문 2**: kube-system을 Ambient에 포함하면 어떤 문제가 생기나요?

> CoreDNS, kube-apiserver 등 클러스터 핵심 컴포넌트가 ztunnel을 통과하게 되면, ztunnel 장애 시 DNS 해석과 API Server 통신이 실패하여 **클러스터 전체가 다운**될 수
> 있다. blast radius를 최소화하기 위해 kube-system은 메시에서 제외하는 것이 모범 사례이다.

---

#### Q3. istiod를 HA 2 replicas로 운영하는데, istiod가 모두 다운되면 기존 mTLS 통신은 유지되나요?

**의도**: Control Plane vs Data Plane 분리 이해, 장애 영향 범위 파악

**키포인트**:

1. **istiod = Control Plane**: xDS(15012/tcp)로 ztunnel에 인증서, 서비스 디스커버리, 정책 배포. 인증서 발급(CA 역할) 담당
2. **istiod 다운 시**: 기존에 배포된 인증서와 정책으로 **기존 연결은 계속 동작**. 그러나 **새로운 Pod 생성/삭제 시 서비스 디스커버리 업데이트 불가**, **인증서 갱신 실패**(기본 24시간
   수명)
3. **시간 제한**: 인증서 만료 전까지는 기존 통신 유지. 만료 후 mTLS 핸드셰이크 실패 → 모든 새 연결 거부. 따라서 istiod 복구 SLO는 인증서 수명보다 짧아야 함

**꼬리질문 1**: istiod 인증서 수명을 늘리면 장애 허용 시간도 늘어나는데, 왜 기본값(24시간)을 유지하나요?

> 인증서 수명이 길수록 탈취 시 악용 기간도 길어진다. 보안과 가용성의 트레이드오프이며, 24시간은 "istiod를 하루 안에 복구할 수 있다"는 운영 역량 전제하에 적절한 값이다. 인증서를 7일로 늘리는 것보다
> istiod HA와 PDB를 통해 가용성을 확보하는 것이 올바른 접근이다.

**꼬리질문 2**: istiod 2 replicas의 PodDisruptionBudget은 어떻게 설정하셨나요?

> `minAvailable: 1`로 설정하여 동시에 2개가 다운되는 것을 방지. 노드 드레인, 클러스터 업그레이드 시에도 최소 1개의 istiod가 동작하도록 보장. 대기업 규모에서는 3 replicas +
`minAvailable: 2`가 더 안전하다.

---

### 팀원3: 최민수 — 보안 엔지니어 (9년차)

> "보안 설정의 '왜'를 모르면, 설정을 바꿔야 할 때 무엇이 안전하고 무엇이 위험한지 판단할 수 없다."

#### Q1. Sidecar Mode 대신 Ambient Mode를 선택한 기술적 근거를 계층별로 설명해 주세요.

**의도**: 단순 "리소스 절약" 이상의 아키텍처적 판단 근거 확인

**키포인트**:

1. **리소스 효율성**: Sidecar(Pod당 Envoy ~128Mi) vs ztunnel(노드당 1개, ~64Mi). Pod 100개 기준: 12.8Gi vs 64Mi (노드 1대 기준). 1인
   DevOps에서 sidecar 관리 부담은 치명적
2. **운영 복잡도**: Sidecar는 injection → Pod 재시작, init container 순서 의존성, Istio 업그레이드 시 전체 Pod 롤링 재시작. Ambient는 네임스페이스 라벨 하나로
   등록/해제, Pod 재시작 불필요
3. **보안 격리**: Sidecar는 앱과 같은 Pod에서 동작 → 앱 취약점이 sidecar에 영향 가능. ztunnel은 앱 Pod 외부(노드 레벨)에서 동작 → **보안 처리 계층과 앱 계층이 물리적으로
   분리**

**꼬리질문 1**: Ambient Mode에서 L7 정책(HTTP 라우팅, 헤더 기반 인가)이 필요하면 어떻게 하나요?

> Waypoint Proxy를 배포한다. Waypoint은 네임스페이스당 또는 서비스당 Envoy 기반 프록시로, 필요한 서비스에만 L7 기능을 추가한다. 이것이 Ambient의 핵심 설계 — **L4는 전체(
ztunnel), L7은 필요한 곳만(Waypoint)** — "pay as you go" 모델이다. 현재 구성에서 L7이 필요 없어 Waypoint을 배포하지 않았다.

**꼬리질문 2**: ztunnel이 노드당 1개이므로, ztunnel이 죽으면 해당 노드의 모든 Pod 통신이 실패하는 거 아닌가요?

> 맞다. ztunnel은 DaemonSet이므로 kubelet이 자동 재시작하며, 재시작 시간은 Rust 바이너리 특성상 수 초 이내이다. 그러나 이 수 초 동안 해당 노드의 메시 트래픽이 중단된다. 이것이
> STRICT mTLS의 리스크이기도 하며, PodDisruptionBudget과 노드 레벨 모니터링이 필수인 이유이다. Sidecar도 sidecar 크래시 시 해당 Pod 통신이 실패하므로, blast
> radius
> 관점에서는 트레이드오프가 있다.

---

#### Q2. Zero Trust를 네트워크(Cilium) → Transport(Istio) → Policy(OPA) → Pod(Security Context) 4계층으로 구현한 설계 의도는?

**의도**: Defense in Depth(심층 방어) 전략의 이해, 각 계층이 독립적으로 필요한 이유

**키포인트**:

1. **Network (Cilium + WireGuard)**: 노드 간 트래픽 암호화 + L3/L4 네트워크 정책. "인프라를 신뢰하지 않는다"
2. **Transport (Istio mTLS)**: 서비스 ID 기반 인증 + Pod-to-Pod 암호화. "같은 네트워크에 있다고 신뢰하지 않는다"
3. **Policy (OPA)**: 배포 시점 거버넌스. "코드가 정책을 위반하지 않도록 강제한다"
4. **Pod (Security Context)**: 런타임 최소 권한. "컨테이너가 탈취되어도 피해를 최소화한다"

**핵심**: 각 계층은 **독립적으로** 동작한다. Istio가 뚫려도 Cilium WireGuard가 노드 레벨 암호화를 유지하고, OPA를 우회해도 Pod Security Context가 런타임에서 권한을
제한한다.

**꼬리질문 1**: 4계층 중 하나만 선택해야 한다면 어떤 것을 선택하시겠습니까?

> Transport Layer (Istio mTLS). 서비스 ID 기반 인증은 Zero Trust의 핵심이며, IP가 아닌 서비스 ID로 통신 대상을 검증하는 것이 네트워크 위치 기반 신뢰 모델을 가장 효과적으로
> 대체한다. 단, 이것은 "하나만"이라는 비현실적 전제에서의 답이며, 실제로는 계층적 방어가 필수이다.

**꼬리질문 2**: 이 4계층 설계에서 가장 운영 부담이 큰 것은 어떤 계층인가요?

> OPA Gatekeeper 정책 관리이다. 보안 정책은 비즈니스 요구사항에 따라 지속적으로 변경되며, 정책이 너무 strict하면 배포를 막고, 너무 loose하면 보안 구멍이 생긴다.
> ConstraintTemplate과 Constraint의 버전 관리, 테스트, 점진적 롤아웃(dryrun → warn → deny) 프로세스가 핵심이다.

---

#### Q3. OPA Gatekeeper의 정책 설계 철학과, auditFromCache=true를 선택한 근거는?

**의도**: 정책 엔진의 아키텍처적 이해, 대규모 환경에서의 고려사항

**키포인트**:

1. **정책 설계 철학**: "Shift Left Security" — 런타임이 아닌 **배포 시점**에서 위반을 차단. 프로덕션에 잘못된 리소스가 배포되는 것 자체를 방지
2. **auditFromCache=true**: Gatekeeper가 Kubernetes 리소스를 내부 캐시(OPA 데이터 스토어)에 복제. 60초 audit 주기마다 API Server에 LIST를 보내는 대신
   캐시에서 조회 → API Server 부하 대폭 감소
3. **트레이드오프**: 캐시 동기화 지연으로 최대 수 초간 최신 상태가 반영되지 않을 수 있으나, audit는 실시간 차단이 아닌 사후 감사이므로 수용 가능

**꼬리질문 1**: auditFromCache=true에서 캐시 동기화 지연으로 인해 위반 리소스를 감지하지 못하는 경우는 없나요?

> 있을 수 있다. 그러나 admission webhook은 실시간으로 동작하므로(캐시와 무관), 새로운 위반 리소스 배포는 차단된다. audit는 "이미 존재하는 리소스 중 정책 위반 리소스"를 찾는 보조
> 수단이므로, 수 초의 지연은 수용 가능하다. 즉, admission(실시간 차단) + audit(사후 감사)의 이중 구조에서 각각의 역할이 다르다.

**꼬리질문 2**: emitAdmissionEvents=true와 emitAuditEvents=true를 모두 켜면 이벤트 양이 많아질 텐데, 어떻게 활용하나요?

> Kubernetes Event로 발행된 admission/audit 이벤트를 Elasticsearch나 Loki에 수집하여, Grafana 대시보드에서 "어떤 팀이 어떤 정책을 가장 많이 위반하는지" 트렌드를
> 추적한다. 이 데이터를 기반으로 정책 교육이나 Helm 차트 템플릿 개선에 활용할 수 있다.

---

#### Q4. WireGuard와 IPSec 중 WireGuard를 선택한 보안적 근거는?

**의도**: 암호화 프로토콜 선택의 보안적 판단력 확인

**키포인트**:

1. **공격 표면 최소화**: WireGuard ~4,000줄 vs IPSec ~400,000줄. 코드가 적을수록 취약점이 적다. 보안 감사(audit)도 용이
2. **암호 스위트 협상 없음**: WireGuard는 ChaCha20-Poly1305 고정. IPSec의 IKE 협상 과정에서 다운그레이드 공격(약한 암호로 유도) 가능성 원천 차단
3. **Noise Protocol Framework**: 현대적 키 교환 프로토콜. IPSec IKE v1/v2 대비 forward secrecy 보장이 더 강력하고, 프로토콜 자체가 형식 검증(formal
   verification)됨

**꼬리질문 1**: WireGuard는 암호 스위트가 고정인데, ChaCha20에 취약점이 발견되면 어떻게 대응하나요?

> WireGuard의 "Crypto Versioning" 전략: 프로토콜 자체를 버전업하여 새 암호를 적용한다. IPSec처럼 런타임에 협상하는 것이 아니라, 커널 모듈 업데이트로 전환. 리눅스 커널 업데이트
> 주기에 맞춰 패치가 배포되며, Cilium이 이를 자동으로 활용한다. 현재 ChaCha20은 암호학적으로 안전한 것으로 평가받고 있다.

**꼬리질문 2**: WireGuard가 UDP(51871) 기반인데, TCP만 허용하는 환경에서는 어떻게 하나요?

> WireGuard는 UDP만 지원하므로 TCP-only 환경에서는 사용할 수 없다. 이 경우 Cilium IPSec (ESP 프로토콜)을 대안으로 사용하거나, UDP를 허용하도록 방화벽 정책을 조정해야 한다.
> 클라우드 환경에서는 대부분 UDP가 허용되므로 문제가 적으나, 온프레미스 환경에서는 네트워크 팀과의 사전 협의가 필요하다.

---

#### Q5. Pod Security Context에서 drop ALL + readOnlyRootFilesystem 조합의 보안적 의미는?

**의도**: 컨테이너 런타임 보안의 심도 있는 이해

**키포인트**:

1. **drop ALL**: 약 40개 Linux capabilities 전부 제거. CAP_NET_RAW(패킷 조작), CAP_SYS_ADMIN(마운트, namespace 조작), CAP_DAC_OVERRIDE(
   파일 권한 우회) 등 위험한 능력 원천 차단
2. **readOnlyRootFilesystem**: 컨테이너 내 파일 쓰기 불가 → 공격자가 침투해도 웹셸, 백도어 바이너리 설치 불가. /tmp만 emptyDir로 마운트하여 제한적 쓰기 허용 (
   sizeLimit: 100Mi)
3. **조합 효과**: capabilities 없는 + 파일시스템 읽기 전용 = 탈취되어도 **권한 상승 불가 + 지속성(persistence) 확보 불가**. 공격자의 kill chain을 초기 단계에서 차단

**꼬리질문 1**: readOnlyRootFilesystem에서 Spring Boot의 /tmp 문제를 emptyDir로 해결했는데, 이 emptyDir의 sizeLimit을 초과하면 어떻게 되나요?

> Pod가 Evict된다 (kubelet이 감지). sizeLimit은 hard limit으로, 이를 초과하면 kubelet이 Pod를 종료한다. 따라서 sizeLimit은 애플리케이션의 실제 /tmp 사용량을
> 모니터링한 후 적절한 여유를 두고 설정해야 한다. 100Mi는 일반적인 Spring Boot 세션/캐시에 충분하나, 대용량 파일 업로드 처리 시에는 부족할 수 있다.

**꼬리질문 2**: allowPrivilegeEscalation=false와 drop ALL의 차이는 무엇인가요?

> `drop ALL`은 현재 프로세스의 capabilities를 제거한다. `allowPrivilegeEscalation=false`는 자식 프로세스가 부모보다 높은 권한을 얻는 것을 방지한다(setuid 비트,
> no_new_privs 커널 플래그). 둘은 다른 공격 벡터를 차단: drop ALL은 "현재 권한 최소화", allowPrivilegeEscalation=false는 "미래 권한 상승 차단". 반드시 함께
> 사용해야
> 완전하다.

---

### 팀원4: 김하준 — 플랫폼 엔지니어 (6년차)

> "보안 설정이 개발자 경험(DX)과 플랫폼 확장성에 미치는 영향을 본다."

#### Q1. Ambient Mode에서 네임스페이스 등록/해제가 Pod 재시작 없이 가능한 원리는?

**의도**: Sidecar Mode와의 아키텍처적 차이, CNI 레벨 동작 원리 이해

**키포인트**:

1. **Sidecar Mode**: Pod 내에 sidecar 컨테이너가 필요 → Pod 스펙 변경 → 재시작 필수
2. **Ambient Mode**: ztunnel이 노드 레벨에서 동작. Istio CNI가 Pod의 네트워크 네임스페이스에 iptables 규칙을 동적으로 삽입/제거하여 트래픽을 ztunnel로 리다이렉트
3. **라벨 변경 시**: istio-cni DaemonSet이 라벨 변경 이벤트를 감지 → 해당 Pod의 netns에 리다이렉트 규칙 추가/제거 → Pod 프로세스 영향 없음

**꼬리질문 1**: "Pod 재시작 불필요"라고 했는데, 기존 TCP 연결도 바로 mTLS로 전환되나요?

> 아니다. 이미 열린 TCP 연결은 평문으로 유지된다. 새로 생성되는 연결부터 ztunnel을 통해 mTLS가 적용된다. 완전한 전환을 위해서는 기존 연결이 닫히고 새 연결이 맺어져야 한다. 긴 수명의 커넥션 풀(
> DB 커넥션 등)은 수동으로 재연결을 트리거하거나, 롤링 재시작을 고려해야 할 수 있다.

**꼬리질문 2**: 개발자가 실수로 kube-system에 ambient 라벨을 붙이면 어떻게 방지하나요?

> OPA Gatekeeper 정책으로 방지한다. 특정 네임스페이스(kube-system, monitoring, kong-system)에 `istio.io/dataplane-mode=ambient` 라벨을 붙이는
> 것을 차단하는 Constraint를 배포. 이것이 OPA와 Istio가 함께 동작하는 거버넌스의 예시이다.

---

#### Q2. Cilium + Istio CNI 체이닝에서 CNI 플러그인 순서가 바뀌면 어떤 문제가 생기나요?

**의도**: CNI 체이닝의 동작 원리를 정확히 이해하는지 확인

**키포인트**:

1. **정상 순서 (Cilium → Istio CNI)**: Cilium이 veth 생성 + IP 할당 → Istio CNI가 netns에 리다이렉트 규칙 삽입
2. **역순 시 문제**: Istio CNI가 먼저 실행되면 아직 네트워크 인터페이스가 없어 리다이렉트 규칙 삽입 실패 → Pod 네트워크 설정 실패 → CrashLoopBackOff
3. **cni.exclusive=false의 중요성**: Cilium 기본값은 `exclusive=true`로 다른 CNI 설정 파일을 삭제. 이를 false로 설정하지 않으면 Istio CNI 설정이 지워져
   체이닝 자체가 불가능

**꼬리질문 1**: CNI 플러그인 순서는 어떻게 결정되나요?

> `/etc/cni/net.d/` 디렉토리에서 파일명 알파벳 순서로 실행된다. Cilium은 보통 `05-cilium.conflist`, Istio는 기존 CNI 설정에 자신을 chained plugin으로
> 추가한다. Istio CNI는 "primary CNI가 아닌 extension"으로 동작하므로, Cilium의 conflist 안에 chained plugin으로 등록되는 형태이다.

**꼬리질문 2**: socketLB.hostNamespaceOnly=true를 빠뜨리면 구체적으로 어떤 증상이 나타나나요?

> Cilium이 Pod 네임스페이스에서도 소켓 레벨 로드밸런싱을 수행한다. 이 경우 Pod에서 나가는 트래픽이 Cilium에 의해 직접 목적지로 리다이렉트되어 ztunnel을 **우회**한다. 결과적으로 mTLS가
> 적용되지 않고 평문 통신이 되며, Hubble에서는 정상적으로 보이지만 실제로는 메시 밖에서 통신하는 보안 구멍이 생긴다.

---

#### Q3. 새 서비스를 배포할 때 보안 설정이 자동으로 적용되는 흐름을 처음부터 끝까지 설명해 주세요.

**의도**: 전체 보안 스택의 end-to-end 이해

**키포인트**:

1. **배포 시점 (OPA Gatekeeper)**: `kubectl apply` → API Server → Gatekeeper webhook이 가로챔 → 리소스 제한 있는지, 특권 컨테이너 아닌지,
   Security Context 올바른지 검증 → 통과 시 etcd 저장
2. **Pod 생성 (CNI 체이닝)**: kubelet이 Pod 생성 → Cilium CNI가 네트워크 설정 → Istio CNI가 ztunnel 리다이렉트 설정 (네임스페이스가 ambient 라벨인 경우)
3. **런타임 (mTLS + WireGuard)**: Pod가 통신 시작 → ztunnel이 자동으로 mTLS 래핑 (HBONE 15008/tcp) → 노드 간 이동 시 WireGuard(51871/udp)가 추가
   암호화
4. **감사 (Audit)**: 60초마다 Gatekeeper가 캐시에서 기존 리소스 스캔 → 위반 발견 시 Event 발행

**꼬리질문 1**: 이 흐름에서 OPA 정책을 통과했지만, Security Context를 빠뜨린 Pod가 배포된 경우 어떻게 감지하나요?

> OPA 정책이 올바르게 작성되어 있다면 admission에서 차단된다. 그러나 정책에 누락이 있을 수 있으므로, audit 주기(60초)에서 기존 리소스를 재검사하여 사후 감지한다. 또한 Pod Security
> Admission(PSA)을 OPA와 병행하여 이중 검증할 수 있다. 궁극적으로는 Helm 차트 템플릿에 Security Context를 하드코딩하여 "설정 누락 자체를 불가능하게" 하는 것이 가장 효과적이다.

**꼬리질문 2**: 이 보안 흐름에서 개발자가 가장 많이 막히는 지점은 어디인가요?

> OPA Gatekeeper의 admission 거부이다. "왜 배포가 안 되지?"라는 문의가 가장 많다. 이를 해결하기 위해: (1) 거부 메시지에 구체적인 위반 내용과 수정 방법을 포함, (2) CI
> 파이프라인에서 `conftest`로 사전 검증하여 클러스터 배포 전에 위반을 감지, (3) 표준 Helm 차트 라이브러리에 Security Context를 내장하여 개발자가 신경 쓸 필요 없게 만드는 것이
> 이상적이다.

---

### 팀원5: 정유진 — CI/CD 엔지니어 (5년차)

> "보안 설정이 배포 파이프라인에 어떤 영향을 주는지, 자동화할 수 있는지가 관심사다."

#### Q1. OPA Gatekeeper 정책을 CI/CD 파이프라인에 통합하는 방법은?

**의도**: Shift Left Security의 실제 구현, 파이프라인 설계 역량 확인

**키포인트**:

1. **conftest**: OPA/Rego 정책으로 매니페스트를 사전 검증. CI 단계에서 `conftest test deployment.yaml -p policies/`로 클러스터 배포 전 위반 감지
2. **Gatekeeper와 동일 정책 재사용**: ConstraintTemplate의 Rego를 conftest 정책으로 변환 가능 → 단일 소스 정책(Single Source of Truth)
3. **파이프라인 단계**:
   `lint → conftest (OPA 검증) → helm template → conftest (렌더링된 매니페스트 검증) → deploy → Gatekeeper admission (최종 방어선)`

**꼬리질문 1**: conftest와 Gatekeeper에서 동일한 정책을 관리하면 동기화 문제가 생기지 않나요?

> 동기화 문제를 피하기 위해 Rego 정책을 Git 저장소에 단일 소스로 관리하고, CI에서 conftest용과 Gatekeeper용(ConstraintTemplate) 형태를 자동 생성하는 것이 이상적이다. 또는
> kustomize/Helm으로 ConstraintTemplate을 배포하면서 동시에 conftest 정책 디렉토리에 심볼릭 링크하는 방식도 있다. 핵심은 "한 곳에서 수정하면 양쪽에 반영"되는 구조이다.

**꼬리질문 2**: Gatekeeper 정책 변경이 기존 배포된 리소스에 영향을 주나요?

> 새 정책은 **새로운 배포에만** admission webhook으로 적용된다. 기존 리소스에는 audit 주기(60초)에서 위반으로 "감지"되지만 자동 삭제/수정되지는 않는다. 기존 위반 리소스를 정리하려면
> 별도의 remediation 프로세스(예: CronJob으로 위반 리소스 리포트 → 팀별 수정 요청)가 필요하다.

---

#### Q2. Istio Ambient Mode 적용이 배포 프로세스에 미치는 영향은 Sidecar 대비 어떻게 다른가요?

**의도**: 배포 파이프라인 관점에서의 Ambient Mode 장점 이해

**키포인트**:

1. **Sidecar Mode 배포**: namespace에 istio-injection=enabled → 모든 신규 Pod에 sidecar 자동 주입 → Pod 스펙 변경 → 리소스 플래닝 복잡 (sidecar
   리소스 별도 계산 필요)
2. **Ambient Mode 배포**: namespace에 istio.io/dataplane-mode=ambient → Pod 스펙 변경 없음 → Helm 차트/매니페스트 수정 불필요 → **기존 CI/CD
   파이프라인 변경 0**
3. **Istio 업그레이드 시**: Sidecar는 모든 Pod 롤링 재시작 필요 (sidecar 이미지 교체). Ambient는 ztunnel DaemonSet만 업데이트 → **배포 중단 없음**

**꼬리질문 1**: Ambient Mode에서 특정 Pod만 메시에서 제외하려면 어떻게 하나요?

> Pod에 `istio.io/dataplane-mode=none` 어노테이션을 설정한다. 네임스페이스는 ambient이지만 특정 Pod만 제외 가능. 이를 Helm values에서 관리하면 배포 파이프라인에서
> 서비스별로 메시 참여 여부를 제어할 수 있다.

**꼬리질문 2**: ArgoCD로 Istio와 Gatekeeper를 관리할 때 주의할 점은?

> (1) Gatekeeper CRD(ConstraintTemplate, Constraint)는 Sync Wave로 순서를 보장해야 한다 (CRD → ConstraintTemplate → Constraint). (

2) Istio CRD와 Gatekeeper가 동시에 배포되면 webhook 충돌 가능 → ArgoCD Application 분리 권장. (3) Gatekeeper webhook이 ArgoCD 자체의 배포를 차단하지
   않도록 argocd 네임스페이스를 Gatekeeper의 exemptNamespaces에 등록하는 것이 중요하다.

---

#### Q3. ServiceEntry(REGISTRY_ONLY)와 OPA 정책을 GitOps로 관리하는 전략은?

**의도**: 보안 정책의 코드화(Policy as Code) 이해

**키포인트**:

1. **ServiceEntry 관리**: Git 저장소에 ServiceEntry 매니페스트를 관리. 개발팀이 PR로 외부 서비스 등록 요청 → 보안팀 리뷰 → merge → ArgoCD 자동 배포
2. **OPA 정책 관리**: ConstraintTemplate과 Constraint를 별도 Git 저장소에서 관리. 정책 변경 시 PR 기반 리뷰 + conftest 자동 테스트
3. **거버넌스 흐름**: `개발자 PR → 자동 conftest 검증 → 보안 리뷰어 승인 → merge → ArgoCD sync → Gatekeeper/Istio 적용`

**꼬리질문 1**: ServiceEntry에 등록할 수 있는 외부 도메인을 제한하려면 어떻게 하나요?

> OPA Gatekeeper로 ServiceEntry 리소스를 검증한다. 허용된 도메인 리스트를 Constraint의 parameters로 관리하고, 리스트에 없는 도메인이 포함된 ServiceEntry는
> admission에서 거부. 이렇게 하면 개발자가 ServiceEntry를 자유롭게 생성하되, 허용된 범위 내에서만 가능하다.

**꼬리질문 2**: 정책 변경이 프로덕션에 즉시 반영되면 위험하지 않나요?

> 맞다. Gatekeeper는 enforcementAction 필드를 지원한다: `dryrun`(위반 감지만, 차단 안 함) → `warn`(경고 표시, 차단 안 함) → `deny`(차단). 새 정책은 반드시
> dryrun으로 배포하여 audit 결과를 확인한 후, 영향 범위가 확인되면 점진적으로 deny로 전환하는 프로세스가 필수이다.

---

### 팀원6: 한소윤 — Engineering Manager (10년차)

> "기술 선택의 비즈니스 임팩트와 의사결정 과정을 본다. 1인 DevOps로서의 우선순위 설정 능력이 핵심이다."

#### Q1. 1인 DevOps로서 이 보안 스택의 운영 부담을 어떻게 관리하고 있나요?

**의도**: 기술적 역량뿐 아니라 우선순위 설정, 자동화 전략, 실용적 판단력 확인

**키포인트**:

1. **자동화 우선**: Helm 차트에 Security Context 내장 → 개발자가 보안을 "선택"이 아닌 "기본값"으로 받음. OPA 정책으로 비표준 배포 자동 차단
2. **계층별 관리 포인트 최소화**: Cilium WireGuard(설정 1줄), Ambient Mode(네임스페이스 라벨 1줄), OPA(템플릿 기반 정책 재사용). 각 컴포넌트가 "set and forget"
   에 가깝도록 설계
3. **관측성 기반 운영**: Hubble + Prometheus + Grafana로 보안 이벤트(drop, policy violation, mTLS 실패) 자동 알림. 사전 감지가 사후 대응보다 비용이 낮음

**꼬리질문 1**: 이 보안 스택 중 가장 먼저 도입한 것과 가장 나중에 도입한 것은 무엇이고, 그 순서의 이유는?

> Cilium CNI가 가장 먼저 (네트워크 기반). OPA Gatekeeper가 그 다음 (거버넌스 기반). Istio Ambient가 가장 나중 (서비스 메시는 서비스가 충분히 늘어난 후에 의미). 인프라
> 레이어 → 정책 레이어 → 서비스 레이어 순으로 bottom-up 접근. 이 순서가 중요한 이유는, 상위 계층은 하위 계층이 안정화된 후에 도입해야 문제 발생 시 원인 격리가 가능하기 때문이다.

**꼬리질문 2**: 3년차에 대기업으로 이직하면, 이 보안 스택 운영 경험이 어떤 차별점이 된다고 생각하나요?

> 대기업은 보통 보안팀과 인프라팀이 분리되어 있어 "왜 이 설정이 필요한지" 크로스 팀 커뮤니케이션이 필수이다. 1인 DevOps로서 보안 설계부터 구현, 운영까지 E2E 경험은 보안팀의 요구사항을 이해하면서
> 인프라에 반영할 수 있는 "번역자" 역할을 할 수 있다는 점이 차별점이다. 또한 Zero Trust를 계층적으로 구현한 경험은 대기업의 컴플라이언스(SOC2, ISO27001) 요구사항과 직결된다.

---

#### Q2. mTLS를 전 서비스에 적용하면서 성능 오버헤드는 어떻게 측정하고 관리하나요?

**의도**: 보안의 비용(성능)을 인식하고 데이터 기반으로 판단하는지 확인

**키포인트**:

1. **Ambient Mode 선택 자체가 오버헤드 최소화**: ztunnel ~50m CPU, ~64Mi 메모리로 Sidecar 대비 ~95% 리소스 절약. HBONE HTTP/2 멀티플렉싱으로 연결 수도 최소화
2. **측정 지표**: (1) P99 latency 변화 (mTLS 핸드셰이크 오버헤드), (2) CPU 사용량 변화 (TLS 암호화/복호화), (3) ztunnel 메모리 사용량 추이
3. **관리 전략**: 성능 민감 서비스(예: 실시간 게임 서버)는 Ambient에서 제외하고 WireGuard로만 보호하는 선택적 적용 가능. "전부 또는 전무"가 아닌 **서비스별 보안 수준 차등 적용**

**꼬리질문 1**: Ambient Mode에서 제외한 3개 네임스페이스(kong-system, monitoring, kube-system)를 선택한 기준은?

> (1) **kube-system**: 클러스터 핵심 컴포넌트의 blast radius 격리, (2) **monitoring**: Prometheus scrape 경로의 mTLS 복잡도 vs 실익 판단, (3) *
*kong-system**: 인그레스 컨트롤러는 외부 → 내부 트래픽의 진입점으로, 별도의 TLS 종료 설정이 있어 이중 암호화 불필요. 공통 기준은 "메시 포함 시 복잡도 대비 보안 이득이 작거나, 장애 시
> blast radius가 너무 큰 경우"이다.

**꼬리질문 2**: 보안 설정으로 인해 서비스 장애가 발생한 경험이 있다면 공유해 주세요.

> (예상 답변 방향) STRICT mTLS 적용 후 Ambient에 등록되지 않은 서비스에서 메시 내부 서비스로 요청이 거부된 경험. 원인은 PERMISSIVE → STRICT 전환 시 모든 클라이언트가 mTLS를
> 지원하는지 확인하지 않은 것. 교훈: STRICT 전환 전 반드시 PERMISSIVE에서 Hubble/Kiali로 평문 트래픽 존재 여부를 확인하고, 남아있는 평문 통신을 모두 처리한 후에 전환해야 한다.

---

#### Q3. 이 보안 아키텍처의 한계점과 개선 방향은?

**의도**: 자기 설계의 한계를 인식하는지, 성장 방향성이 있는지 확인

**키포인트**:

1. **현재 한계**: (1) L7 정책 부재 — Waypoint 미배포로 HTTP 헤더/경로 기반 세밀한 인가 불가, (2) 런타임 보안 부재 — Falco 등 런타임 위협 탐지 도구 미적용, (3) 이미지
   스캐닝 부재 — CI에서 Trivy/Grype 등 취약점 스캐닝 미통합
2. **개선 방향**: (1) Waypoint Proxy 도입으로 필요한 서비스에 L7 AuthorizationPolicy 적용, (2) Falco 또는 Tetragon(eBPF 기반)으로 런타임 시스템콜
   모니터링, (3) 이미지 서명(cosign/sigstore) + 스캐닝을 CI/CD에 통합
3. **우선순위 판단**: 1인 DevOps에서 모든 것을 한 번에 할 수 없음. "현재 보안 수준으로 비즈니스 리스크가 수용 가능한가"를 기준으로 단계적 도입

**꼬리질문 1**: Falco와 Tetragon 중 어떤 것을 선택하시겠습니까?

> Tetragon을 선택할 것이다. 이미 Cilium(eBPF 기반)을 사용하고 있으므로 기술 스택 일관성이 있고, Tetragon은 Cilium 프로젝트의 일부로 eBPF 기반 런타임 보안을 제공한다.
> Falco는 커널 모듈 또는 eBPF 기반이지만 별도의 프로젝트이므로, 기존 Cilium 에코시스템과의 통합 시너지가 Tetragon이 더 크다.

**꼬리질문 2**: 보안 아키텍처를 처음부터 다시 설계한다면 달라지는 부분이 있나요?

> (1) OPA Gatekeeper 대신 Kyverno를 검토했을 것 — Rego 학습 곡선이 높고, YAML 네이티브 정책이 DevOps 친화적. (2) Istio 대신 Cilium Service Mesh를
> 검토했을 것 — Cilium이 자체 mTLS와 L7 정책을 제공하므로 컴포넌트 수 감소. 단, 두 선택 모두 트레이드오프가 있으며 (Kyverno는 복잡한 정책에서 OPA 대비 표현력 부족, Cilium SM은
> Istio 대비 기능 미성숙), 현재 선택이 잘못된 것은 아니다.

---

## 부록: 핵심 설정값 빠른 참조

```yaml
# Cilium
kubeProxyReplacement: "true"
encryption.enabled: true
encryption.type: wireguard
hubble.metrics: "dns,drop,tcp,flow,icmp,http"
prometheus.enabled: true
socketLB.hostNamespaceOnly: true
cni.exclusive: false

# Istio Ambient
istio.io/dataplane-mode: ambient     # 메시 등록
istio.io/dataplane-mode: none        # 메시 제외
istiod.replicaCount: 2
outboundTrafficPolicy.mode: REGISTRY_ONLY
PeerAuthentication.mtls.mode: STRICT

# OPA Gatekeeper
replicas: 2
audit.auditInterval: 60
audit.auditFromCache: true
emitAdmissionEvents: true
emitAuditEvents: true

# Pod Security Context
runAsNonRoot: true
allowPrivilegeEscalation: false
capabilities.drop: [ ALL ]
readOnlyRootFilesystem: true
seccompProfile.type: RuntimeDefault
```

---

## 참고 문서

- [Cilium 공식 — Kubernetes Without kube-proxy](https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/)
- [Cilium 공식 — WireGuard Transparent Encryption](https://docs.cilium.io/en/stable/security/network/encryption-wireguard/)
- [Cilium 공식 — Integration with Istio](https://docs.cilium.io/en/latest/network/servicemesh/istio/)
- [Istio 공식 — Ambient Mode Overview](https://istio.io/latest/docs/ambient/overview/)
- [Istio 공식 — Ambient Architecture](https://istio.io/latest/docs/ambient/architecture/)
- [Istio 공식 — Ambient Data Plane](https://istio.io/latest/docs/ambient/architecture/data-plane/)
- [Istio 공식 — Traffic Redirection](https://istio.io/latest/docs/ambient/architecture/traffic-redirection/)
- [Istio 공식 — Platform Prerequisites (Cilium)](https://istio.io/latest/docs/ambient/install/platform-prerequisites/)
- [Istio 공식 — Rust-Based Ztunnel](https://istio.io/latest/blog/2023/rust-based-ztunnel/)
- [OPA Gatekeeper 공식 문서](https://open-policy-agent.github.io/gatekeeper/website/)
- [Kubernetes — OPA Gatekeeper Policy and Governance](https://kubernetes.io/blog/2019/08/06/opa-gatekeeper-policy-and-governance-for-kubernetes/)
- [Cilium CNI Performance Benchmark](https://docs.cilium.io/en/latest/operations/performance/benchmark/)
