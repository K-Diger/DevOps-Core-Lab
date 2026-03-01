# Cilium CNI 핸즈온 랩

## 학습 목표

1. eBPF 기반 kube-proxy 대체 동작 원리 이해 및 확인
2. WireGuard transparent encryption 관찰
3. Hubble로 L3-L7 네트워크 플로우 시각화
4. CiliumNetworkPolicy를 통한 L3/L4 트래픽 제어

## 전제 조건

- Kind 클러스터 실행 중: `kind get clusters`
- Cilium 설치 완료: `cilium status`

### UI 접속 정보

| 항목 | 값 |
|------|-----|
| **Kong URL (권장)** | `http://hubble.lab-dev.local` |
| **Fallback (port-forward)** | `kubectl port-forward -n kube-system svc/hubble-ui 12000:80` → `http://localhost:12000` |
| **인증** | 없음 (별도 로그인 불필요) |

---

## 실습 1: kube-proxy 대체 확인

### 배경 지식

kube-proxy는 iptables 규칙으로 ClusterIP → Pod 라우팅을 처리한다.
서비스가 N개일 때 iptables 규칙은 O(N)으로 증가하며, 규칙 업데이트 시 전체 체인을 재생성한다.

Cilium의 eBPF는 해시 테이블 기반 O(1) 룩업으로 서비스 수에 관계없이 일정한 성능을 제공한다.

### 확인 방법

```bash
# 1. kube-proxy Pod가 없음을 확인
kubectl get pods -n kube-system | grep kube-proxy
# (출력 없어야 함 — Kind config에서 kubeProxyMode: "none")

# 2. Cilium 상태에서 KubeProxyReplacement 확인
cilium status | grep KubeProxyReplacement
# 출력: KubeProxyReplacement: True

# 3. eBPF 서비스 맵 확인 (iptables 대신 eBPF가 라우팅)
kubectl -n kube-system exec ds/cilium -- cilium-dbg service list
# ClusterIP 서비스들이 eBPF 맵에 등록되어 있음을 확인

# 4. iptables 규칙이 비어있음을 확인
kubectl -n kube-system exec ds/cilium -- iptables-legacy -t nat -L KUBE-SERVICES 2>/dev/null
# (규칙 없음 — kube-proxy가 없으므로)
```

### 핵심 포인트

> Q: "kube-proxy를 왜 대체했나요?"
> A: iptables 기반 kube-proxy는 서비스 수에 비례하여 O(N) 룩업이 발생한다.
> 1000개 서비스 환경에서 iptables 규칙 업데이트에 수 초가 걸리며,
> 그동안 새로운 연결이 잘못된 Pod로 라우팅될 수 있다.
> Cilium eBPF는 해시 테이블 기반 O(1) 룩업으로 이 문제를 해결한다.

---

## 실습 2: Hubble 네트워크 플로우 관찰

### 배경 지식

Hubble은 Cilium의 eBPF 데이터플레인에서 직접 네트워크 이벤트를 수집한다.
tcpdump가 패킷을 복사(copy)하여 userspace로 전달하는 것과 달리,
Hubble은 eBPF 링 버퍼에서 zero-copy로 구조화된 이벤트를 읽는다.

### 실습 단계

```bash
# 1. Hubble CLI로 실시간 플로우 관찰
hubble observe --follow

# 2. 특정 네임스페이스만 필터
hubble observe -n demo --follow

# 3. HTTP 트래픽만 관찰
hubble observe --protocol http --follow

# 4. DNS 쿼리 관찰
hubble observe --type l7 --protocol dns --follow

# 5. Drop된 패킷만 관찰 (정책에 의해 차단된 트래픽)
hubble observe --verdict DROPPED --follow

# 6. Hubble UI 접속 (port-forward)
kubectl port-forward -n kube-system svc/hubble-ui 12000:80
# 브라우저: http://localhost:12000
```

#### UI에서 확인

1. **네임스페이스 선택**: Hubble UI 상단 드롭다운에서 `demo` 네임스페이스 선택
2. **Service Map 해석**:
   - **노드(원)** = Pod 또는 Service (이름이 라벨로 표시됨)
   - **화살표** = 트래픽 방향 (출발지 → 목적지)
   - **초록색 화살표** = 허용된(FORWARDED) 트래픽
   - **빨간색 화살표** = 차단된(DROPPED) 트래픽
   - 화살표 위에 마우스를 올리면 프로토콜, 포트, verdict 등 상세 정보 표시
3. **플로우 목록 확인**: 하단 플로우 테이블에서 개별 네트워크 이벤트 확인
   - Source / Destination / Verdict / Type 칼럼으로 트래픽 분석
   - `hubble observe` CLI 출력과 동일한 데이터가 UI에 표시됨을 확인

#### CLI ↔ UI 대조

```bash
# 터미널에서 hubble observe 실행
hubble observe -n demo --last 10
# 출력된 플로우(Source → Destination, Verdict)가
# Hubble UI 하단 플로우 목록과 동일한 데이터임을 확인
```

### 핵심 포인트

> Q: "네트워크 문제를 어떻게 디버깅하나요?"
> A: Hubble을 사용한다. hubble observe --verdict DROPPED으로 NetworkPolicy에 의해
> 차단된 트래픽을 실시간으로 확인할 수 있다. tcpdump와 달리 eBPF 레벨에서
> 소스/목적지 Pod 이름, 네임스페이스, 정책 이름까지 확인 가능하다.

---

## 실습 3: WireGuard 암호화 확인

### 배경 지식

WireGuard는 노드 간 모든 Pod 트래픽을 투명하게 암호화한다.
애플리케이션 코드 변경 없이 L3 레벨에서 자동 적용된다.

### 확인 방법

```bash
# 1. Cilium 상태에서 암호화 확인
cilium status | grep Encryption
# 출력: Encryption: Wireguard [NodeEncryption: Disabled, ...]

# 2. WireGuard 인터페이스 확인
kubectl -n kube-system exec ds/cilium -- cilium-dbg encrypt status
# WireGuard 터널 정보 및 피어 노드 확인

# 3. 노드 간 암호화된 트래픽 확인 (Hubble)
hubble observe --from-namespace demo --to-namespace demo --follow
# is-encrypted 필드가 true인지 확인
```

---

## 실습 4: NetworkPolicy 적용

### 실습 단계

```bash
# 1. 정책 적용 전: 외부 통신 가능
kubectl -n demo exec deploy/frontend -- wget -qO- https://httpbin.org/ip --timeout=5
# (응답 받음)

# 2. Egress 차단 정책 적용
kubectl apply -f policies/deny-external-egress.yaml

# 3. 정책 적용 후: 외부 통신 차단
kubectl -n demo exec deploy/frontend -- wget -qO- https://httpbin.org/ip --timeout=5
# (타임아웃 — 차단됨)

# 4. 클러스터 내부 통신은 여전히 가능
kubectl -n demo exec deploy/frontend -- wget -qO- http://backend:8080 --timeout=5
# (응답 받음)

# 5. Hubble에서 DROP 확인
hubble observe -n demo --verdict DROPPED
# deny-external-egress 정책에 의해 차단된 패킷 확인

# 6. 모니터링 허용 정책 적용
kubectl apply -f policies/allow-monitoring.yaml
```

#### UI에서 확인

1. **DROPPED 트래픽 시각화**: Hubble UI에서 `demo` 네임스페이스를 선택한 상태에서
   - 정책 적용 전: 모든 화살표가 초록색 (FORWARDED)
   - `deny-external-egress.yaml` 적용 후: 외부 통신 시도 시 **빨간색 화살표**가 나타남
   - 빨간색 화살표 클릭 → verdict: `DROPPED`, 정책 이름 확인 가능
2. **내부 트래픽 확인**: `frontend` → `backend` 화살표는 여전히 초록색
   - 정책이 외부 egress만 차단하고 클러스터 내부 통신은 허용함을 시각적으로 확인
3. **CLI 결과와 대조**:
   ```bash
   # CLI에서 DROPPED 확인
   hubble observe -n demo --verdict DROPPED --last 5
   # UI 플로우 목록의 빨간색 행과 동일한 Source/Destination/Reason이 표시됨
   ```

### 핵심 포인트

> Q: "NetworkPolicy를 어떻게 운영하나요?"
> A: 기본 거부(deny-all) 정책을 먼저 적용한 후, 필요한 통신만 명시적으로 허용한다.
> 모니터링 시스템은 모든 네임스페이스에 접근해야 하므로 별도 허용 정책을 구성한다.
> 정책 적용 후 Hubble로 DROP 이벤트를 모니터링하여 의도하지 않은 차단을 감지한다.
