# ArgoCD GitOps 핸즈온 랩

## 학습 목표

1. GitOps 원칙 이해 및 ArgoCD를 통한 선언적 배포
2. Application과 ApplicationSet의 차이점과 활용
3. Sync Policy(자동/수동)와 Prune 동작 이해
4. ArgoCD Web UI를 통한 배포 상태 시각화

## 전제 조건

- ArgoCD 설치 완료: `kubectl get pods -n argocd`

### UI 접속 정보

| 항목 | 값 |
|------|-----|
| **Kong URL (권장)** | `https://argocd.lab-dev.local` |
| **Fallback (port-forward)** | `kubectl port-forward svc/argocd-server -n argocd 8080:443` → `https://localhost:8080` |
| **Username** | `admin` |
| **Password** | `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" \| base64 -d` |

> **Note**: ArgoCD Server는 HTTPS를 사용한다. port-forward 시 `8080:443`이 올바른 포트 매핑이다.

---

## 실습 1: ArgoCD Application 생성

### 배경 지식

ArgoCD Application은 "어떤 Git 소스를" "어떤 클러스터/네임스페이스에" 배포할지 정의한다.
Application Controller가 주기적으로 Git과 클러스터 상태를 비교(diff)하여 동기화한다.

### 실습 단계

```bash
# 1. ArgoCD CLI 로그인
argocd login localhost:8080 --insecure --username admin \
  --password $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

# 2. Application 생성 (로컬 Git → demo 네임스페이스)
kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: demo-app
  namespace: argocd
spec:
  project: default
  source:
    # 로컬 경로 대신 실제 Git URL 사용 시:
    # repoURL: https://github.com/your-repo/interview-prep.git
    # path: lab/03-argocd/apps/demo-app
    repoURL: https://github.com/K-Diger/DevOps-Core-Lab.git
    path: lab/03-argocd/apps/demo-app
    targetRevision: HEAD
  destination:
    server: https://kubernetes.default.svc
    namespace: demo
  syncPolicy:
    # 수동 동기화 (실습용: Sync 버튼을 직접 클릭)
    # 프로덕션에서는 automated + selfHeal 권장
    automated: null
EOF

# 3. Web UI에서 확인
# http://localhost:8080 → demo-app Application 확인
# Status: OutOfSync (아직 Sync 안 함)

# 4. 수동 Sync 실행
argocd app sync demo-app
# 또는 Web UI에서 SYNC 버튼 클릭

# 5. 배포 결과 확인
kubectl get pods -n demo
argocd app get demo-app
```

#### UI에서 확인

1. **Application 카드 확인**: ArgoCD UI 메인 화면에서 `demo-app` 카드를 찾는다
   - **Sync Status**: `OutOfSync` (노란색) → Sync 후 `Synced` (초록색)
   - **Health Status**: `Healthy` (하트 아이콘) / `Progressing` / `Degraded`
   - 카드 색상으로 전체 상태를 한눈에 파악할 수 있다

2. **APP DETAILS 네비게이션**: `demo-app` 카드를 클릭하여 상세 화면으로 진입
   - **리소스 트리**: Application → Deployment → ReplicaSet → Pod 계층 구조가 시각화됨
   - 각 노드의 아이콘 색상으로 Health 상태 확인 가능

3. **UI에서 SYNC 실행**:
   - 상단 **SYNC** 버튼 클릭 → 옵션 패널이 열림
   - **PRUNE**: Git에서 삭제된 리소스를 클러스터에서도 제거
   - **DRY RUN**: 실제 적용 없이 변경 사항만 미리 확인
   - **FORCE**: 리소스를 삭제 후 재생성 (주의: 다운타임 발생)
   - SYNCHRONIZE 클릭 후 리소스 트리에서 각 노드가 실시간으로 `Progressing` → `Healthy`로 전환되는 것을 관찰

### 핵심 포인트

> Q: "GitOps의 핵심 원칙은?"
> A: (1) Git이 Single Source of Truth — 클러스터에 직접 kubectl apply 금지
> (2) 선언적(Declarative) — 원하는 상태를 Git에 커밋하면 ArgoCD가 실현
> (3) 자동 동기화(Reconciliation) — Git과 클러스터 상태를 주기적으로 비교
> (4) 감사 추적(Audit Trail) — 모든 변경이 Git commit으로 기록

---

## 실습 2: Sync Policy — 자동 vs 수동

### 배경 지식

- **수동(Manual)**: Sync 버튼을 클릭해야 배포 (안전하지만 느림)
- **자동(Automated)**: Git 변경 감지 시 자동 배포 (빠르지만 주의 필요)
- **selfHeal**: 클러스터에서 직접 변경한 것을 Git 상태로 되돌림
- **prune**: Git에서 삭제된 리소스를 클러스터에서도 삭제

### 실습 단계

```bash
# 1. 자동 동기화 활성화
kubectl patch application demo-app -n argocd --type=merge -p '{
  "spec": {
    "syncPolicy": {
      "automated": {
        "selfHeal": true,
        "prune": true
      }
    }
  }
}'

# 2. selfHeal 테스트: 직접 replica 변경 시도
kubectl scale deployment frontend -n demo --replicas=5
# → 잠시 후 ArgoCD가 Git 상태(replicas=2)로 자동 복원

# 3. 확인
kubectl get pods -n demo
# → 2개로 돌아옴 (selfHeal 동작)
```

#### UI에서 확인

1. **selfHeal 실시간 관찰**: `kubectl scale` 실행 후 ArgoCD UI에서 `demo-app` 상세 화면을 관찰
   - Sync Status가 `Synced` → `OutOfSync` (노란색)로 변경됨
   - selfHeal이 작동하여 수 초 내에 자동으로 `Synced` (초록색)으로 복원됨
   - 리소스 트리에서 Pod 수가 5개로 증가했다가 다시 2개로 줄어드는 과정이 실시간으로 보임

2. **HISTORY AND ROLLBACK 탭 확인**:
   - `demo-app` 상세 화면 → 상단 **HISTORY AND ROLLBACK** 탭 클릭
   - 최근 Sync 기록에서 `Initiated by: automated` 라벨이 붙은 항목을 확인
   - 수동 Sync와 자동 Sync의 이력이 구분되어 기록됨
   - 이 기록이 Git commit 기반 감사 추적(Audit Trail)의 핵심

### 핵심 포인트

> Q: "누군가 kubectl로 직접 배포하면 어떻게 되나요?"
> A: selfHeal이 활성화되어 있으면 ArgoCD가 Git 상태로 자동 되돌린다.
> 이를 통해 "Git이 유일한 진실의 원천" 원칙을 강제할 수 있다.
> kubectl 직접 변경은 drift(편차)로 감지되어 알림이 발생한다.

---

## 실습 3: Drift Detection 확인

### 실습 단계

```bash
# 1. 직접 리소스 변경 (drift 발생)
kubectl -n demo set image deployment/frontend frontend=nginx:latest

# 2. ArgoCD에서 drift 감지 확인
argocd app get demo-app
# Status: OutOfSync (Diff 존재)

# 3. Diff 확인
argocd app diff demo-app
# 이미지 태그가 alpine → latest로 변경된 것이 표시됨

# 4. selfHeal이 자동으로 원래 상태로 복원하는지 확인
kubectl get deployment frontend -n demo -o jsonpath='{.spec.template.spec.containers[0].image}'
# → nginx:alpine (원래 Git 상태로 복원)
```

#### UI에서 확인

1. **APP DIFF 버튼으로 차이 확인**:
   - `demo-app` 상세 화면 → 상단 **APP DIFF** 버튼 클릭
   - Git에 정의된 상태(Desired)와 클러스터 실제 상태(Live)의 차이가 diff 형식으로 표시됨
   - 이미지 태그가 `nginx:alpine` → `nginx:latest`로 변경된 것이 빨간색/초록색으로 시각화됨
   - CLI의 `argocd app diff` 출력과 동일한 정보를 시각적으로 확인할 수 있다

2. **리소스별 DIFF 확인**:
   - 리소스 트리에서 `OutOfSync` 상태인 Deployment 노드를 클릭
   - **DIFF** 탭에서 해당 리소스만의 변경 사항을 확인
   - **DESIRED MANIFEST** / **LIVE MANIFEST** 탭으로 전체 매니페스트 비교 가능

---

## 실습 4: ArgoCD + OPA Gatekeeper 연동

### 배경 지식

ArgoCD가 배포하는 리소스도 OPA Gatekeeper의 정책 검사를 거친다.
Git에 정책 위반 매니페스트가 커밋되면 ArgoCD Sync가 실패한다.

### 실습 단계

```bash
# 1. 정책 위반 매니페스트 배포 시도
# (resource limits 누락 → Gatekeeper가 거부)
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: violation-test
  namespace: demo
  labels:
    app: violation-test
    team: test
spec:
  replicas: 1
  selector:
    matchLabels:
      app: violation-test
  template:
    metadata:
      labels:
        app: violation-test
        team: test
    spec:
      containers:
        - name: nginx
          image: nginx:alpine
          # ★ resource limits 누락 → Gatekeeper가 거부
EOF
# ERROR: admission webhook "validation.gatekeeper.sh" denied the request

# 2. ArgoCD에서도 동일하게 거부됨을 확인
# Git에 이 매니페스트를 커밋하면 ArgoCD Sync가 실패
```
