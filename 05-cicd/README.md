# 05. CI/CD (Jenkins, ArgoCD) -- 기술 심화 가이드

> **리뷰어 관점**: CI/CD는 DevOps의 핵심이지만, 1년차가 Jenkins Shared Library 설계 + ArgoCD GitOps 전환 + Helm Umbrella Chart까지 했다고 하면 "
> 진짜야?"가 첫 반응이다.
> 코드 한 줄까지 파고들어서 직접 만든 게 맞는지 검증한다. 특히 Jenkins에서 ArgoCD로 "전환했다"면 전환 동기, 과정, 트레이드오프를 구체적으로 말할 수 있어야 한다.
> Helm Umbrella Chart는 10개 subchart를 condition 기반으로 관리하는 것 자체가 쉽지 않은데, 왜 이 구조를 선택했는지 설계 의도가 핵심이다.

---

## 1. CI/CD 파이프라인 Overview

### 전체 흐름

```
[개발자 코드 Push]
    │
    ▼
[Jenkins CI - 10.125.11.176]
    ├── Shared Library (vars/)
    │   ├── backendBuildBase.groovy   → 빌드 통합 엔트리 포인트
    │   ├── gitUtils.groovy           → Git 체크아웃, GitHub Release 조회
    │   ├── dockerUtils.groovy        → Docker 빌드 + Harbor Push
    │   ├── gradleUtils.groovy        → Gradle 빌드
    │   └── commonUtils.groovy        → 버전 검증, 공통 유틸
    ├── Gradle 빌드 (parallel=true, caching=true)
    ├── DOCKER_BUILDKIT=1 이미지 빌드
    │   └── --build-arg VCS_REF, BUILD_DATE, VERSION
    └── Harbor Push (registry.example.com)
        ├── version tag (예: 1.2.3)
        └── latest tag
    │
    ▼
[ArgoCD - argocd 네임스페이스]
    ├── ApplicationSet (service-platform)
    │   └── Git Directory Generator
    │       → helm/charts/service-platform/charts/* 스캔
    │       → values-{env}.yaml 매핑
    ├── Image Updater
    │   └── Harbor polling (2분) → Git commit → ArgoCD sync
    └── syncPolicy: automated (prune + selfHeal)
    │
    ▼
[Helm Umbrella Chart - service-platform]
    ├── 10 subcharts: eam, tlm, gea, common, frontend-bo/tlm/gea/hrm, checkin, observer
    ├── condition 기반 활성화 (eam.enabled, tlm.enabled ...)
    └── 환경별 values 오버라이드 (values-live.yaml)
    │
    ▼
[Argo Rollouts]
    ├── Canary 배포: 10% → 50% → 100%
    ├── AnalysisTemplate: 에러율 < 5%, P99 < 2s
    └── Gateway API(Kong) 트래픽 라우팅
```

### 환경별 배포 흐름

- **dev** -> **stg** -> **live** 순차 배포
- 각 환경은 `values-dev.yaml`, `values-stg.yaml`, `values-live.yaml`로 분리
- 네임스페이스: `dev`, `stg`, `prod`

---

## 2. 핵심 설정 해설

### 2.1 Jenkins Shared Library

**설계 의도**: 10+ 서비스의 빌드/배포 파이프라인이 90% 동일한 구조를 반복. 코드 중복 제거 + 표준화 + 신규 서비스 온보딩 시간 단축.

**실제 구조** (환경별 분리: `live/backend/vars/`, `stg/backend/vars/`):

| 파일                         | 역할                               | 핵심 로직                                                                     |
|----------------------------|----------------------------------|---------------------------------------------------------------------------|
| `backendBuildBase.groovy`  | 빌드 통합 엔트리 포인트                    | `determineBuildBranch()` -> `determineBuildVersion()` -> `executeBuild()` |
| `backendDeployBase.groovy` | 배포 통합 엔트리 포인트                    | 파라미터 검증 -> 롤백 버전 결정 -> 서버별 배포                                             |
| `gitUtils.groovy`          | Git 체크아웃 + GitHub Release 조회     | `@NonCPS parseGitHubReleaseResponse()` (JsonSlurper)                      |
| `dockerUtils.groovy`       | Docker 빌드 + Harbor Push/롤백 버전 조회 | `--password-stdin`, `DOCKER_BUILDKIT=1`, 버전+latest 듀얼 태그                  |
| `gradleUtils.groovy`       | Gradle 빌드                        | `-Dorg.gradle.parallel=true -Dorg.gradle.caching=true`                    |
| `commonUtils.groovy`       | 버전 검증, 공통 유틸                     | `validateVersionFormat()`, `normalizeVersionTag()`                        |

**핵심 설계 포인트**:

- `@NonCPS` 어노테이션: `JsonSlurper.parseText()`가 반환하는 `LazyMap`은 Serializable하지 않으므로 CPS 변환에서 제외
- `--password-stdin`: `docker login -p`는 프로세스 목록에 비밀번호 노출 가능. stdin으로 전달하여 보안 강화
- 듀얼 태그 전략: `version tag` + `latest tag` 동시 Push. 롤백 시 이전 version tag 사용

### 2.2 ArgoCD GitOps

**선언적 배포**: Git에 Desired State를 선언하면 ArgoCD가 Actual State와 지속적으로 동기화.

**실제 설정**:

- ArgoCD v2.14.0 (Helm chart argo-cd-7.8.0)
- Server replicas=2, RepoServer replicas=2, ApplicationSet replicas=2 (HA 구성)
- NodePort 32443으로 UI 노출
- Harbor 미러 이미지 사용 (폐쇄망)

**ApplicationSet 설정**:

```yaml
# Git Directory Generator
generators:
  - git:
      repoURL: https://github.com/your-org/Infra-DevOps.git
      directories:
        - path: helm/charts/service-platform/charts/*   # subchart 자동 스캔
      files:
        - path: "../../values-*.yaml"               # 환경별 values 매핑

# syncPolicy
automated:
  prune: true      # Git에서 삭제 -> K8s에서도 삭제
  selfHeal: true   # kubectl edit 수동 변경 -> Git 상태로 자동 복원
syncOptions:
  - PruneLast=true  # 새 리소스 생성 후 구 리소스 삭제 (Zero-downtime)
```

**Image Updater**: Harbor polling(2분) -> `values-{env}.yaml` 자동 업데이트 -> Git commit -> ArgoCD sync

### 2.3 Helm Umbrella Chart 전략

**왜 Umbrella Chart인가**:

- 10개 마이크로서비스를 하나의 Chart로 묶어 **일관된 배포 단위** 확보
- `condition` 기반 활성화로 환경별/상황별 서비스 선택 배포 가능
- Global values(`imageRegistry`, `imagePullSecrets`, `istio.enabled`)를 한 곳에서 관리

**Chart.yaml (실제)**:

```yaml
dependencies:
  - name:
      eam        condition: eam.enabled
  - name:
      tlm        condition: tlm.enabled
  - name:
      gea        condition: gea.enabled
  - name:
      common     condition: common.enabled
  - name:
      frontend-bo   condition: frontendBo.enabled
  - name:
      frontend-tlm  condition: frontendTlm.enabled
  - name:
      frontend-gea  condition: frontendGea.enabled
  - name:
      frontend-hrm  condition: frontendHrm.enabled
  - name:
      checkin    condition: checkin.enabled
  - name:
      observer   condition: observer.enabled
```

**환경별 오버라이드 (values-live.yaml)**:

- `global.imageRegistry: registry.example.com`
- YAML Anchor(`&backend-pod-security`)로 보안 설정 재사용
- `startupProbe`: Spring Boot JVM 기동 시간(최대 5분) 대기
- `preStop` Lifecycle Hook: `sleep 10`으로 Graceful Shutdown 보장

### 2.4 이미지 태그 관리

**Semantic Versioning + Git Release 연동**:

1. 개발자가 GitHub Release 생성 (tag: `v1.2.3`)
2. Jenkins가 GitHub API로 최신 Release 태그 자동 조회 (`detectLatestReleaseFromGitHub()`)
3. `commonUtils.normalizeVersionTag()`로 `v` 접두사 제거 -> `1.2.3`
4. Harbor에 `1.2.3` + `latest` 듀얼 태그 Push

**롤백 버전 자동 탐지**:

- `dockerUtils.detectRollbackVersionFromHarbor()`: Harbor API로 아티팩트 목록 조회
- latest 태그의 push_time과 다른 최신 Semver 태그를 자동 선택
- 롤백 시 재빌드 없이 이전 이미지 태그로 즉시 배포

### 2.5 배포 전략 (Argo Rollouts)

**Canary 배포 설정 (실제)**:

```
Step 1: setWeight 10%  -> 1시간 대기 (수동 관찰)
Step 2: AnalysisTemplate 실행 (에러율 + P99 레이턴시)
Step 3: setWeight 50%  -> 2시간 대기
Step 4: AnalysisTemplate 재실행
Step 5: 100% 전환 (자동)
```

**AnalysisTemplate (Prometheus 연동)**:

- `http-error-rate`: 5분간 5xx 에러율 < 5% (30초 간격, 10회 측정, failureLimit=3)
- `http-latency-p99`: P99 응답시간 < 2000ms

**트래픽 라우팅**: Kong Gateway API의 HTTPRoute weight를 Argo Rollouts가 자동 조절

---

## 3. 심화 Q&A -- 팀 토론 결과

### [팀원1: 박준혁 - 인프라]

---

**Q1. Jenkins 서버를 단일 인스턴스(10.125.11.176)로 운영했다고 했는데, SPOF 문제는 어떻게 대응했나요?**

- **의도**: CI/CD 인프라 자체의 가용성을 고민해봤는지. Jenkins Controller가 죽으면 전체 빌드/배포가 중단됨
- **꼬리질문 1**: "Jenkins Controller의 HA 구성은 검토해봤나요? 왜 안 했나요?"
- **꼬리질문 2**: "Jenkins가 24시간 다운되면 개발팀에 어떤 영향이 있었나요? 실제로 다운된 적은?"

> **모범 답변**:
>
> Jenkins Controller가 단일 장애점이라는 것은 명확히 인지하고 있었다.
>
> Jenkins HA 구성을 위해서는 **CloudBees CI(유료)** 같은 엔터프라이즈 솔루션이 필요하거나, Active-Passive 구성으로 Controller를 이중화해야 한다.
> Active-Passive 구조는 `JENKINS_HOME` 디렉토리를 공유 스토리지(NFS, GlusterFS)에 올려서 Failover 시 Secondary가 인계받는 방식인데, **Jenkins의 파일 기반
상태 관리** 특성상 동시 접근 시 데이터 정합성 문제가 발생할 수 있다. 비용과 복잡도를 고려해 도입하지 않았다.
>
> 대신 세 가지 보완책을 적용했다:
> 1. **JENKINS_HOME 정기 백업**: 크론잡으로 일 1회 전체 백업, 복원 테스트까지 수행
> 2. **인프라 모니터링**: Prometheus Metrics Plugin(`:8080/prometheus/`)으로 Jenkins 메트릭을 수집하고, CPU/메모리/디스크 임계치 알림 설정
> 3. **CD를 ArgoCD로 분리**: Jenkins가 죽어도 ArgoCD는 독립적으로 GitOps sync를 계속 수행. CI만 중단되고 CD는 영향 없음
>
> 솔직히 실제로 Jenkins가 완전히 다운된 적은 없었지만, **디스크 사용량 경고**가 발생해 오래된 빌드 로그와 workspace를 정리한 적이 있다.

> **키포인트**:
> - Jenkins HA의 기술적 어려움(파일 기반 상태 관리, 공유 스토리지 문제)을 구체적으로 설명
> - CI/CD 분리 아키텍처(Jenkins=CI, ArgoCD=CD)로 blast radius를 줄인 설계 의도
> - 모니터링 + 백업으로 SPOF 보완했다는 현실적 대응

---

**Q2. 폐쇄망(Air-gap)에서 Docker 이미지 빌드 환경은 어떻게 구성하셨나요? 베이스 이미지 관리, 의존성 다운로드 등.**

- **의도**: 폐쇄망에서 CI를 돌리는 것은 단순히 Jenkins 설치하는 것과 차원이 다름. 빌드에 필요한 모든 의존성을 오프라인에서 해결해야 함
- **꼬리질문 1**: "Gradle 빌드 시 Maven Central에 접근 못 하잖아요. 어떻게 해결했나요?"
- **꼬리질문 2**: "Harbor에 베이스 이미지(openjdk, nginx 등)를 어떻게 유지하셨나요? 업데이트 주기는?"

> **모범 답변**:
>
> 폐쇄망에서 CI를 돌리기 위해 세 가지 인프라를 구축했다.
>
> **1. Nexus Repository (사내 Maven Mirror)**: Gradle 빌드 시 외부 Maven Central 대신 사내 Nexus를 프록시로 사용한다. Shared Library의
`backendBuildBase.groovy`에서 `NEXUS_USERNAME`, `NEXUS_SECRET` 환경변수를 `withCredentials`로 주입하고, `build.gradle`의
`repositories`에 Nexus URL을 설정했다. 초기에 필요한 의존성을 DMZ 서버를 통해 Nexus에 캐싱하고, 이후에는 캐시된 아티팩트를 사용한다.
>
> **2. Harbor 미러 레지스트리**: Docker Hub, Quay.io, GHCR의 베이스 이미지를 Harbor에 미러링한다.
`global.imageRegistry: registry.example.com`으로 모든 이미지 Pull을 Harbor로 통일했다. 베이스 이미지 업데이트는 **보안 패치 시 수동으로 반입**하는
> 프로세스를 운영했다.
>
> **3. BuildKit 활용**: `DOCKER_BUILDKIT=1`로 빌드 시 `--build-arg BUILDKIT_INLINE_CACHE=1`을 설정해 이전 빌드의 레이어 캐시를 Harbor에서 직접
> 참조할 수 있도록 했다.

> **키포인트**:
> - 폐쇄망 CI의 3대 과제: 소스 의존성(Nexus), 컨테이너 이미지(Harbor 미러), 빌드 캐시(BuildKit)
> - `withCredentials`로 Nexus 자격증명 관리 -- 실제 코드(`backendBuildBase.groovy`)와 일치
> - 베이스 이미지 업데이트 프로세스의 현실적 한계(수동 반입)를 솔직히 언급

---

**Q3. Jenkins에서 Gradle 빌드 최적화를 어떻게 했나요? 빌드 시간은 얼마나 걸리나요?**

- **의도**: 빌드 시간을 숫자로 말할 수 있는지, 최적화를 실제로 해봤는지
- **꼬리질문 1**: "Gradle Daemon은 사용하셨나요? Jenkins에서 Daemon을 쓰면 어떤 문제가 있나요?"
- **꼬리질문 2**: "`-Dorg.gradle.parallel=true`가 항상 빠른 건 아니잖아요. 프로젝트 간 의존성이 있으면 어떻게 되나요?"

> **모범 답변**:
>
> 전체 파이프라인(체크아웃 -> Gradle 빌드 -> Docker 이미지 빌드/Push) 기준으로 **평균 7~10분** 소요된다. 이 중 Gradle 빌드가 약 3~4분, Docker 빌드/Push가 약 2~
> 3분이다.
>
> Gradle 최적화는 `backendBuildBase.groovy`에서 두 가지 옵션을 적용했다:
> - **`-Dorg.gradle.parallel=true`**: 독립적인 서브 프로젝트를 병렬 컴파일. 단, 프로젝트 간 의존성이 있으면 Gradle이 자동으로 의존 순서를 해석해서 순차 실행한다. 순수하게
    독립적인 모듈이 많은 멀티프로젝트에서 효과적이다.
> - **`-Dorg.gradle.caching=true`**: 빌드 캐시 활성화. 입력(소스코드, 의존성)이 변경되지 않은 태스크는 캐시에서 결과를 가져온다.
>
> Gradle Daemon은 **Jenkins 환경에서는 의도적으로 비활성화**했다. Daemon은 JVM 프로세스를 메모리에 상주시켜 재사용하는 방식인데, Jenkins Agent에서 여러 빌드가 동시에 돌
> 때 Daemon 프로세스가 누적되어 **OOM 문제**가 발생할 수 있다. CI 환경에서는 Gradle 공식 문서에서도 Daemon 비활성화를 권장한다.

> **키포인트**:
> - 빌드 시간을 구체적 숫자로 제시 ("7~10분", 각 단계별 소요 시간)
> - `parallel`과 `caching` 옵션의 동작 원리를 설명 (단순 "켰다"가 아님)
> - Gradle Daemon이 CI에서 문제가 되는 이유를 아는 것 = 실제 운영 경험
> - 공식 문서: https://docs.gradle.org/current/userguide/build_environment.html

---

### [팀원2: 이서연 - SRE]

---

**Q1. ArgoCD의 syncPolicy에서 `selfHeal: true`를 설정했는데, 긴급 상황에서 `kubectl edit`로 빠르게 대응해야 할 때 어떻게 하시나요?**

- **의도**: selfHeal은 Git이 Single Source of Truth임을 보장하지만, 긴급 대응과 충돌할 수 있음. 이 트레이드오프를 인지하고 있는지
- **꼬리질문 1**: "selfHeal을 끄면 configuration drift가 발생하잖아요. 그건 어떻게 관리하나요?"
- **꼬리질문 2**: "ArgoCD에서 sync가 실패하면 어떻게 알림을 받나요?"

> **모범 답변**:
>
> `selfHeal: true`는 **Git에 선언된 상태와 클러스터 실제 상태의 일관성을 자동으로 보장**하는 설정이다. `kubectl edit`로 수동 변경하면 ArgoCD가 **기본 3분 내에 감지하고
Git 상태로 되돌린다.**
>
> 긴급 상황 대응에는 두 가지 전략이 있다:
>
> **1. Git-first 원칙 유지 (권장)**: 긴급 변경도 Git에 커밋한다. `git commit` -> `git push` -> ArgoCD auto-sync까지 **5분 이내**에 반영된다. 정말
> 급하면 ArgoCD UI/CLI에서 **Manual Sync**를 트리거해 즉시 반영할 수 있다.
>
> **2. 특정 Application에 대해 임시로 selfHeal 비활성화**: ArgoCD CLI로 `argocd app set <app> --self-heal=false`를 실행한 뒤 `kubectl`로 긴급
> 패치를 적용하고, 이후 Git에 동일 변경을 커밋한 다음 selfHeal을 다시 활성화한다. 다만 이 방식은 **configuration drift 위험**이 있으므로 반드시 Git 동기화 후 selfHeal을
> 복원해야 한다.
>
> 저희 설정에서는 `syncPolicy.syncOptions`에 `PruneLast=true`도 설정해서, 새 리소스가 먼저 생성된 후 구 리소스가 삭제되도록 Zero-downtime을 보장하고 있다.

> **키포인트**:
> - selfHeal의 동작 원리(Git 상태로 자동 복원)와 트레이드오프(긴급 대응 방해)를 명확히 설명
> - "Git-first 원칙"을 유지하면서 긴급 대응하는 현실적 프로세스 제시
> - 공식 문서: https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/

---

**Q2. Argo Rollouts의 AnalysisTemplate에서 에러율 < 5%, P99 < 2s로 설정한 근거는 뭔가요?**

- **의도**: 임계값을 "그냥 설정"한 건지, 데이터 기반으로 결정한 건지
- **꼬리질문 1**: "서비스별로 임계값이 다를 수 있잖아요. Observer(모니터링)와 TLM(업무 시스템)의 에러율 기준이 같은 게 맞나요?"
- **꼬리질문 2**: "`failureLimit: 3`이면 10회 측정 중 3회 초과 시 롤백인데, 이게 너무 관대한 건 아닌가요?"

> **모범 답변**:
>
> 솔직히 초기 임계값은 **Google SRE 워크북의 SLO 설정 가이드**와 업계 일반적 기준을 참고해서 설정했다. 에러율 5%는 SLO 99.95% 기준에서 "배포 중 일시적으로 허용 가능한 수준"이고,
> P99 2초는 저희 서비스의 평균 응답시간(~500ms)의 약 4배다.
>
> 지적하신 대로, **서비스별 특성에 따라 임계값을 세분화하는 것이 이상적**이다. 예를 들어:
> - **TLM (핵심 업무 시스템, 5 pods, 72GB)**: 에러율 기준을 더 엄격하게 (< 1%)
> - **Observer (모니터링 도구, 6G)**: 상대적으로 완화 가능 (< 10%)
>
> 현재는 공통 AnalysisTemplate 하나를 사용하고 `args.service-name`으로 PromQL 쿼리를 동적으로 바꾸는 수준인데, **서비스별 별도 AnalysisTemplate을 만들거나
args로 임계값 자체를 파라미터화**하는 것이 개선 방향이다.
>
> `failureLimit: 3`은 **네트워크 순간 지터나 Prometheus 스크래핑 타이밍 차이**로 인한 일시적 spike를 false positive로 처리하지 않기 위한 여유분이다. 1로 설정하면
> 일시적 spike에도 즉시 롤백되어 불필요한 롤백이 빈번해질 수 있다.

> **키포인트**:
> - 임계값 설정의 근거(SRE 워크북, 서비스 평균 응답시간 대비 비율)를 데이터 기반으로 설명
> - 서비스별 차등 적용이 필요하다는 개선점을 스스로 인지
> - failureLimit의 존재 이유(false positive 방지)를 설명
> - 공식 문서: https://argoproj.github.io/argo-rollouts/features/analysis/

---

**Q3. GitOps에서 Git이 SPOF가 되지 않나요? GitHub Enterprise가 다운되면 배포가 전부 멈추잖아요.**

- **의도**: GitOps의 구조적 약점을 인지하고 있는지. "Git이 Single Source of Truth"라고만 외우면 이 질문에 막힘
- **꼬리질문 1**: "ArgoCD가 Git을 polling하는 주기는? 그 사이에 변경을 놓치면?"
- **꼬리질문 2**: "Git 저장소에 Helm values와 application 코드를 같이 두나요, 분리하나요?"

> **모범 답변**:
>
> 맞다. GitOps에서 **Git은 새로운 SPOF**가 될 수 있다. 다만 GitHub Enterprise가 다운되면 ArgoCD가 Git 변경을 감지 못해 **새 배포가 안 되는 것**이지, **이미
배포된 서비스가 죽는 것은 아니다.** ArgoCD의 마지막 sync 상태가 클러스터에 유지되기 때문이다.
>
> ArgoCD의 Git polling 주기는 기본 **3분**이다. Webhook을 설정하면 Git push 시 즉시 sync를 트리거할 수 있는데, 저희 폐쇄망 환경에서는 GitHub Enterprise와
> ArgoCD가 같은 네트워크에 있어서 Webhook 설정이 가능했다. Webhook + Polling 병행으로 **Webhook 유실 시에도 최대 3분 내 감지**를 보장한다.
>
> Git 저장소 구조는 **인프라/배포 설정 전용 레포(Infra-DevOps)**와 **애플리케이션 코드 레포**를 분리했다. Helm charts, values 파일, ArgoCD ApplicationSet
> 설정은 Infra-DevOps에, 서비스 소스 코드는 각 서비스별 레포에 있다. 이렇게 분리하는 이유는:
> - 애플리케이션 코드 변경과 인프라 설정 변경의 **변경 빈도와 승인 프로세스가 다름**
> - 개발자에게 인프라 레포 쓰기 권한을 주지 않아 **보안 분리** 가능
> - ArgoCD가 감시하는 레포의 변경 이벤트를 최소화하여 **불필요한 sync 방지**

> **키포인트**:
> - GitOps에서 Git 다운 시 "새 배포 불가 vs 기존 서비스 유지"를 구분하여 설명
> - Webhook + Polling 병행 전략과 그 이유
> - 코드 레포와 인프라 레포 분리의 보안/운영 관점 근거
> - 공식 문서: https://argo-cd.readthedocs.io/en/stable/operator-manual/webhook/

---

### [팀원3: 최민수 - 보안]

---

**Q1. Jenkins에서 Harbor로 Push할 때 credential 관리는 어떻게 하셨나요? Shared Library에서 credential이 노출될 위험은?**

- **의도**: CI/CD 파이프라인 보안은 가장 간과되기 쉬운 영역. credential이 로그에 찍히거나, Shared Library 코드에 하드코딩되어 있지 않은지
- **꼬리질문 1**: "`withCredentials` 블록 밖에서 credential 변수를 참조하면 어떻게 되나요?"
- **꼬리질문 2**: "Jenkins Admin 권한이 있으면 Script Console에서 모든 credential을 평문으로 볼 수 있는 거 아닌가요?"

> **모범 답변**:
>
> credential 관리는 **Jenkins Credentials Store**에 등록하고, `withCredentials` 블록으로 감싸서 사용한다. 실제 `dockerUtils.groovy` 코드에서는:
>
> ```groovy
> withCredentials([usernamePassword(
>     credentialsId: harborConfig.credentialsId,
>     usernameVariable: 'HARBOR_USERNAME',
>     passwordVariable: 'HARBOR_PASSWORD'
> )]) {
>     sh 'echo "${HARBOR_PASSWORD}" | docker login ${harborConfig.url} -u "${HARBOR_USERNAME}" --password-stdin'
> }
> ```
>
> **핵심 보안 포인트 3가지**:
>
> 1. **`--password-stdin`**: 초기에는 `docker login -p`를 사용했는데, 이 방식은 `ps aux` 프로세스 목록에 비밀번호가 노출된다. `--password-stdin`으로
     개선하여 stdin을 통해 전달한다.
>
> 2. **Jenkins 콘솔 로그 마스킹**: `withCredentials` 블록 내에서 credential 값이 로그에 출력되면 `****`로 마스킹된다. 단, **정확히 일치하는 문자열만** 마스킹되므로,
     base64 인코딩이나 substring으로 출력하면 마스킹이 우회된다.
>
> 3. **Script Console 위험**: 지적하신 대로, Jenkins Admin 권한이 있으면 Groovy Script Console에서
     `com.cloudbees.plugins.credentials.CredentialsProvider`를 통해 **credential을 평문으로 추출 가능**하다. 이것은 Jenkins의 구조적 한계이며,
     Admin 권한을 가진 사용자를 최소화하고, **Role-Based Access Strategy 플러그인**으로 역할별 권한을 분리했다.

> **키포인트**:
> - `--password-stdin` 전환 경험은 실무 보안 의식의 증거
> - Jenkins credential 마스킹의 한계(정확 일치만)를 아는 것
> - Script Console 취약점을 솔직히 인정하면서 대응책(RBAC) 제시
> - 공식 문서: https://www.jenkins.io/doc/book/using/using-credentials/

---

**Q2. ArgoCD ApplicationSet에서 `prune: true`를 설정하면, Git에서 실수로 리소스 정의를 삭제했을 때 프로덕션 리소스도 삭제되잖아요. 이 위험은 어떻게 관리하나요?**

- **의도**: `prune: true`는 편리하지만 위험. Git 실수 = 프로덕션 장애 직결. 이 위험을 인지하고 방어책이 있는지
- **꼬리질문 1**: "실수로 values-live.yaml에서 `eam.enabled: false`로 바꾸면 EAM 서비스 전체가 내려가는 거 아닌가요?"
- **꼬리질문 2**: "Git 레포에 Branch Protection Rule은 설정하셨나요?"

> **모범 답변**:
>
> 맞다. `prune: true`는 **Git이 삭제한 리소스를 K8s에서도 자동 삭제**하므로, Git 실수가 곧 프로덕션 장애로 이어질 수 있다. 이 위험을 관리하기 위해 세 가지 방어층을 구성했다:
>
> **1. Git Branch Protection**: `main` 브랜치에 직접 push를 금지하고, **PR + 최소 1명 리뷰 승인** 후에만 머지 가능하도록 설정했다. 특히
`values-live.yaml` 변경은 DevOps 팀 리뷰를 필수로 했다.
>
> **2. `PruneLast=true` syncOption**: 저희 ApplicationSet에 설정되어 있는데, 이것은 **새 리소스를 먼저 생성한 후 구 리소스를 삭제**한다. 실수로 리소스 정의를
> 삭제했더라도, 삭제가 가장 마지막에 실행되므로 발견 후 revert할 시간적 여유가 생긴다.
>
> **3. ArgoCD Notification + 수동 Sync 전환 가능**: 위험도가 높은 Application에 대해서는 `automated`를 제거하고 **수동 Sync**로 운영하는 옵션도 있다. 다만
> 저희는 자동 Sync의 편리함을 유지하면서 PR 리뷰로 방어하는 전략을 선택했다.
>
> `eam.enabled: false` 실수 시나리오에 대해서는, condition 기반 활성화이므로 **값 하나 변경으로 전체 서비스가 내려갈 수 있다**. 이런 critical 변경은 PR 리뷰에서 잡는
> 것이 1차 방어선이고, ArgoCD의 `retry.limit: 5`와 `backoff` 설정으로 일시적 문제 시 자동 재시도된다.

> **키포인트**:
> - `prune: true`의 위험성을 인지하고 방어층(Branch Protection, PruneLast, PR 리뷰)을 구체적으로 제시
> - condition 기반 활성화의 위험(값 하나로 서비스 전체 다운)을 솔직히 인정
> - 공식 문서: https://argo-cd.readthedocs.io/en/stable/user-guide/sync-options/

---

**Q3. Shared Library의 `@NonCPS` 어노테이션이 보안에 미치는 영향을 알고 계신가요?**

- **의도**: `@NonCPS`는 Groovy Sandbox 밖에서 실행됨. 보안 관점에서 위험한 코드가 Sandbox 제한을 우회할 수 있음
- **꼬리질문 1**: "`@NonCPS` 함수 안에서 `Runtime.exec()`을 호출하면 어떻게 되나요?"
- **꼬리질문 2**: "Groovy Sandbox와 Script Approval의 차이를 설명해주세요"

> **모범 답변**:
>
> `@NonCPS`는 CPS 변환에서 제외하는 어노테이션인데, 보안 관점에서 중요한 특성이 있다. `@NonCPS` 함수는 **Groovy Sandbox의 제한을 일부 우회**할 수 있다.
>
> 저희 코드에서 `@NonCPS`를 사용한 곳은 `gitUtils.groovy`의 `parseGitHubReleaseResponse()`와 `dockerUtils.groovy`의
`parseHarborResponse()`, `findPreviousVersionBeforeLatest()` 등 **JSON 파싱 함수**다. `JsonSlurper`가 반환하는 `LazyMap`이
`Serializable`하지 않아서 CPS 변환 시 `NotSerializableException`이 발생하기 때문에 `@NonCPS`가 필수적이었다.
>
> **Groovy Sandbox**는 Jenkins가 Pipeline 스크립트 실행 시 위험한 Java/Groovy API 호출을 차단하는 메커니즘이고, **Script Approval**은 Sandbox에서
> 차단된 특정 메서드 시그니처를 관리자가 명시적으로 허용하는 화면이다.
>
> `@NonCPS` 함수에서 `Runtime.exec()`을 호출하면, **Shared Library가 Trusted Source**로 등록되어 있으면 Sandbox 제한 없이 실행될 수 있다. 저희
> Shared Library는 Jenkins 시스템 설정에서 등록한 것이므로 Trusted로 간주된다. 이것이 Shared Library 레포에 대한 **쓰기 권한을 DevOps 팀으로 제한**해야 하는
> 이유다.

> **키포인트**:
> - `@NonCPS`의 보안적 의미(Sandbox 우회 가능성)를 구체적으로 설명
> - Trusted Shared Library의 보안 위험(Sandbox 제한 없음)을 인지
> - 실제 코드에서 `@NonCPS`를 사용한 이유(JsonSlurper의 NotSerializableException)를 연결
> - 공식 문서: https://www.jenkins.io/doc/book/pipeline/shared-libraries/#defining-shared-libraries

---

### [팀원4: 김하준 - 플랫폼]

---

**Q1. Helm Umbrella Chart에서 10개 subchart를 관리하면 `helm upgrade` 시 전체 서비스가 영향을 받을 수 있잖아요. 이 위험은 어떻게 관리하나요?**

- **의도**: Umbrella Chart의 핵심 트레이드오프. 하나의 Chart에 모든 서비스를 묶으면 배포 단위가 커지고 blast radius가 넓어짐
- **꼬리질문 1**: "TLM만 업데이트하고 싶은데 EAM도 같이 helm upgrade가 돌아가는 건 아닌가요?"
- **꼬리질문 2**: "Umbrella Chart 대신 서비스별 독립 Chart로 분리하는 것은 고려하지 않았나요?"

> **모범 답변**:
>
> 이것은 Umbrella Chart의 가장 큰 트레이드오프다. `helm upgrade service-platform`을 실행하면 모든 subchart에 대해 diff를 계산하고, **변경이 있는 subchart의
리소스만 실제로 업데이트**된다. Helm은 변경이 없는 리소스는 건드리지 않는다. 하지만 Helm의 template rendering 과정에서 예상치 못한 side effect가 발생할 위험은 있다.
>
> 저희 구조에서는 ArgoCD의 **ApplicationSet이 subchart별로 별도 Application을 생성**한다:
> ```
> checkin-live, eam-live, tlm-live, observer-live ...
> ```
> 각 Application이 `helm/charts/service-platform/charts/{서비스}/` 경로를 독립적으로 감시하므로, **TLM의 values만 변경하면 TLM Application만 sync**
> 된다. Umbrella Chart의 구조적 한계를 ArgoCD ApplicationSet으로 보완한 셈이다.
>
> 서비스별 독립 Chart 분리는 검토했지만, Global values(imageRegistry, imagePullSecrets, istio.enabled, gateway 설정)를 서비스마다 중복 관리해야 하는
> 문제가 있었다. 10개 서비스 x 3개 환경 = 30개 values 파일에 동일한 설정을 반복하는 것보다, **Umbrella Chart의 global values로 한 곳에서 관리**하는 것이 유지보수
> 면에서
> 유리했다.

> **키포인트**:
> - Umbrella Chart의 한계를 ArgoCD ApplicationSet으로 보완한 아키텍처 설계
> - "변경 없는 리소스는 업데이트 안 됨" (Helm의 동작 원리)
> - 독립 Chart 대비 Umbrella Chart의 장점(Global values 중앙 관리)을 구체적으로 설명
> - 공식 문서: https://helm.sh/docs/howto/charts_tips_and_tricks/#complex-charts-with-many-dependencies

---

**Q2. values-live.yaml에서 YAML Anchor(`&backend-pod-security`)를 사용하셨는데, Helm에서 YAML Anchor 사용 시 주의할 점은?**

- **의도**: Helm values에서 YAML Anchor는 편리하지만 함정이 있음. `x-` 접두사 사용 이유를 아는지
- **꼬리질문 1**: "`x-backend-pod-security`에서 `x-` 접두사를 붙인 이유가 뭔가요?"
- **꼬리질문 2**: "Helm template 내에서 YAML Anchor를 참조할 수 있나요?"

> **모범 답변**:
>
> `x-` 접두사는 **YAML Extension Fields** 규약이다. Helm은 values.yaml의 모든 최상위 키를 subchart에 전달하려고 하는데, `x-`로 시작하는 키는 **Helm이 무시
**한다. 따라서 Anchor 정의용 블록이 subchart에 불필요하게 전달되는 것을 방지한다.
>
> YAML Anchor(`&`)와 Alias(`*`)는 **같은 YAML 파일 내에서만** 동작한다. 즉, `values-live.yaml`에서 정의한 Anchor를
`templates/deployment.yaml`에서 직접 참조할 수는 **없다**. Helm template은 Go template 엔진이 처리하고, YAML Anchor/Alias는 YAML 파서가 먼저
> 처리하기 때문이다.
>
> 저희 `values-live.yaml`에서는 Anchor를 같은 파일 내의 subchart values에서 참조한다:
> ```yaml
> x-backend-pod-security: &backend-pod-security
>   runAsNonRoot: true
>   runAsUser: 1000
>   fsGroup: 1000
>
> eam:
>   podSecurityContext: *backend-pod-security
> tlm:
>   podSecurityContext: *backend-pod-security
> ```
> 이렇게 하면 CIS Kubernetes Benchmark 5.2 보안 설정을 **한 곳에서 정의하고 10개 subchart에 일관되게 적용**할 수 있다.

> **키포인트**:
> - `x-` 접두사의 의미(Extension Fields, Helm이 무시)를 정확히 설명
> - YAML Anchor의 스코프(같은 파일 내에서만)를 이해
> - CIS Benchmark 보안 설정을 Anchor로 일관 적용한 설계 의도
> - 공식 문서: https://helm.sh/docs/chart_template_guide/yaml_techniques/

---

**Q3. 서비스별 리소스 할당이 상당히 큰데 (TLM 72GB, Observer 6G), 리소스 산정 기준은 뭐였나요?**

- **의도**: Kubernetes에서 리소스 request/limit 산정은 과학이 아닌 엔지니어링. 실제 운영 데이터 기반인지, 감으로 잡은 건지
- **꼬리질문 1**: "requests와 limits를 같게 설정하셨나요, 다르게 설정하셨나요? 이유는?"
- **꼬리질문 2**: "OOM Kill이 발생한 적이 있나요? 어떻게 대응했나요?"

> **모범 답변**:
>
> TLM이 72GB로 가장 큰 이유는 **3 API + 1 Consumer + 1 Excel 처리 = 5 pods**로 구성되어 있고, 각 Pod이 Spring Boot + JVM Heap 기반이라 메모리 소모가
> 큽니다. 특히 Excel 처리 Pod은 대량 데이터를 메모리에 로드하므로 단일 Pod에 12~14GB가 필요했다.
>
> 리소스 산정은 세 단계로 진행했다:
> 1. **개발 환경에서 기본 값 설정**: Spring Boot Actuator의 JVM 메트릭과 `kubectl top pod`로 평균 사용량 측정
> 2. **부하 테스트(k6)로 피크 사용량 측정**: 최대 동시 사용자 시나리오에서 메모리/CPU 사용량 관찰
> 3. **피크 사용량의 1.3~1.5배로 limit 설정**: 여유 버퍼 포함
>
> Observer(6G, 4G heap)는 Elasticsearch 쿼리 결과를 집계하는 로직이 있어서 JVM Heap 4G가 필요했고, 나머지 2G는 non-heap(Metaspace, Thread stack,
> Native memory)을 위한 것이다. **JVM 앱에서 limit = heap + 2G**가 일반적인 경험칙이다.
>
> requests와 limits는 **다르게 설정**했다. requests는 스케줄링에 사용되는 "보장된 리소스"이고 limits는 "최대 허용치"다. requests = limits로 설정하면 *
*Guaranteed QoS**가 되어 안정적이지만 리소스 효율이 떨어지고, 차이를 두면 **Burstable QoS**가 되어 유연하지만 OOM 위험이 있다. 저희는 **프로덕션 핵심 서비스(TLM, EAM)는
requests ≈ limits (Guaranteed)**, 비핵심 서비스는 차이를 두었다.

> **키포인트**:
> - 리소스 산정의 3단계 프로세스(기본값 -> 부하 테스트 -> 버퍼 추가)를 구체적으로 설명
> - JVM 앱의 메모리 구성(heap + non-heap)을 이해하고 limit 설정에 반영
> - QoS Class(Guaranteed vs Burstable)에 따른 서비스별 차등 전략
> - 공식 문서: https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/

---

**Q4. ArgoCD Image Updater의 semver 전략에서 환경별 태그 분리(`live-1.2.3`, `stg-1.2.3`)를 하셨는데, 이 패턴의 장단점은?**

- **의도**: 환경별 태그 접두사 전략은 Image Updater와 잘 맞지만, 이미지 불변성 관점에서 안티패턴일 수 있음
- **꼬리질문 1**: "같은 코드인데 dev-1.2.3과 live-1.2.3이 다른 이미지인 건가요? 아니면 같은 이미지에 태그만 다른 건가요?"
- **꼬리질문 2**: "이미지 불변성(Image Immutability) 원칙과 이 전략이 충돌하지 않나요?"

> **모범 답변**:
>
> 환경별 태그 접두사(`live-`, `stg-`, `dev-`)를 사용한 이유는 **Image Updater의 `allow-tags` 필터와 연동**하기 위해서다:
> ```yaml
> argocd-image-updater.argoproj.io/checkin.allow-tags: regexp:^live-.*
> argocd-image-updater.argoproj.io/checkin.ignore-tags: regexp:^(dev|stg)-.*
> ```
> 이렇게 하면 live 환경의 Image Updater는 `live-` 접두사 태그만 추적하고, dev/stg 태그는 무시한다.
>
> **이미지 불변성 관점**에서, 이상적으로는 **하나의 이미지를 빌드하고 동일한 digest를 모든 환경에서 사용**하는 것이 원칙이다. dev에서 테스트한 이미지와 live에 배포하는 이미지가 다르면 "
> dev에서는 됐는데 live에서 안 되는" 문제가 발생할 수 있다.
>
> 저희 구조에서는 **같은 코드를 환경별로 별도 빌드**하는 방식이므로, 이미지 불변성 원칙에 완벽히 부합하지는 않는다. 개선 방향은:
> - Git commit SHA 기반 단일 태그로 빌드 (`abc123`)
> - dev -> stg -> live 프로모션 시 **동일 이미지에 환경별 태그를 추가** (`docker tag`)
> - Image Updater 대신 **Git commit으로 values.yaml의 image tag를 직접 업데이트**하는 방식
>
> 다만 현재 구조를 선택한 현실적 이유는, 환경별 빌드 설정(`SPRING_PROFILES_ACTIVE` 등)이 빌드 시점에 주입되는 부분이 있었기 때문이다.

> **키포인트**:
> - 환경별 태그 전략의 Image Updater 연동 이점을 구체적으로 설명
> - 이미지 불변성 원칙과의 충돌을 솔직히 인정하고 개선 방향 제시
> - "같은 코드 다른 빌드" vs "같은 이미지 다른 태그"의 차이를 이해
> - 공식 문서: https://argocd-image-updater.readthedocs.io/en/stable/configuration/images/

---

### [팀원5: 정유진 - CI/CD 전문]

> 리뷰어 관점: 11년차 CI/CD 전문가. "Jenkins Shared Library + ArgoCD + Helm Umbrella + Argo Rollouts를 1년차 혼자 했다고? 코드 레벨로 파고들어서
> 검증하겠다."

---

**Q1. Jenkins에서 ArgoCD로 전환한 과정을 구체적으로 설명해주세요. 한번에 전환했나요, 점진적으로 했나요?**

- **의도**: "전환했다"가 실제 어떤 프로세스였는지. 빅뱅 전환 vs 점진적 전환, 트레이드오프를 경험했는지
- **꼬리질문 1**: "전환 중에 Jenkins CI와 ArgoCD CD가 공존하는 기간이 있었나요? 그때 어떤 문제가 있었나요?"
- **꼬리질문 2**: "전환 후 개발팀의 반응은 어땠나요? 배포 프로세스가 바뀌면 저항이 있었을 텐데요."

> **모범 답변**:
>
> 점진적으로 전환했다. 전체 과정은 약 **3단계**로 나눌 수 있다.
>
> **1단계 - Jenkins CI + Jenkins CD (기존 상태)**:
> Jenkins Shared Library의 `backendDeployBase.groovy`가 서버별로 SSH 접속해서 Docker container를 직접 교체하는 방식이었다. 코드에서 볼 수 있듯이
`TLM_SERVER1_IP`, `EAM_SERVER1_IP` 등 **서버 IP를 Jenkins 환경변수로 관리**하고, Rolling/All 타겟으로 서버별 배포를 제어했다.
>
> **2단계 - Jenkins CI + ArgoCD CD (전환 기간)**:
> Kubernetes 클러스터 구축 후, ArgoCD를 설치하고 Helm chart를 작성했다. 이 기간에는 **일부 서비스는 Jenkins 직접 배포, 일부 서비스는 ArgoCD GitOps**로
> 공존했다. 가장 큰 문제는 **배포 상태 확인의 이원화**였다. "이 서비스는 Jenkins에서 확인해야 하고, 저 서비스는 ArgoCD에서 확인해야 하는" 혼란이 있었다.
>
> **3단계 - Jenkins CI + ArgoCD CD (최종)**:
> 모든 서비스를 ArgoCD로 이관 완료. Jenkins는 **CI(빌드 + Harbor Push)만** 담당하고, CD(배포)는 **전적으로 ArgoCD**가 담당한다.
>
> 개발팀 반응은 초기에 **"왜 바꿔야 하는지"에 대한 의문**이 있었다. 기존 Jenkins 배포는 "빌드 버튼 하나 누르면 끝"이었는데, GitOps는 "Git에 커밋해야 배포된다"는 개념이 생소했다.
> ArgoCD UI에서 **배포 상태를 실시간으로 시각화**할 수 있다는 점과, **롤백이 `git revert`로 가능**하다는 점을 데모로 보여주면서 수용도가 높아졌다.

> **키포인트**:
> - 3단계 점진적 전환 과정을 구체적으로 설명 (기존 코드 참조)
> - 공존 기간의 실제 문제(상태 확인 이원화)를 경험 기반으로 언급
> - 개발팀 저항에 대한 현실적 대응(데모, 시각화, 롤백 편의성)
> - 공식 문서: https://argo-cd.readthedocs.io/en/stable/getting_started/

---

**Q2. Shared Library의 `backendBuildBase.groovy`에서 버전을 `AUTO_VERSION_DETECTION`으로 GitHub Release에서 자동 탐지하는 로직을 설명해주세요. 이
방식의 장단점은?**

- **의도**: 실제 코드를 직접 짠 사람인지 검증. 로직의 동작 흐름과 edge case를 이해하고 있는지
- **꼬리질문 1**: "GitHub Release가 없으면 `latest` 태그로 빌드하는데, 프로덕션에 `latest` 태그를 쓰면 어떤 문제가 있나요?"
- **꼬리질문 2**: "`normalizeVersionTag()`는 어떤 변환을 하나요? `v1.2.3`을 `1.2.3`으로 바꾸는 건가요?"

> **모범 답변**:
>
> `backendBuildBase.groovy`의 `determineBuildVersion()` 함수에서 버전 결정 로직은 **3단계 폴백 구조**다:
>
> 1. `params.TARGET_VERSION`이 명시적으로 지정되면 -> 해당 버전 사용 (형식 검증 후)
> 2. `params.AUTO_VERSION_DETECTION = true`이면 -> GitHub Enterprise API(`/api/v3/repos/{owner}/{repo}/releases/latest`)를
     호출해서 최신 Release 태그를 자동 탐지
> 3. 둘 다 아니면 -> `latest` 폴백
>
> GitHub API 호출은 `gitUtils.groovy`의 `detectLatestReleaseFromGitHub()`에서 수행한다. `withCredentials`로 GitHub 토큰을 주입하고,
`curl`로 API를 호출한 뒤 **`@NonCPS parseGitHubReleaseResponse()`**로 JSON을 파싱한다. `@NonCPS`를 사용하는 이유는 `JsonSlurper`가 반환하는
`LazyMap`이 Serializable하지 않아서 CPS 변환 시 `NotSerializableException`이 발생하기 때문이다.
>
> `normalizeVersionTag()`는 `v1.2.3` -> `1.2.3`으로 `v` 접두사를 제거하고, `^[0-9]+\.[0-9]+\.[0-9]+$` 정규식으로 유효한 Semver 형식인지 검증한다.
>
> **장점**: 개발자가 GitHub Release만 생성하면 빌드 파이프라인이 자동으로 버전을 인식. 수동 버전 입력 실수 방지.
>
> **단점**: GitHub API 의존성. API가 느리거나 타임아웃(30초 설정)되면 빌드가 `latest`로 폴백. **프로덕션에 `latest` 태그가 배포되면** 어떤 버전인지 특정할 수 없고,
`IfNotPresent` imagePullPolicy와 조합 시 캐시된 구버전 이미지가 계속 사용되는 심각한 문제가 생긴다.

> **키포인트**:
> - 3단계 폴백 구조를 코드 흐름 그대로 설명
> - `@NonCPS`의 필요성(JsonSlurper NotSerializableException)을 CPS 동작 원리와 연결
> - `latest` 태그의 위험성(버전 불확정, imagePullPolicy 캐시 문제)을 명확히 인지
> - 공식 문서: https://www.jenkins.io/doc/book/pipeline/cps-method-mismatches/

---

**Q3. `dockerUtils.groovy`에서 Harbor의 이전 버전을 자동 탐지하는 `detectRollbackVersionFromHarbor()` 로직을 설명해주세요.**

- **의도**: 롤백 자동화의 구현 상세를 직접 설계한 사람인지 검증. Harbor API 연동과 버전 비교 로직
- **꼬리질문 1**: "`findPreviousVersionBeforeLatest()`에서 latest의 push_time과 다른 첫 Semver 태그를 선택한다고 했는데, 같은 시간에 여러 태그를 push하면
  어떻게 되나요?"
- **꼬리질문 2**: "이 로직이 실패하면(롤백 버전을 못 찾으면) 배포 파이프라인은 어떻게 되나요?"

> **모범 답변**:
>
> `detectRollbackVersionFromHarbor()`는 Harbor API v2.0의 아티팩트 목록 조회 엔드포인트를 사용한다:
> ```
> GET /api/v2.0/projects/{project}/repositories/{image}/artifacts?page_size=50&with_tag=true
> ```
>
> 응답을 `@NonCPS parseHarborResponse()`로 파싱하여 `[name, pushTime]` 리스트를 만들고, `pushTime` 역순(최신순)으로 정렬한다.
>
> `findPreviousVersionBeforeLatest()`의 로직:
> 1. `latest` 태그의 `pushTime`을 찾음
> 2. `latest`와 **다른 `pushTime`**을 가진 첫 번째 Semver 태그를 선택
> 3. 이것이 "현재 배포된 버전의 직전 버전" = 롤백 대상
>
> **같은 시간에 여러 태그를 push하는 경우**: 저희 파이프라인에서 version 태그와 latest 태그를 동시에 push하므로 **같은 pushTime**을 가진다.
`findPreviousVersionBeforeLatest()`가 "latest와 다른 pushTime"을 조건으로 하기 때문에, **방금 push한 version 태그는 건너뛰고 그 이전 버전을 정확히 찾는다.
** 이것이 의도한 설계다.
>
> 롤백 버전을 못 찾으면 `null`을 반환하고, `backendDeployBase.groovy`의 `determineRollbackVersion()`에서 경고 로그만 출력한다. 배포 자체는 **롤백 버전 없이도
진행 가능**하다. 다만 롤백이 필요한 상황에서 자동 롤백이 불가능하고 수동으로 이전 버전을 지정해야 한다.

> **키포인트**:
> - Harbor API v2.0 엔드포인트와 파라미터를 정확히 인용
> - "같은 pushTime" 조건의 설계 의도를 논리적으로 설명
> - 롤백 버전 미탐지 시 graceful degradation(경고 후 계속 진행) 전략
> - 공식 문서: https://goharbor.io/docs/2.0.0/build-customize-contribute/configure-swagger/

---

**Q4. Helm Umbrella Chart에서 `condition` 기반 활성화 패턴의 한계는 뭐라고 생각하나요? 대안은?**

- **의도**: condition 패턴을 "사용만" 한 건지, 한계를 인지하고 대안을 고민해봤는지
- **꼬리질문 1**: "`eam.enabled: true`를 설정하지 않으면 EAM subchart가 아예 렌더링되지 않는 건가요?"
- **꼬리질문 2**: "서비스가 30개, 50개로 늘어나면 이 구조가 유지 가능한가요?"

> **모범 답변**:
>
> `condition` 기반 활성화의 한계는 몇 가지 있다:
>
> **1. Chart.yaml에 모든 dependency를 하드코딩**: 새 서비스를 추가하려면 Chart.yaml에 dependency를 추가하고, values.yaml에
`{service}.enabled: true`를 추가해야 한다. 서비스가 30개 이상이면 Chart.yaml이 비대해지고 관리가 어려워진다.
>
> **2. dependency 업데이트 시 전체 Chart Lock**: `helm dependency update`를 실행하면 모든 subchart의 lock이 갱신된다. 한 subchart만 수정해도 전체에
> 영향을 줄 수 있다.
>
> **3. 버전 관리의 경직성**: 현재 모든 subchart가 `version: "1.0.0"`으로 고정되어 있는데, subchart별 독립적 버전 관리가 어렵다.
>
> **대안**:
> - **서비스별 독립 Chart + ArgoCD App of Apps 패턴**: 각 서비스를 독립 Chart로 분리하고, ArgoCD의 "App of Apps" 패턴으로 한 Application이 다른
    Application들을 관리하는 구조. 서비스가 50개 이상일 때 더 적합하다.
> - **Kustomize 전환**: Helm의 template 복잡성 없이 overlay 방식으로 환경별 설정을 관리. 단, Helm의 패키징/버저닝 기능을 잃게 된다.
>
> 현재 10개 subchart 수준에서는 Umbrella Chart가 관리 가능한 범위이고, 서비스가 크게 늘어날 때 App of Apps로 전환하는 것이 현실적인 마이그레이션 경로라고 생각한다.

> **키포인트**:
> - condition 패턴의 3가지 구체적 한계를 설명
> - App of Apps 패턴과 Kustomize를 대안으로 제시하면서 트레이드오프 비교
> - "현재 규모에서는 적합하지만 확장 시 전환 필요"라는 현실적 판단
> - 공식 문서: https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/

---

**Q5. Argo Rollouts의 Canary 배포에서 Kong Gateway API와 트래픽 라우팅을 연동했다고 했는데, HTTPRoute의 weight는 어떻게 자동으로 조절되나요?**

- **의도**: Argo Rollouts + Gateway API 연동의 동작 원리를 이해하고 있는지. 단순히 "설정했다"가 아니라 트래픽이 실제로 어떻게 분리되는지
- **꼬리질문 1**: "Canary와 Stable Service가 별도로 필요한 이유는? 하나의 Service로 안 되나요?"
- **꼬리질문 2**: "Canary 배포 중 Abort(롤백)가 발생하면 트래픽 전환은 어떻게 되나요?"

> **모범 답변**:
>
> Argo Rollouts의 Gateway API 플러그인(`argoproj-labs/gatewayAPI`)이 동작하는 흐름:
>
> 1. Rollout 리소스에 새 이미지 태그가 반영되면 **Canary ReplicaSet**이 생성됨
> 2. Rollout Controller가 `steps`에 따라 `setWeight: 10`을 실행
> 3. Controller가 지정된 **HTTPRoute 리소스의 `backendRefs` weight를 자동 수정**:
     >

- `checkin-stable`: weight 90

> - `checkin-canary`: weight 10
> 4. Kong Gateway가 HTTPRoute 변경을 감지하고 트래픽 비율을 재설정
>
> **Canary/Stable Service 분리가 필요한 이유**: Argo Rollouts는 Canary Pod과 Stable Pod을 구분하기 위해 **`rollouts-pod-template-hash`
라벨을 자동으로 주입**한다. Canary Service는 Canary hash 라벨이 있는 Pod만 선택하고, Stable Service는 Stable hash 라벨이 있는 Pod만 선택한다. 하나의
> Service로는 이 **트래픽 분리가 불가능**하다.
>
> **Abort 시 트래픽 전환**: Rollout이 Abort되면 Controller가 즉시 HTTPRoute를 **stable: 100%, canary: 0%**로 되돌린다. Canary Pod은
`abortScaleDownDelaySeconds: 30` 설정에 따라 **30초간 유지** 후 삭제된다. 이 30초는 로그 수집과 디버깅을 위한 시간이다.

> **키포인트**:
> - HTTPRoute weight 자동 조절의 전체 흐름(Rollout -> Controller -> HTTPRoute -> Kong)을 단계별로 설명
> - `rollouts-pod-template-hash` 라벨에 의한 Service 분리 메커니즘
> - Abort 시 트래픽/Pod 처리 과정과 `abortScaleDownDelaySeconds`의 역할
> - 공식 문서: https://argoproj.github.io/argo-rollouts/features/traffic-management/plugins/

---

### [팀원6: 한소윤 - EM(Engineering Manager)]

---

**Q1. 1인 DevOps로 이 규모의 CI/CD 파이프라인을 구축하면서 가장 어려웠던 점은 뭐였나요?**

- **의도**: 기술적 역량뿐 아니라 1인 DevOps의 현실적 어려움(의사결정, 우선순위, 소통)을 경험했는지
- **꼬리질문 1**: "기술적으로 막혔을 때 어떻게 해결하셨나요? 사내에 DevOps 시니어가 없었잖아요."
- **꼬리질문 2**: "개발팀이 DevOps의 가치를 이해 못 할 때 어떻게 설득하셨나요?"

> **모범 답변**:
>
> 가장 어려웠던 것은 **"무엇을 먼저 할 것인가"의 우선순위 결정**이었다. Jenkins CI, ArgoCD CD, Helm Chart, 모니터링, 보안 등 해야 할 일이 산더미인데, 1인이라 동시에 진행할
> 수 없었다.
>
> 우선순위 결정 기준은 **"개발팀의 가장 큰 고통점"**이었다:
> 1. 빌드/배포에 매번 수동 작업이 필요 -> **Jenkins Shared Library로 자동화** (1순위)
> 2. 배포 상태를 Jenkins 로그에서만 확인 가능 -> **ArgoCD UI로 시각화** (2순위)
> 3. 환경별 설정 관리가 혼란 -> **Helm Chart로 환경별 values 분리** (3순위)
>
> 기술적으로 막혔을 때는 **공식 문서 + GitHub Issues + 커뮤니티(CNCF Slack)**를 활용했다. 예를 들어 ArgoCD ApplicationSet의 Git Directory
> Generator에서 values 파일 매핑이 안 되는 이슈가 있었는데, ArgoCD GitHub Issues에서 유사 사례를 찾아 해결했다.
>
> 개발팀 설득은 **"이전과 이후"를 숫자로 보여주는 것**이 가장 효과적이었다:
> - 배포 소요 시간: 30분(수동) -> 10분(자동)
> - 배포 실수율: 월 2~3건 -> 0건
> - 새 서비스 온보딩: 2~3일 -> 반나절

> **키포인트**:
> - 우선순위 결정 기준("개발팀의 고통점")이 명확
> - 문제 해결 방법(공식 문서, GitHub Issues, 커뮤니티)이 구체적
> - 정량적 성과 제시(배포 시간, 실수율, 온보딩 시간)
> - EM이 듣고 싶은 답변: 기술 + 커뮤니케이션 + 임팩트 측정

---

**Q2. 이 CI/CD 아키텍처에서 가장 큰 기술 부채(Tech Debt)는 뭐라고 생각하시나요?**

- **의도**: 자기 시스템의 약점을 객관적으로 평가할 수 있는지. "완벽합니다"는 비현실적
- **꼬리질문 1**: "그 기술 부채를 해결하기 위한 로드맵이 있나요?"
- **꼬리질문 2**: "만약 팀원이 3명 더 있었다면 가장 먼저 시킬 일은?"

> **모범 답변**:
>
> 기술 부채는 크게 세 가지다:
>
> **1. Shared Library 테스트 부재**: 가장 심각한 부채다. `backendBuildBase.groovy`, `dockerUtils.groovy` 등의 단위 테스트가 없다. Shared
> Library가 모든 파이프라인의 단일 의존점이므로, 여기에 버그가 들어가면 **전체 서비스의 빌드/배포가 동시에 깨진다.** JenkinsPipelineUnit 프레임워크로 테스트를 작성하는 것이 최우선
> 과제다.
>
> **2. 이미지 불변성 미확보**: 현재 환경별로 별도 빌드하는 구조라, dev에서 테스트한 이미지와 live에 배포되는 이미지가 동일하지 않을 수 있다. **빌드 한 번, 프로모션으로 환경 이동**하는
> 구조로 전환해야 한다.
>
> **3. Jenkins 의존도**: Jenkins Controller가 SPOF이고, Groovy DSL의 유지보수 부담이 크다. 장기적으로 **Tekton(K8s 네이티브 CI)**이나 **GitHub
Actions**로 CI를 전환하는 것이 바람직하다.
>
> 팀원이 3명 더 있었다면:
> - 1명: Shared Library 테스트 코드 작성 + CI 파이프라인 자체의 CI(메타 파이프라인)
> - 1명: 이미지 빌드 파이프라인 개선(불변성 확보, Multi-stage 최적화)
> - 1명: 모니터링/알림 체계 고도화(ArgoCD Notification, Rollout 메트릭 대시보드)

> **키포인트**:
> - 기술 부채를 우선순위 순으로 나열하고 각각의 영향도를 설명
> - "테스트 부재"를 가장 심각한 부채로 꼽는 것 = 품질에 대한 인식
> - 팀 확장 시 인원 배분까지 구체적으로 제시 = 리드/시니어 사고
> - EM 관점에서 "자기 시스템의 약점을 솔직히 인정하고 개선 계획이 있는" 엔지니어는 신뢰감이 높음

---

**Q3. "Jenkins에서 ArgoCD로 전환했다"는 이력을 가지고 있는데, 새 회사에서 GitHub Actions를 쓰라고 하면 어떤 부분이 쉽고 어떤 부분이 어려울까요?**

- **의도**: 도구에 종속적인 엔지니어인지, 아니면 CI/CD의 핵심 원리를 이해하고 있어서 도구가 바뀌어도 적응 가능한지
- **꼬리질문 1**: "GitHub Actions의 Reusable Workflow가 Jenkins Shared Library와 어떻게 대응되나요?"
- **꼬리질문 2**: "GitHub Actions에서 self-hosted runner를 운영해본 적 있나요?"

> **모범 답변**:
>
> **쉬운 부분 (도구 무관 원리)**:
> - **파이프라인 설계**: 체크아웃 -> 빌드 -> 테스트 -> 이미지 빌드 -> Push -> 배포의 흐름은 동일하다. Jenkins에서 stage로 나누던 것을 GitHub Actions에서는
    job/step으로 나누면 된다.
> - **재사용 가능한 구조**: Jenkins Shared Library의 `vars/` 함수가 GitHub Actions의 **Reusable Workflow**(
    `.github/workflows/reusable-build.yml`)와 **Composite Actions**에 대응된다. 함수 단위 재사용이 워크플로우/액션 단위 재사용으로 바뀌는 것뿐이다.
> - **Credential 관리**: Jenkins Credentials Store가 GitHub Actions의 **Secrets**(Repository/Organization Secrets)로 대응된다.
> - **Docker 빌드 최적화**: BuildKit, Multi-stage build, 레이어 캐싱은 도구와 무관하다.
>
> **어려운 부분 (GitHub Actions 고유)**:
> - **YAML 기반 워크플로우 문법**: Jenkins의 Groovy DSL과 달리 YAML 기반이라 프로그래밍적 유연성이 낮다. 복잡한 분기 로직은 별도 스크립트로 분리해야 한다.
> - **Marketplace 생태계**: GitHub Actions의 강점인 Marketplace Actions(3rd party)를 효과적으로 활용하려면 학습이 필요하다.
> - **OIDC 기반 클라우드 인증**: AWS/GCP와 연동 시 OIDC를 사용하는 패턴은 Jenkins에서 경험하지 못한 부분이다.
> - **Matrix Strategy**: 멀티 환경/멀티 플랫폼 빌드를 위한 matrix 전략은 새로 학습해야 한다.
>
> "바로 프로덕션 수준으로 할 수 있다"고 말하기는 어렵지만, CI/CD의 **핵심 원리(파이프라인 표준화, 재사용, credential 관리, 이미지 최적화)**를 실무에서 경험했기 때문에 **러닝커브는 짧을 것
**이라고 자신한다.

> **키포인트**:
> - "도구가 바뀌어도 변하지 않는 원리"를 구체적으로 나열 = 도구 비종속적 엔지니어
> - Jenkins -> GitHub Actions 용어 매핑(Shared Library -> Reusable Workflow, Credentials -> Secrets)
> - 모르는 부분(OIDC, Matrix)을 솔직히 인정하면서 빠른 적응 자신감
> - 공식 문서: https://docs.github.com/en/actions/sharing-automations/reusing-workflows

---

## 부록: 실제 코드 경로 맵

| 구성요소                                   | 경로                                                                     |
|----------------------------------------|------------------------------------------------------------------------|
| Jenkins Shared Library (Live Backend)  | `backdoor/ci/jenkins/live/backend/vars/`                               |
| Jenkins Shared Library (Stg Backend)   | `backdoor/ci/jenkins/stg/backend/vars/`                                |
| Jenkins Shared Library (Live Frontend) | `backdoor/ci/jenkins/live/frontend/vars/`                              |
| Helm Umbrella Chart                    | `backdoor/deployments/helm/charts/service-platform/`                       |
| Helm Chart.yaml (dependencies)         | `backdoor/deployments/helm/charts/service-platform/Chart.yaml`             |
| values-live.yaml                       | `backdoor/deployments/helm/charts/service-platform/values-live.yaml`       |
| Kong Gateway Chart                     | `backdoor/deployments/helm/charts/kong-gateway/`                       |
| ArgoCD 설치                              | `backdoor/infrastructure/k8s/phase7-tools/51-install-argocd.sh`        |
| Argo Rollouts 설치                       | `backdoor/infrastructure/k8s/phase7-tools/52-install-argo-rollouts.sh` |
| ApplicationSet 설정                      | `backdoor/infrastructure/k8s/phase7-tools/57-setup-argocd-appset.sh`   |

---

## 부록: 핵심 공식 문서 링크

- Jenkins Pipeline: https://www.jenkins.io/doc/book/pipeline/
- Jenkins Shared Libraries: https://www.jenkins.io/doc/book/pipeline/shared-libraries/
- Jenkins CPS: https://www.jenkins.io/doc/book/pipeline/cps-method-mismatches/
- ArgoCD: https://argo-cd.readthedocs.io/en/stable/
- ArgoCD ApplicationSet: https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/
- ArgoCD Image Updater: https://argocd-image-updater.readthedocs.io/en/stable/
- Argo Rollouts: https://argoproj.github.io/argo-rollouts/
- Helm Dependency: https://helm.sh/docs/helm/helm_dependency/
- Harbor API: https://goharbor.io/docs/2.0.0/build-customize-contribute/configure-swagger/
- Kubernetes Deployment Strategy: https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#strategy
- GitHub Actions Reusable Workflows: https://docs.github.com/en/actions/sharing-automations/reusing-workflows
