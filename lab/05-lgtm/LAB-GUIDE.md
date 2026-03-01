# LGTM Observability Stack 핸즈온 랩

## 학습 목표

1. LGTM(Loki, Grafana, Tempo, Mimir) 스택의 역할과 데이터 흐름 이해
2. Grafana Alloy를 통한 메트릭/로그/트레이스 수집 파이프라인 구성
3. Grafana에서 메트릭-로그-트레이스 간 상관관계(correlation) 확인
4. Cilium Hubble + Istio ztunnel 메트릭 통합 관찰

## 전제 조건

- LGTM Stack 설치 완료: `kubectl get pods -n monitoring`
- Demo App 배포 완료: `kubectl get pods -n demo`

### UI 접속 정보

| 항목 | 값 |
|------|-----|
| **Kong URL (권장)** | `http://grafana.lab-dev.local` |
| **Fallback (port-forward)** | `kubectl port-forward svc/grafana -n monitoring 3000:80` → `http://localhost:3000` |
| **Username** | `admin` |
| **Password** | `kubectl -n monitoring get secret grafana -o jsonpath="{.data.admin-password}" \| base64 -d` |

> **Note**: 기본 비밀번호가 `admin`이 아닐 수 있다. 반드시 위 명령으로 Secret에서 추출한 비밀번호를 사용한다.

---

## 실습 1: Grafana Datasource 확인

### 배경 지식

Grafana는 데이터를 직접 저장하지 않고, 외부 datasource에 쿼리한다.
이 랩에서는 values-grafana.yaml의 provisioning으로 3개 datasource가 자동 등록된다.

### 실습 단계

```bash
# 1. Grafana 포트 포워딩
kubectl port-forward svc/grafana -n monitoring 3000:80

# 2. 브라우저 접속: http://localhost:3000 (admin/admin)

# 3. Configuration → Data Sources 확인
#    - Mimir (Prometheus 호환): 메트릭 쿼리
#    - Loki: 로그 쿼리
#    - Tempo: 트레이스 쿼리
```

#### UI에서 확인

1. **Data Sources 화면 접속**: 좌측 메뉴 ⚙️ → **Data sources** 클릭
2. **등록된 데이터소스 확인**: 다음 4개가 provisioning으로 자동 등록되어 있음
   - **Mimir** (Prometheus 호환): 메트릭 저장소
   - **Loki**: 로그 저장소
   - **Tempo**: 트레이스 저장소
   - **Prometheus** (Alloy self-monitoring): 수집기 자체 메트릭
3. **연결 테스트**: 각 데이터소스를 클릭 → 하단 **Save & test** 버튼 클릭
   - `Data source is working` 메시지가 표시되면 정상
   - 실패 시 해당 백엔드 Pod 상태를 `kubectl get pods -n monitoring`으로 확인

---

## 실습 2: PromQL로 메트릭 조회 (Mimir)

### 실습 단계

```bash
# Grafana → Explore → Mimir datasource 선택

# 1. Cilium 네트워크 드롭 메트릭
hubble_drop_total

# 2. Cilium HTTP 요청 메트릭
hubble_http_requests_total

# 3. ztunnel TCP 연결 메트릭
istio_tcp_connections_opened_total

# 4. 컨테이너 메모리 사용량 (kubelet 메트릭)
container_memory_working_set_bytes{namespace="demo"}
```

#### UI에서 확인

1. **Explore 진입**: 좌측 메뉴 🧭 **Explore** 클릭
2. **Mimir 선택**: 상단 데이터소스 드롭다운에서 **Mimir** 선택
3. **Code 모드 전환**: 쿼리 입력 영역 우측의 **Code** 버튼 클릭 (Builder 모드에서 전환)
4. **PromQL 입력 및 실행**:
   - 쿼리 입력란에 `container_memory_working_set_bytes{namespace="demo"}` 입력
   - **Run query** (또는 `Shift+Enter`) 클릭
5. **결과 시각화 토글**:
   - **Graph**: 시계열 그래프로 메트릭 추이 확인 (기본값)
   - **Table**: 현재 시점의 값을 테이블로 확인
   - 우측 시간 범위 피커에서 `Last 15 minutes` → `Last 1 hour` 등으로 범위 조절

### 핵심 포인트

> Q: "Prometheus와 Mimir의 차이?"
> A: Prometheus는 Pull 기반 로컬 TSDB, Mimir는 remote_write 기반 분산 스토리지.
> Prometheus는 단일 노드에 데이터가 저장되어 디스크 용량과 보존 기간에 한계.
> Mimir는 S3/GCS에 블록을 저장하여 무제한 확장 가능하고,
> PromQL 100% 호환이므로 기존 쿼리/대시보드를 그대로 사용할 수 있다.

---

## 실습 3: LogQL로 로그 조회 (Loki)

### 실습 단계

```bash
# Grafana → Explore → Loki datasource 선택

# 1. demo 네임스페이스 전체 로그
{namespace="demo"}

# 2. 특정 Pod 로그
{namespace="demo", pod=~"frontend.*"}

# 3. 에러 로그 필터
{namespace="demo"} |= "error"

# 4. JSON 파싱 + 필드 추출
{namespace="istio-system", container="ztunnel"} | json | line_format "{{.msg}}"

# 5. 로그 빈도 집계 (Log Metrics)
rate({namespace="demo"}[5m])
```

#### UI에서 확인

1. **Explore에서 Loki 선택**: 상단 데이터소스 드롭다운에서 **Loki** 선택
2. **Builder 모드로 쿼리 작성**:
   - **Label filters**: `namespace` = `demo` 선택
   - 라벨 값 옆 🔍 돋보기 아이콘 클릭으로 사용 가능한 값 자동 완성
   - **Line contains**: `error` 입력 → 에러 로그만 필터링
3. **Code 모드로 전환**: LogQL 직접 입력
   - `{namespace="demo"} |= "error"` 입력 후 Run query
4. **Live tail 모드**:
   - 우측 상단 **Live** 버튼 클릭
   - 실시간으로 유입되는 로그가 스트리밍됨
   - 다른 터미널에서 `kubectl -n demo exec deploy/frontend -- wget -qO- http://backend:8080` 실행하여 로그 발생 확인
   - **Stop** 버튼으로 스트리밍 중지

### 핵심 포인트

> Q: "Loki와 Elasticsearch의 차이?"
> A: Loki는 로그 내용을 인덱싱하지 않고 라벨만 인덱싱한다.
> Elasticsearch는 전문(full-text) 인덱싱으로 검색 속도가 빠르지만
> 인덱스 관리 비용(스토리지, CPU)이 Loki 대비 10-100배다.
> Loki는 "Prometheus for logs" — 라벨 기반 필터 + grep 방식으로
> 간단한 로그 분석에 적합하며, 대규모 환경에서 비용 효율적이다.

---

## 실습 4: 트레이스 조회 (Tempo)

### 실습 단계

```bash
# Grafana → Explore → Tempo datasource 선택

# 1. 서비스별 트레이스 검색
# Search 탭 → Service Name: frontend → Find Traces

# 2. Trace ID로 직접 검색
# 특정 Trace ID 입력 → 전체 스팬 트리 확인

# 3. Service Map 확인
# Grafana → Explore → Tempo → Service Graph
# 서비스 간 의존성과 지연시간을 시각적으로 확인
```

#### UI에서 확인

1. **Explore에서 Tempo 선택**: 상단 데이터소스 드롭다운에서 **Tempo** 선택
2. **Search 탭으로 트레이스 검색**:
   - **Service Name** 드롭다운에서 서비스 선택 (예: `frontend`)
   - **Span Name**: 특정 오퍼레이션 필터링 (선택사항)
   - **Min Duration / Max Duration**: 느린 요청 필터링 (예: `> 100ms`)
   - **Find Traces** 버튼 클릭 → 매칭되는 트레이스 목록 표시
3. **Span 트리 해석**: 트레이스 하나를 클릭하면 상세 화면이 열림
   - 각 Span은 하나의 서비스 호출 구간을 나타냄
   - Span의 가로 길이 = 소요 시간 (긴 Span이 병목)
   - 부모-자식 관계로 호출 체인을 시각화
   - 각 Span 클릭 → 태그(HTTP status, method 등)와 로그 확인 가능

### 핵심 포인트

> Q: "분산 트레이싱은 어떻게 동작하나요?"
> A: 요청이 서비스를 거칠 때마다 고유 Trace ID와 Span ID가 HTTP 헤더로 전파된다.
> 각 서비스는 자신의 처리 시간을 Span으로 기록하고 Tempo로 전송한다.
> Tempo는 같은 Trace ID의 Span을 모아 전체 요청 경로를 재구성한다.
> Istio Ambient Mode에서는 ztunnel이 자동으로 트레이스 헤더를 전파한다.

---

## 실습 5: 메트릭-로그-트레이스 상관관계 (Correlation)

### 배경 지식

관측성의 3대 축(Metrics, Logs, Traces)을 서로 연결하면 문제 진단 속도가 획기적으로 향상된다.

```
[메트릭 이상 감지] → [관련 로그 확인] → [트레이스로 병목 식별]
```

### 실습 단계

```bash
# 1. 메트릭에서 이상 감지
#    Grafana → Dashboard → HTTP Error Rate 패널
#    → 에러 급증 구간 발견

# 2. 메트릭 → 로그로 점프
#    패널 우클릭 → Explore → Loki
#    → 동일 시간대의 에러 로그 확인

# 3. 로그 → 트레이스로 점프
#    로그 라인의 traceID 클릭 → Tempo에서 트레이스 열기
#    → 어떤 서비스에서 지연이 발생했는지 Span 트리로 확인

# 4. Tempo Service Map에서 전체 의존성 시각화
#    어떤 서비스 간 통신에서 에러가 발생하는지 한눈에 파악
```

#### UI에서 확인: 메트릭 → 로그 → 트레이스 상관관계 점프

1. **메트릭에서 출발**: Explore → **Mimir** 선택 → `rate(hubble_http_requests_total{namespace="demo"}[5m])` 실행
   - 그래프에서 에러율이 높은 시간대를 드래그하여 시간 범위 선택
2. **로그로 점프**: 데이터소스를 **Loki**로 전환
   - 시간 범위가 유지된 상태에서 `{namespace="demo"} |= "error"` 실행
   - 동일 시간대의 에러 로그가 표시됨
3. **트레이스로 점프**: 로그 라인을 펼치면 `traceID` 필드가 보임
   - traceID 값 클릭 → 자동으로 **Tempo**에서 해당 트레이스가 열림
   - Span 트리에서 어떤 서비스 구간에서 에러/지연이 발생했는지 확인
4. **핵심**: 데이터소스를 전환해도 **시간 범위가 유지**되므로 동일 시간대의 메트릭-로그-트레이스를 교차 확인할 수 있다

### 핵심 포인트

> Q: "관측성을 어떻게 구성했나요?"
> A: LGTM 스택으로 구성했다. Grafana Alloy가 DaemonSet으로
> 모든 노드에서 메트릭/로그/트레이스를 수집하고,
> Mimir(메트릭), Loki(로그), Tempo(트레이스)로 각각 전송한다.
> Grafana에서 세 가지 데이터를 상관관계로 연결하여
> 메트릭 이상 → 로그 확인 → 트레이스 병목 식별까지 한 화면에서 가능하다.

---

## 실습 6: Cilium + Istio 메트릭 통합 관찰

### 실습 단계

```bash
# 1. Cilium Hubble 메트릭 (L3/L4 레벨)
#    Grafana → Explore → Mimir
hubble_flows_processed_total{source_namespace="demo"}
hubble_dns_queries_total
hubble_drop_total{reason!=""}

# 2. Istio ztunnel 메트릭 (L4 mTLS 레벨)
istio_tcp_connections_opened_total{reporter="source"}
istio_tcp_sent_bytes_total{destination_workload="backend"}

# 3. 두 레이어 비교
# Cilium: 패킷 레벨 관찰 (eBPF 기반)
# Istio: 연결 레벨 관찰 (mTLS 터널 기반)
# → 같은 트래픽을 다른 관점에서 관찰 가능
```

---

## 실습 7: Spring Boot OTel 계측 + Grafana UI 심화

### 배경 지식

현재 Lab의 demo 앱(httpbin)은 OTel 미계측 상태라, Istio/Cilium이 생성한 인프라 레벨 트레이스만 확인할 수 있다.
프로덕션 환경에서는 **애플리케이션 내부**의 메서드 호출, DB 쿼리, 메시지 발행까지 계측해야 병목을 정확히 식별할 수 있다.

이 실습에서는 Spring Boot 앱에 OTel Java Agent를 적용하는 방법과, 생성되는 메트릭/로그/트레이스를 Grafana UI에서 심층 활용하는 방법을 다룬다.

### Part A: OTel 계측 설정 가이드

#### A-1. 계측 방식 비교

| 항목 | OTel Java Agent (`-javaagent`) | Micrometer + OTel Bridge |
|------|------|------|
| 코드 변경 | 제로 코드 (bytecode instrumentation) | 의존성 추가 + `application.yml` 설정 |
| 자동 계측 | HTTP, JDBC, Kafka, gRPC, Redis 등 80+ 라이브러리 | Spring MVC/WebFlux HTTP만 기본 |
| K8s 운영 | **init container 패턴** (앱 이미지 변경 불필요) | 앱 빌드에 포함 필요 |
| 프로덕션 권장 | **권장** — 운영팀이 앱 코드 변경 없이 관측성 추가 | 개발팀이 직접 관리할 때 적합 |

> **공식 문서**: [OpenTelemetry Java Agent](https://opentelemetry.io/docs/zero-code/java/agent/)

#### A-2. K8s init container 패턴

OTel Java Agent를 init container로 다운로드 → `emptyDir` 볼륨 → 앱 컨테이너의 `JAVA_TOOL_OPTIONS`에 `-javaagent` 지정.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: spring-app
  namespace: demo
spec:
  template:
    spec:
      initContainers:
        - name: otel-agent
          image: ghcr.io/open-telemetry/opentelemetry-java-instrumentation/opentelemetry-javaagent:latest
          command: ["cp", "/javaagent.jar", "/otel/javaagent.jar"]
          volumeMounts:
            - name: otel-agent
              mountPath: /otel
      containers:
        - name: app
          image: my-spring-app:latest
          env:
            - name: JAVA_TOOL_OPTIONS
              value: "-javaagent:/otel/javaagent.jar"
            - name: OTEL_EXPORTER_OTLP_ENDPOINT
              value: "http://otel-collector.monitoring.svc:4317"
            - name: OTEL_SERVICE_NAME
              value: "spring-app"
            - name: OTEL_TRACES_SAMPLER
              value: "always_on"
            - name: OTEL_LOGS_EXPORTER
              value: "otlp"
            - name: OTEL_METRICS_EXPORTER
              value: "otlp"
            - name: OTEL_RESOURCE_ATTRIBUTES
              value: "service.namespace=demo,service.version=1.0.0,deployment.environment=dev"
          volumeMounts:
            - name: otel-agent
              mountPath: /otel
      volumes:
        - name: otel-agent
          emptyDir: {}
```

**핵심 환경변수 설명**:

| 환경변수 | 값 | 이유 |
|---------|---|------|
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://otel-collector.monitoring.svc:4317` | 기존 OTel Collector로 전송 |
| `OTEL_SERVICE_NAME` | 앱명 | Tempo Service Map 노드명 |
| `OTEL_TRACES_SAMPLER` | `always_on` | **앱은 100% 전송, Collector에서 tail_sampling** |
| `OTEL_LOGS_EXPORTER` | `otlp` | 로그도 OTLP로 전송 |
| `OTEL_METRICS_EXPORTER` | `otlp` | 메트릭도 OTLP로 전송 |
| `OTEL_RESOURCE_ATTRIBUTES` | `service.namespace=demo,...` | Grafana 필터링용 라벨 |

> **왜 앱에서 `always_on`인가?**: 앱 레벨에서 샘플링하면(head sampling) 에러 트레이스를 놓칠 수 있다.
> 앱은 모든 트레이스를 전송하고, OTel Collector의 `tail_sampling` 프로세서가 에러/지연 기준으로 보관 여부를 결정한다.
> 이 Lab에서는 error(100%), slow 2s+(100%), normal(10%) 정책이 이미 적용되어 있다.

#### A-3. 구조화 로깅 설정

Spring Boot의 로그 패턴에 `[trace_id,span_id]`를 포함시키면, Grafana Loki → Tempo 자동 점프가 가능하다.

```yaml
# application.yml
logging:
  pattern:
    console: "%d{yyyy-MM-dd HH:mm:ss} [%X{trace_id},%X{span_id}] %-5level %logger{36} - %msg%n"
```

이 패턴은 Grafana datasource에 설정된 `derivedFields` 정규식과 매칭된다:

```yaml
# values-grafana.yaml (이미 설정됨)
derivedFields:
  - datasourceUid: tempo
    matcherRegex: "\\[([a-f0-9]{32}),"
    name: TraceID
    url: "$${__value.raw}"
```

→ 로그에서 `[a]` 패턴의 32자리 hex trace_id를 추출하여 Tempo 링크를 자동 생성한다.

#### A-4. Spring Boot 자동 생성 메트릭

OTel Java Agent가 자동으로 생성하는 주요 메트릭:

| 카테고리 | 메트릭 | 설명 |
|---------|--------|------|
| JVM | `process_runtime_jvm_memory_usage` | Heap/Non-heap 사용량 |
| JVM | `process_runtime_jvm_gc_duration` | GC pause 시간 |
| HTTP | `http_server_request_duration_seconds` | HTTP 요청 처리 시간 (histogram) |
| DB | `db_client_connections_usage` | 커넥션 풀 사용량 |
| Kafka | `messaging_publish_duration` | 메시지 발행 지연 |

> **참고**: OTel Collector의 `transform/sanitize_labels`가 점 표기법(`service.name`) → 언더스코어(`service_name`)로 변환한다.
> `filter/otlp_metrics`에서 `jvm_compilation_*`, `jvm_info`, `tomcat_sessions_*`는 이미 필터링되어 Mimir에 저장되지 않는다.

---

### Part B: Grafana UI 심화 실습

#### B-1. Explore → Mimir: Spring Boot PromQL 실습

Grafana → 🧭 **Explore** → 데이터소스 **Mimir** 선택 → **Code** 모드 전환.

**쿼리 1: JVM Heap 메모리 사용률**

```promql
process_runtime_jvm_memory_usage{type="heap"}
  / process_runtime_jvm_memory_limit{type="heap"} * 100
```

- **Graph** 모드에서 시계열 추이 확인
- **Legend**: `{{pod}}` 포맷으로 Pod별 구분
- 80% 이상이면 JVM `-Xmx` 조정 또는 메모리 누수 의심

**쿼리 2: HTTP RPS by route**

```promql
sum(rate(http_server_request_duration_seconds_count[5m])) by (http_route)
```

- 어떤 API 엔드포인트에 트래픽이 집중되는지 확인
- **Legend**: `{{http_route}}`

**쿼리 3: HTTP P95 레이턴시**

```promql
histogram_quantile(0.95,
  sum(rate(http_server_request_duration_seconds_bucket[5m])) by (le, http_route)
)
```

- P95가 SLO(예: 500ms)를 초과하면 해당 route의 트레이스를 Tempo에서 확인
- **Graph** 모드 → 시간 범위를 `Last 1 hour`로 설정하여 추이 관찰

**쿼리 4: HTTP 에러율 5xx**

```promql
sum(rate(http_server_request_duration_seconds_count{http_status_code=~"5.."}[5m]))
  / sum(rate(http_server_request_duration_seconds_count[5m])) * 100
```

- 에러율 1% 이상 시 Loki에서 에러 로그 확인 필요
- **Table** 모드로 현재 에러율 수치 확인

**쿼리 5: GC Pause 시간**

```promql
rate(process_runtime_jvm_gc_duration_sum[5m])
```

- GC pause가 급증하면 Old Generation 메모리 부족 → Heap 덤프 분석 필요

#### B-2. Explore → Loki: 구조화 로그 검색

**Builder 모드** (초보자 친화):
1. Explore → **Loki** 선택 → **Builder** 탭
2. Label filters에서 `namespace` = `demo`, `container` = `spring-app` 선택
3. 라벨 값 옆 🔍 돋보기 아이콘 클릭 → 사용 가능한 값 자동 완성
4. **Line contains**: `ERROR` 입력 → 에러 로그만 필터링

**Code 모드** (고급 사용자):

```logql
# 에러 로그 검색
{namespace="demo"} |= "ERROR"

# JSON 파서 + 레벨 필터
{namespace="demo"} | json | level="ERROR"

# 특정 trace_id의 모든 로그
{namespace="demo"} |= "abc123def456"
```

**trace_id → Tempo 점프**:
1. 로그 라인을 펼치면 `TraceID` 링크가 표시됨 (`derivedFields` 설정 동작)
2. 클릭하면 Tempo에서 해당 트레이스의 전체 Span 트리가 열림

**Live tail**:
1. 우측 상단 **Live** 버튼 클릭 → 실시간 로그 스트리밍
2. 로그 볼륨 히스토그램: 상단 바 차트에서 시간대별 로그 빈도 확인

#### B-3. Explore → Tempo: 분산 트레이스 + TraceQL

**Search 탭**:
1. Explore → **Tempo** 선택 → **Search** 탭
2. **Service Name**: 서비스 선택 → **Span Name**: 오퍼레이션 필터링
3. **Duration**: `> 500ms` → 느린 요청만 필터
4. **Status**: `Error` → 에러 트레이스만 필터
5. **Tags**: `http.method = POST` 등 커스텀 태그 필터

**Span 트리 읽는 법**:
- 트레이스 클릭 → 상세 Span 트리 열림
- 각 Span의 **가로 바 길이** = 소요 시간 (긴 Span이 병목)
- **부모-자식 계층**: 호출 체인을 들여쓰기로 시각화
- Span 클릭 → **Tags** 탭 (HTTP status, method, URL) / **Logs** 탭 (Span 내 이벤트)

**TraceQL 쿼리** (Tempo 2.0+):

```traceql
# 500ms 이상 + 5xx 에러 트레이스
{ duration > 500ms && span.http.status_code >= 500 }

# DB 쿼리가 포함된 트레이스
{ span.db.system = "postgresql" }

# 특정 서비스의 느린 요청
{ resource.service.name = "spring-app" && duration > 1s }
```

**Service Map**:
1. Explore → Tempo → 상단 **Service Graph** 탭
2. 노드 **색상**: 에러율 (빨간색 = 에러 많음)
3. 노드 **크기**: 요청 빈도 (큰 노드 = 트래픽 많음)
4. **화살표**: 서비스 간 의존성과 호출 방향

> **참고**: Service Map 데이터는 Tempo의 `metricsGenerator`가 생성하는 `traces_spanmetrics_*` 메트릭을 기반으로 한다.
> Mimir로 remote_write되어 Grafana에서 시각화된다.

#### B-4. 장애 대응 시나리오: 메트릭 → 로그 → 트레이스 → 서비스 맵

"응답 시간 급증" 시나리오를 4단계로 추적하는 연습:

**1단계 — Mimir에서 이상 감지**:
- Explore → Mimir → `histogram_quantile(0.95, sum(rate(http_server_request_duration_seconds_bucket[5m])) by (le))` 실행
- 그래프에서 P95 스파이크 발견 → 해당 시간대를 **드래그**하여 시간 범위 선택

**2단계 — Loki에서 에러 패턴 확인**:
- 데이터소스를 **Loki**로 전환 (시간 범위 자동 유지)
- `{namespace="demo"} |= "timeout"` 검색 → timeout 에러 패턴 확인
- `{namespace="demo"} | json | level="ERROR"` → 구조화된 에러 로그 필터링

**3단계 — Tempo에서 병목 식별**:
- 에러 로그의 **TraceID** 클릭 → Tempo Span 트리 자동 열림
- Span 트리에서 가장 긴 Span 확인 → DB 쿼리 3초 소요 발견
- Tags 탭에서 `db.statement` 확인 → 문제 쿼리 식별

**4단계 — Service Map에서 영향도 파악**:
- Tempo → Service Graph → 빨간색 노드(에러율 높은 서비스) 확인
- 화살표를 따라 영향받는 downstream 서비스 파악
- 장애 범위와 영향도를 한눈에 시각화

#### B-5. Spring Boot 대시보드 만들기

Dashboards → **New** → **New Dashboard** → **Add visualization**:

| 패널 | 타입 | PromQL |
|------|------|--------|
| HTTP RPS | Time series | `sum(rate(http_server_request_duration_seconds_count[5m])) by (http_route)` |
| P95 Latency | Time series + threshold(500ms) | `histogram_quantile(0.95, sum(rate(http_server_request_duration_seconds_bucket[5m])) by (le))` |
| JVM Heap | Gauge | `process_runtime_jvm_memory_usage{type="heap"} / process_runtime_jvm_memory_limit{type="heap"} * 100` |
| Error Rate | Stat | `sum(rate(http_server_request_duration_seconds_count{http_status_code=~"5.."}[5m])) / sum(rate(http_server_request_duration_seconds_count[5m])) * 100` |

각 패널 설정:
1. **Data source**: Mimir 선택
2. **Query**: 위 PromQL 입력 → **Code** 모드
3. **Panel options** → Title 입력
4. P95 Latency 패널: **Thresholds** → Add threshold → 500ms (orange), 1s (red)
5. **Save dashboard** → 이름 입력 → Save

---

### Part C: Node Exporter vs Alloy 호스트 메트릭 수집

#### 배경 지식

Grafana Alloy의 `prometheus.exporter.unix` 컴포넌트는 Node Exporter를 내장하고 있어 **기능적으로 100% 대체 가능**하다.
하지만 환경에 따라 최적의 구성이 달라진다.

#### 비교 테이블

| 항목 | Node Exporter (독립) | Alloy (`prometheus.exporter.unix`) |
|------|------|------|
| 배포 크기 | 단일 바이너리 ~7MB | Alloy 전체 바이너리 ~150MB |
| 설정 | 플래그만 (거의 제로 설정) | `config.alloy` 필수 |
| 권한 | 최소 (읽기 전용 `/proc`, `/sys` 마운트) | 호스트 메트릭 시 동일 마운트 + 추가 권한 |
| 관리 포인트 | 별도 프로세스 관리 | **통합** (로그+메트릭 한 에이전트) |
| 메트릭 이름 | `node_*` (업계 표준) | `node_*` (동일) |
| 커뮤니티 대시보드 | Node Exporter Full (ID: 1860) 등 풍부 | 동일 메트릭이므로 그대로 사용 가능 |

#### 환경별 권장 패턴

| 환경 | 권장 | 이유 |
|------|------|------|
| **Kubernetes** | Node Exporter DaemonSet + Alloy DaemonSet **분리** | Grafana Labs 공식 권장. 관심사 분리, Node Exporter가 경량, 높은 권한 불필요 |
| **Docker Compose/VM (소규모)** | Alloy 단독 (`prometheus.exporter.unix`) | 관리 포인트 1개로 감소. 로그+메트릭 통합 수집 |
| **Docker Compose/VM (대규모)** | Node Exporter + Alloy **분리** | Ansible로 Node Exporter 일괄 배포, Alloy는 scraper 역할. 장애 격리 용이 |

#### 왜 분리가 권장되는가?

**관심사 분리 (Separation of Concerns)**:
- Node Exporter = **메트릭 생산자** (호스트의 CPU, 메모리, 디스크, 네트워크 메트릭을 `/metrics` 엔드포인트로 노출)
- Alloy = **메트릭 수집/전송자** (Node Exporter의 `/metrics`를 scrape → remote_write로 Mimir에 전송)
- 한 컴포넌트에 장애가 발생해도 다른 컴포넌트에 영향 없음

**Kubernetes 환경에서**:
- Node Exporter DaemonSet: `hostPID: true`, `/proc`와 `/sys` 읽기 전용 마운트만 필요
- Alloy DaemonSet: 로그 수집(`/var/log`), 메트릭 scrape, OTLP 수신 등 다양한 역할
- 두 DaemonSet의 리소스와 권한을 독립적으로 관리 가능

#### 핵심 포인트

> **이 Lab의 구성**: Alloy DaemonSet이 kubelet/cAdvisor 메트릭을 직접 scrape하고 있다.
> Node Exporter는 별도로 배포하지 않았는데, Kind 환경에서는 호스트 메트릭이 필수적이지 않기 때문이다.
> 프로덕션에서는 Node Exporter DaemonSet을 추가하여 호스트 레벨 메트릭(디스크 I/O, 네트워크 인터페이스별 트래픽 등)을 수집하는 것이 권장된다.

**참고 자료**:
- [Grafana Alloy: prometheus.exporter.unix](https://grafana.com/docs/alloy/latest/reference/components/prometheus/prometheus.exporter.unix/)
- [Grafana k8s-monitoring-helm Issue #659](https://github.com/grafana/k8s-monitoring-helm/issues/659) — 관심사 분리 권장
- [SUSE: Grafana Alloy로 Node Exporter 대체](https://www.suse.com/c/grafana-alloy-part-2-replacing-prometheus-node-exporter/) — 단일 도구 운영 효율성
