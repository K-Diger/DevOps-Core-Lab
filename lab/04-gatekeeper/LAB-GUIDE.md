# OPA Gatekeeper 실습 가이드

## 목차

1. [사전 준비](#1-사전-준비)
2. [정책 위반 테스트](#2-정책-위반-테스트)
3. [enforcementAction: deny vs audit 차이 실습](#3-enforcementaction-deny-vs-audit-차이-실습)
4. [Audit 결과 확인](#4-audit-결과-확인)
5. [Gatekeeper Event 확인](#5-gatekeeper-event-확인)
6. [ConstraintTemplate Rego 정책 작성법](#6-constrainttemplate-rego-정책-작성법)
7. [Q&A 종합 정리](#7-qa-종합-정리)

---

## 1. 사전 준비

### 설치 및 정책 적용

```bash
# Gatekeeper 설치 + 정책 적용 (한 번에)
./install.sh

# demo 네임스페이스 생성 (정책 적용 대상)
kubectl create namespace demo
```

### 설치 확인

```bash
# Pod 상태 확인
kubectl get pods -n gatekeeper-system

# 기대 결과:
# NAME                                             READY   STATUS    RESTARTS   AGE
# gatekeeper-audit-xxxxx                           1/1     Running   0          1m
# gatekeeper-controller-manager-xxxxx              1/1     Running   0          1m

# ConstraintTemplate 확인
kubectl get constrainttemplates
# NAME                        AGE
# k8sdenyprivileged           1m
# k8srequirelabels            1m
# k8srequirenonroot           1m
# k8srequireresourcelimits    1m

# Constraint 확인
kubectl get constraints
```

---

## 2. 정책 위반 테스트

### 2.1 Resource Limits 없는 Pod (거부되어야 함)

```bash
# limits 없이 Pod 생성 시도
kubectl run no-limits --image=nginx -n demo

# 기대 결과: 거부됨
# Error from server (Forbidden): admission webhook "validation.gatekeeper.sh" denied the request:
# [require-resource-limits] 컨테이너 'no-limits'에 memory limits가 설정되지 않았습니다...
```

> **핵심 포인트**: "limits가 없으면 어떤 문제가 발생하나요?"
> - **Noisy Neighbor**: 한 Pod이 노드의 CPU/Memory를 독점 → 같은 노드의 다른 Pod이 OOMKilled
> - **Scheduler 문제**: limits 기반으로 Bin Packing 불가 → 리소스 낭비 또는 과밀 배치
> - **QoS 클래스**: limits 없으면 BestEffort → 리소스 압박 시 가장 먼저 eviction 대상

### 정상 배포 (모든 정책 충족)

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: good-pod
  namespace: demo
  labels:
    app: test
    team: platform
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
  containers:
    - name: nginx
      image: nginx
      securityContext:
        privileged: false
      resources:
        requests:
          cpu: 50m
          memory: 64Mi
        limits:
          cpu: 100m
          memory: 128Mi
EOF

# 기대 결과: pod/good-pod created
```

### 2.2 Privileged 컨테이너 (거부되어야 함)

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: privileged-pod
  namespace: demo
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
  containers:
    - name: nginx
      image: nginx
      securityContext:
        privileged: true
      resources:
        limits:
          cpu: 100m
          memory: 128Mi
EOF

# 기대 결과: 거부됨
# "컨테이너 'nginx'가 privileged 모드로 실행됩니다. 보안 위험: 호스트 전체 접근 가능."
```

> **핵심 포인트**: "privileged 컨테이너는 왜 위험한가요?"
> - **호스트 디바이스 접근**: /dev 아래 모든 디바이스 읽기/쓰기 가능
> - **커널 모듈 로드**: insmod/modprobe로 커널 모듈 삽입 가능
> - **컨테이너 탈출**: namespace/cgroup 제한 해제 → 호스트 프로세스 조작
> - **CIS Benchmark 5.2.1**: "Minimize the admission of privileged containers"

### 2.3 Root 사용자 실행 Pod (거부되어야 함)

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: root-pod
  namespace: demo
spec:
  containers:
    - name: nginx
      image: nginx
      securityContext:
        privileged: false
      resources:
        limits:
          cpu: 100m
          memory: 128Mi
EOF

# 기대 결과: 거부됨
# "Pod securityContext에 runAsNonRoot: true가 설정되지 않았습니다."
```

> **핵심 포인트**: "runAsNonRoot는 어떻게 동작하나요?"
> - kubelet이 컨테이너 시작 시 UID 검사
> - UID 0이면 컨테이너 시작 거부 (CrashLoopBackOff)
> - Dockerfile의 USER 지시자와 함께 사용 권장
> - runAsUser로 특정 UID 지정 가능 (예: 1000)

### 2.4 필수 라벨 누락 Deployment (거부되어야 함)

```bash
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: no-labels-deploy
  namespace: demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test
  template:
    metadata:
      labels:
        app: test
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
      containers:
        - name: nginx
          image: nginx
          securityContext:
            privileged: false
          resources:
            limits:
              cpu: 100m
              memory: 128Mi
EOF

# 기대 결과: 거부됨
# "필수 라벨 'team'이(가) 없습니다. 리소스 관리를 위해 반드시 설정하세요."
```

> **핵심 포인트**: "라벨 정책은 어떤 수준에서 적용해야 하나요?"
> - **Deployment 메타데이터**: 리소스 소유권, 비용 할당 목적
> - **Pod 템플릿 라벨**: Service selector, 모니터링 대상 식별 목적
> - 프로덕션에서는 `app`, `team`, `env`, `version` 라벨 필수가 일반적

---

## 3. enforcementAction: deny vs audit 차이 실습

### 3.1 개념 설명

| enforcementAction | Admission 단계 | Audit 단계 | 용도           |
|-------------------|--------------|----------|--------------|
| `deny`            | 차단           | 위반 기록    | 프로덕션 강제      |
| `dryrun`          | 허용           | 위반 기록    | 정책 영향도 사전 평가 |
| `warn`            | 허용 (경고 표시)   | 위반 기록    | 단계적 정책 도입    |

### 3.2 실습: deny → dryrun 변경

```bash
# 현재 상태: deny (리소스 생성 차단)
kubectl get k8srequireresourcelimits require-resource-limits -o jsonpath='{.spec.enforcementAction}'
# 출력: deny

# dryrun으로 변경 (정책 위반을 기록만 하고 차단하지 않음)
kubectl patch k8srequireresourcelimits require-resource-limits \
  --type=merge -p '{"spec":{"enforcementAction":"dryrun"}}'

# 이제 limits 없는 Pod 생성 가능 (차단 안 됨)
kubectl run test-dryrun --image=nginx -n demo
# 기대 결과: pod/test-dryrun created (차단되지 않음!)

# 하지만 Audit에서 위반으로 기록됨 (60초 대기 후 확인)
sleep 65
kubectl get k8srequireresourcelimits require-resource-limits -o yaml | grep -A 20 "violations"

# 테스트 후 정리
kubectl delete pod test-dryrun -n demo --ignore-not-found
kubectl patch k8srequireresourcelimits require-resource-limits \
  --type=merge -p '{"spec":{"enforcementAction":"deny"}}'
```

> **핵심 포인트**: "새 정책을 프로덕션에 어떻게 안전하게 도입하나요?"
> - **Step 1**: `dryrun`으로 배포 → Audit 결과로 영향도 파악
> - **Step 2**: 위반 리소스 수정 완료 확인
> - **Step 3**: `warn`으로 전환 → 개발팀에 경고 노출
> - **Step 4**: `deny`로 전환 → 강제 적용
> - 이 패턴을 **Progressive Policy Rollout**이라 함

### 3.3 실습: warn 모드

```bash
# warn 모드로 변경
kubectl patch k8srequireresourcelimits require-resource-limits \
  --type=merge -p '{"spec":{"enforcementAction":"warn"}}'

# limits 없는 Pod 생성 시도
kubectl run test-warn --image=nginx -n demo
# 기대 결과: 생성은 되지만 Warning 메시지 표시
# Warning: [require-resource-limits] 컨테이너 'test-warn'에 memory limits가...

# 정리
kubectl delete pod test-warn -n demo --ignore-not-found
kubectl patch k8srequireresourcelimits require-resource-limits \
  --type=merge -p '{"spec":{"enforcementAction":"deny"}}'
```

---

## 4. Audit 결과 확인

### 4.1 Constraint의 violations 필드

```bash
# 모든 Constraint의 위반 현황 한눈에 보기
kubectl get constraints

# 특정 Constraint의 상세 위반 목록
kubectl get k8srequireresourcelimits require-resource-limits -o yaml
```

**출력 예시 (violations 섹션)**:

```yaml
status:
  auditTimestamp: "2026-02-27T10:30:00Z"
  totalViolations: 2
  violations:
    - enforcementAction: deny
      kind: Pod
      message: "컨테이너 'nginx'에 memory limits가 설정되지 않았습니다..."
      name: some-pod
      namespace: demo
```

> **핵심 포인트**: "Audit과 Admission의 차이는?"
> - **Admission**: 리소스 생성/수정 시점에 실시간 검사 (ValidatingAdmissionWebhook)
> - **Audit**: 이미 존재하는 리소스를 주기적으로 검사 (auditInterval마다)
> - **왜 둘 다 필요한가?**: 정책 추가 전에 이미 존재하던 위반 리소스를 발견하기 위해

### 4.2 모든 Constraint 위반 현황 조회

```bash
# 모든 Constraint의 totalViolations 확인
kubectl get constraints -o custom-columns=\
'NAME:.metadata.name,ACTION:.spec.enforcementAction,VIOLATIONS:.status.totalViolations'

# 기대 출력:
# NAME                        ACTION   VIOLATIONS
# deny-privileged-container   deny     0
# require-labels              deny     0
# require-non-root            deny     0
# require-resource-limits     deny     0
```

### 4.3 Audit 주기와 캐시

```bash
# Gatekeeper Audit Controller 로그에서 감사 주기 확인
kubectl logs -n gatekeeper-system -l control-plane=audit-controller --tail=20

# auditFromCache 설정 확인
helm get values gatekeeper -n gatekeeper-system -a | grep auditFromCache
```

> **핵심 포인트**: "auditFromCache: true의 트레이드오프는?"
> - **장점**: API 서버 부하 감소 (캐시에서 조회)
> - **단점**: 캐시 동기화 지연 (수 초) → 최신 리소스 상태 반영 지연
> - **대규모 클러스터 필수**: 수천 개 리소스를 매번 API 서버에서 조회하면 etcd 과부하

---

## 5. Gatekeeper Event 확인

### 5.1 Event 조회

```bash
# Gatekeeper 관련 이벤트 확인
kubectl get events -n demo --field-selector reason=FailedAdmission
kubectl get events -n gatekeeper-system

# 모든 네임스페이스의 Gatekeeper 이벤트
kubectl get events -A | grep gatekeeper
```

### 5.2 Event 상세 분석

```bash
# 특정 네임스페이스의 최근 이벤트 (시간순)
kubectl get events -n demo --sort-by='.lastTimestamp'
```

**출력 예시**:

```
LAST SEEN   TYPE      REASON            OBJECT       MESSAGE
10s         Warning   FailedAdmission   pod/badpod   [require-resource-limits] 컨테이너...
```

> **핵심 포인트**: "Gatekeeper 이벤트를 모니터링에 어떻게 활용하나요?"
> - **emitAdmissionEvents: true** → 정책 위반 시도를 Kubernetes Event로 기록
> - **emitAuditEvents: true** → Audit 위반 결과를 Event로 기록
> - Event Exporter(예: kubernetes-event-exporter)로 Elasticsearch/Loki에 전송
> - Grafana 대시보드로 정책 위반 트렌드 시각화
> - Slack 알림 연동으로 보안팀 즉시 인지

---

## 6. ConstraintTemplate Rego 정책 작성법

### 6.1 Rego 기본 구조

```rego
package <패키지명>

# violation 규칙: 조건이 참이면 위반
violation[{"msg": msg}] {
  # 조건 1: input에서 데이터 추출
  container := input.review.object.spec.containers[_]

  # 조건 2: 위반 조건 검사
  not container.resources.limits.memory

  # 위반 메시지 생성
  msg := sprintf("컨테이너 '%v'에 memory limits가 없습니다", [container.name])
}
```

### 6.2 input 구조 이해

```
input
├── review
│   ├── object          # 생성/수정되는 리소스
│   │   ├── metadata
│   │   │   ├── name
│   │   │   ├── namespace
│   │   │   └── labels
│   │   └── spec
│   │       ├── containers[]
│   │       ├── initContainers[]
│   │       └── securityContext
│   ├── oldObject       # 수정 시 이전 상태 (UPDATE only)
│   └── operation       # CREATE, UPDATE, DELETE
└── parameters          # Constraint에서 전달한 파라미터
```

### 6.3 주요 Rego 패턴

**패턴 1: 컨테이너 순회**

```rego
# 모든 컨테이너(일반 + init)를 순회
violation[{"msg": msg}] {
  container := input.review.object.spec.containers[_]
  # 검사 로직...
}

violation[{"msg": msg}] {
  container := input.review.object.spec.initContainers[_]
  # 동일한 검사 로직...
}
```

**패턴 2: 파라미터 사용 (Constraint에서 값 전달)**

```rego
# Constraint의 parameters.labels를 순회
violation[{"msg": msg}] {
  required := input.parameters.labels[_]
  not input.review.object.metadata.labels[required]
  msg := sprintf("라벨 '%v'이 없습니다", [required])
}
```

**패턴 3: 이미지 레지스트리 제한**

```rego
violation[{"msg": msg}] {
  container := input.review.object.spec.containers[_]
  not startswith(container.image, "my-registry.example.com/")
  msg := sprintf("컨테이너 '%v'의 이미지가 허용된 레지스트리가 아닙니다: %v",
    [container.name, container.image])
}
```

**패턴 4: 여러 조건 AND 결합**

```rego
# Rego에서 같은 rule body 안의 조건들은 AND
violation[{"msg": msg}] {
  container := input.review.object.spec.containers[_]
  container.securityContext.privileged == true           # 조건 1 AND
  not input.review.object.metadata.labels["exception"]  # 조건 2
  msg := "..."
}
```

### 6.4 ConstraintTemplate 작성 시 주의사항

| 항목                           | 설명                                   |
|------------------------------|--------------------------------------|
| **metadata.name**            | 소문자, 하이픈 없이 (예: `k8srequirelabels`)  |
| **spec.crd.spec.names.kind** | CamelCase (예: `K8sRequireLabels`)    |
| **패키지명**                     | metadata.name과 동일하게 맞추기              |
| **violation 함수명**            | 반드시 `violation`이어야 함 (Gatekeeper 규약) |
| **반환 형식**                    | `{"msg": msg}` 필수                    |

### 6.5 Rego 정책 테스트 (opa eval)

```bash
# OPA CLI로 로컬 테스트 (Gatekeeper 없이)
# 1. rego 파일 준비
# 2. input.json 준비 (테스트할 리소스)
# 3. opa eval로 검증

opa eval --data policy.rego --input input.json 'data.k8srequireresourcelimits.violation'
```

> **핵심 포인트**: "Rego 정책을 어떻게 테스트하나요?"
> - **Unit Test**: `opa test` 명령으로 Rego 단위 테스트 실행
> - **Conftest**: CI/CD 파이프라인에서 YAML 매니페스트를 배포 전 검증
> - **Gatekeeper Library**: https://github.com/open-policy-agent/gatekeeper-library 에서 검증된 정책 재사용
> - **dry-run=server**: `kubectl apply --dry-run=server`로 Gatekeeper 정책 통과 여부 사전 확인

---

## 7. Q&A 종합 정리

### Q1: "OPA Gatekeeper가 뭔가요? 왜 필요한가요?"

**A**: OPA Gatekeeper는 Open Policy Agent를 Kubernetes Admission Controller로 통합한 프로젝트다.

- **동작 원리**: ValidatingAdmissionWebhook으로 리소스 생성/수정 요청을 가로채어 Rego 정책으로 검증
- **왜 필요한가**: RBAC은 "누가 무엇을 할 수 있는가"를 제어하지만, "리소스가 어떤 형태여야 하는가"는 제어 불가
- **예시**: "모든 Pod에 resource limits 필수", "privileged 컨테이너 금지" 등은 RBAC으로 불가능

### Q2: "ConstraintTemplate과 Constraint의 관계는?"

**A**: 객체지향의 Class와 Instance 관계와 유사하다.

- **ConstraintTemplate**: 정책의 로직(Rego 코드)을 정의 → "어떤 검사를 할 것인가"
- **Constraint**: 정책의 적용 범위와 파라미터를 정의 → "어디에, 어떤 값으로 적용할 것인가"
- **왜 분리했는가**: 같은 정책 로직을 다른 네임스페이스/파라미터로 재사용 가능

### Q3: "Gatekeeper Pod가 죽으면 배포가 안 되나요?"

**A**: `webhookFailurePolicy` 설정에 따라 다릅니다.

- **Fail**: Gatekeeper가 응답 못하면 모든 리소스 생성/수정 차단 → 안전하지만 가용성 위험
- **Ignore**: Gatekeeper가 응답 못하면 정책 검사 없이 허용 → 가용성 확보하지만 보안 공백
- **프로덕션 권장**: Fail + replicas: 2 이상 + PodDisruptionBudget으로 HA 보장

### Q4: "Pod Security Standards(PSS)와 Gatekeeper 차이는?"

**A**:

- **PSS/PSA (Pod Security Admission)**: Kubernetes 내장, Pod 보안 프로필 3단계 (Privileged/Baseline/Restricted)
- **Gatekeeper**: 외부 도구, Rego로 커스텀 정책 작성 가능
- **PSS 장점**: 설치 불필요, 간단, 표준화됨
- **Gatekeeper 장점**: 파라미터화, 복잡한 로직, Pod 외 리소스(Deployment, Service 등)도 검사 가능
- **프로덕션**: 둘 다 사용 — PSS로 기본 보안, Gatekeeper로 조직별 커스텀 정책

### Q5: "정책을 Audit 모드로만 운영하면 안 되나요?"

**A**: Audit은 사후 감지, Deny는 사전 차단이다.

- **Audit만**: 위반 리소스가 이미 실행 중 → 보안 사고 발생 후 발견
- **Deny만**: 기존 리소스에 대해 검사 불가 (Admission 시점에만 작동)
- **Best Practice**: Deny + Audit 병행 → 새 리소스는 차단하고, 기존 리소스는 감사로 발견

### Q6: "대규모 클러스터에서 Gatekeeper 성능 이슈는?"

**A**:

- **Webhook 지연**: 모든 리소스 생성에 네트워크 홉 추가 → p99 latency 모니터링 필수
- **Audit 부하**: `auditFromCache: true`로 API 서버 부하 최소화
- **Rego 복잡도**: 복잡한 정책은 평가 시간 증가 → opa bench로 성능 측정
- **대응**: replicas 증가, resource limits 조정, 불필요한 정책 정리

---

## 정리 및 리소스 정리

```bash
# 테스트 리소스 정리
kubectl delete pod good-pod -n demo --ignore-not-found

# 전체 삭제 (Gatekeeper 포함)
helm uninstall gatekeeper -n gatekeeper-system
kubectl delete namespace gatekeeper-system
kubectl delete namespace demo
```

## 참고 문서

- [OPA Gatekeeper 공식 문서](https://open-policy-agent.github.io/gatekeeper/website/docs/)
- [Gatekeeper Library (검증된 정책 모음)](https://github.com/open-policy-agent/gatekeeper-library)
- [Rego 언어 레퍼런스](https://www.openpolicyagent.org/docs/latest/policy-language/)
- [CIS Kubernetes Benchmark](https://www.cisecurity.org/benchmark/kubernetes)
- [Kubernetes Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
