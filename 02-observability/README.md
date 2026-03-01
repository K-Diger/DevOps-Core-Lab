# 02. Observability (LGTM Stack) — 기술 심화 가이드

> **대상**: 1년차 DevOps (스마일게이트, 1인 DevOps) → 3년차급 대기업 이직
> **인프라 규모**: 서버 77대 (DEV/STG/LIVE), Dynatrace → LGTM 전환 (연 1.7억 절감)
> **리뷰어 관점**: 11년차 DevOps 팀 리드 + 6명 팀원 (인프라/SRE/보안/플랫폼/CI·CD/EM)

---

## 1. 아키텍처 Overview

### LGTM 스택 전체 구조

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Application Layer                            │
│  Spring Boot Apps (micrometer-registry-otlp)                        │
│  → OTLP push (30s interval) → gRPC:4317 / HTTP:4318                │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│               OTel Collector Gateway (775라인)                       │
│                                                                     │
│  [Pipeline 1: OTLP]          │  [Pipeline 2: Prometheus]            │
│  receivers: otlp             │  receivers: prometheus (12 jobs)     │
│  processors: resourcedetect  │  processors: memory_limiter, batch   │
│  exporters: otlphttp         │  exporters: prometheusremotewrite    │
│    → Mimir (metrics)         │    → Mimir (metrics)                 │
│    → Tempo (traces)          │                                      │
│    → Loki  (logs)            │                                      │
└──────────────────────────────┴──────────────────────────────────────┘
                               │
              ┌────────────────┼────────────────┐
              ▼                ▼                ▼
┌──────────────────┐ ┌─────────────────┐ ┌──────────────────┐
│   Grafana Mimir  │ │  Grafana Tempo   │ │  Grafana Loki    │
│   (Metrics)      │ │  (Traces)        │ │  (Logs)          │
│   Monolithic     │ │                  │ │                  │
│   1.5M series    │ │                  │ │                  │
└────────┬─────────┘ └────────┬─────────┘ └────────┬─────────┘
         │                    │                     │
         └────────────────────┼─────────────────────┘
                              ▼
                 ┌─────────────────────┐
                 │     Grafana         │
                 │  4 Datasources      │
                 │  Cross-link 연결     │
                 │  Exemplars 활성화    │
                 └─────────┬───────────┘
                           ▼
                 ┌─────────────────────┐
                 │   AlertManager      │
                 │   (541라인)          │
                 │   6 inhibition      │
                 │   7 receivers       │
                 └─────────────────────┘
```

### 시그널별 데이터 흐름

| 시그널               | 소스                       | 수집 방식                       | 저장소   | 비고                      |
|-------------------|--------------------------|-----------------------------|-------|-------------------------|
| **Metrics (앱)**   | Spring Boot (micrometer) | OTLP push → 4317/4318       | Mimir | scrape → push 마이그레이션 완료 |
| **Metrics (인프라)** | Node Exporter, JMX 등     | Prometheus scrape (12 jobs) | Mimir | relabel로 IP→호스트명 변환     |
| **Traces**        | OTel SDK (Java Agent)    | OTLP push → 4317            | Tempo | Exemplar로 메트릭 연결        |
| **Logs**          | Promtail (앱 서버)          | push → Loki                 | Loki  | TraceID 파싱으로 트레이스 연결    |

---

## 2. 핵심 설정 해설

### 2.1 OTel Collector Gateway — 듀얼 파이프라인

**왜 OTLP/Prometheus 파이프라인을 분리하는가?**

두 파이프라인은 근본적으로 다른 데이터 모델과 라이프사이클을 가진다.

| 구분         | OTLP Pipeline                       | Prometheus Pipeline             |
|------------|-------------------------------------|---------------------------------|
| **수집 모델**  | Push (앱 → Collector)                | Pull (Collector → target)       |
| **데이터 포맷** | OTLP protobuf (metrics/traces/logs) | Prometheus exposition format    |
| **프로세서**   | resourcedetection (호스트/환경 메타데이터)    | memory_limiter → batch (OOM 방지) |
| **대상**     | 앱 메트릭 + 트레이스 + 로그                   | 인프라 메트릭 (Node Exporter, JMX 등)  |
| **장애 격리**  | 앱 장애 시 인프라 모니터링 유지                  | 인프라 장애 시 앱 모니터링 유지              |

**분리하지 않으면 발생하는 문제:**

1. **장애 전파**: Prometheus scrape의 memory_limiter가 OOM 직전 동작하면 OTLP 데이터까지 드롭
2. **프로세서 충돌**: OTLP의 resourcedetection 프로세서가 Prometheus 메트릭에 불필요한 리소스 속성을 추가하여 카디널리티 폭발
3. **배치 전략 불일치**: 인프라 메트릭(15s scrape)과 앱 메트릭(30s push)의 최적 배치 크기/타이밍이 다름
4. **디버깅 난이도**: 단일 파이프라인에서 문제 발생 시 앱/인프라 어느 쪽 이슈인지 분리 불가

**Scrape Jobs 12개 구성:**

```
kafka-broker, kafka-connect-source, kafka-connect-sink,
redis-cluster, node-app-servers(19대), node-infra-servers(13대),
loki, tempo, grafana, alertmanager, mimir, otel-collector,
harbor, kong-gateway, jenkins, alloy-faro
```

**relabel_configs (IP → 호스트명 변환):**

```yaml
relabel_configs:
  - source_labels: [ __address__ ]
    regex: '10\.0\.1\.10:.*'
    target_label: instance
    replacement: 'app-server-01'
```

왜 필요한가: 기존 Dynatrace 시절 alerts.yml과 대시보드 PromQL이 호스트명 기반(`instance="app-server-01"`)으로 작성되어 있음. IP 기반으로 변경하면 수백 개 PromQL
전부 수정 필요. relabel로 호환성 유지하면서 마이그레이션 비용을 제거했다.

---

### 2.2 앱 메트릭 마이그레이션 (Prometheus scrape → OTLP push)

**전환 과정:**

```
[Before] OTel Collector → scrape → /actuator/prometheus (8개 앱 jobs)
[After]  Spring Boot (micrometer-registry-otlp) → OTLP push → OTel Collector:4317
```

**마이그레이션 단계:**

1. `micrometer-registry-otlp` 의존성 추가 (Spring Boot 3.x)
2. `management.otlp.metrics.export.url=http://otel-collector:4318/v1/metrics` 설정
3. push 간격 30s로 설정 (`management.otlp.metrics.export.step=30s`)
4. OTLP push 데이터 정상 수신 확인 후 기존 scrape job 제거
5. `/actuator/prometheus` 엔드포인트 비활성화

**왜 Push로 전환했는가:**

| 관점        | Scrape (Pull)                     | OTLP Push                  |
|-----------|-----------------------------------|----------------------------|
| **네트워크**  | Collector → 앱 방화벽 오픈 필요 (N개)      | 앱 → Collector 단일 엔드포인트     |
| **디스커버리** | target 목록 수동 관리 (앱 서버 추가 시 설정 변경) | 앱이 자동 등록 (설정만 있으면 push)    |
| **멀티시그널** | 메트릭만 가능                           | 메트릭+트레이스+로그 단일 프로토콜        |
| **방화벽**   | 앱 서버마다 9090 포트 인바운드 허용            | Collector의 4317/4318만 인바운드 |
| **오너십**   | 인프라팀이 scrape 관리                   | 앱팀이 메트릭 export 직접 관리       |

**Push 전환의 단점과 보완:**

- **단점**: 앱이 죽으면 메트릭이 안 옴 → "메트릭 없음" 자체를 알림으로 감지 (`absent()` 함수)
- **단점**: Push storm (재시작 시 burst) → Mimir `ingestion_burst_size: 500000`으로 대비
- **단점**: 앱팀 의존성 증가 → micrometer 설정 템플릿 + Ansible 자동화로 DX 확보

---

### 2.3 Mimir — 메트릭 장기 저장

**Monolithic 모드 선택 이유:**

Mimir는 3가지 배포 모드를 제공한다: Monolithic, Read-Write, Microservices.

| 모드             | 적합 규모             | 복잡도 | 선택 이유                     |
|----------------|-------------------|-----|---------------------------|
| **Monolithic** | ~1M active series | 낮음  | 현재 규모 (77대, ~1.5M series) |
| Read-Write     | 1M~10M series     | 중간  | 향후 확장 시 고려                |
| Microservices  | 10M+ series       | 높음  | 대기업급 (수천 대)               |

77대 서버에서 Microservices 모드를 택하면 운영 복잡도만 올라가고 이점이 없다. 1인 DevOps 환경에서 Monolithic이 운영 효율 최적이다. Grafana 공식 문서도 초기에는
Monolithic 권장.

**Limits 튜닝 상세:**

```yaml
limits:
  ingestion_rate: 50000           # 기본 10,000 → 5배
  ingestion_burst_size: 500000    # 기본 200,000 → 2.5배
  max_global_series_per_user: 1500000    # 기본 150,000 → 10배
  max_global_series_per_metric: 100000   # 기본 20,000 → 5배
  max_fetched_series_per_query: 200000   # 기본 100,000 → 2배
  out_of_order_time_window: 15m          # 기본 0 → 15분
```

**각 설정의 WHY:**

| 설정                             | 기본값     | 설정값       | 왜 올렸는가                                                                                                         |
|--------------------------------|---------|-----------|----------------------------------------------------------------------------------------------------------------|
| `ingestion_rate`               | 10,000  | 50,000    | 19대 앱 서버 + 12 scrape jobs의 동시 ingest. 기본값이면 429 에러 다발                                                          |
| `ingestion_burst_size`         | 200,000 | 500,000   | Spring Boot 재시작 시 micrometer가 버퍼링된 메트릭을 한번에 flush. 기본값이면 burst 시 드롭                                            |
| `max_global_series_per_user`   | 150,000 | 1,500,000 | Histogram 메트릭 (http_server_requests)의 le 버킷 × method × uri × status 조합 카디널리티. 기본값이면 series limit 도달로 신규 메트릭 거부 |
| `max_global_series_per_metric` | 20,000  | 100,000   | 단일 histogram 메트릭이 수만 series 생성. 기본값이면 주요 메트릭이 잘림                                                               |
| `max_fetched_series_per_query` | 100,000 | 200,000   | 전체 서버 대시보드 PromQL 쿼리 시 series 수 초과. 기본값이면 대시보드 로딩 실패                                                           |
| `out_of_order_time_window`     | 0       | 15m       | OTel Collector의 batch processor + retry가 네트워크 지연 시 과거 타임스탬프 전송. 기본 0이면 해당 데이터 전부 reject                        |

**out_of_order_time_window 15m 설정의 깊은 이유:**

OTel Collector의 retry 메커니즘에서 비롯된다. 네트워크 일시 장애 → batch된 데이터가 retry queue에 쌓임 → 복구 후 한꺼번에 전송 → 이 데이터의 타임스탬프는 수 분 전. Mimir
기본 설정(0)은 out-of-order 샘플을 전부 reject하므로, 네트워크 복구 후에도 장애 기간 메트릭이 영구 손실된다. 15분은 OTel batch timeout(5m) + retry backoff(최대
5m) + 여유분(5m)으로 산정했다.

**Compactor 설정:**

```yaml
compactor:
  compaction_interval: 30m
  retention_period: 7d    # 시범운영 기간
```

7일 retention은 시범운영 기간이라 짧게 설정. 프로덕션 안정화 후 90일~1년으로 확장 계획. S3 backend 전환도 함께 진행 예정 (현재 filesystem).

---

### 2.4 Grafana 크로스링크 (Correlation)

**4개 Datasource의 Cross-link 구성:**

```
Prometheus(Mimir) ←→ Tempo: Exemplars
Loki ←→ Tempo: trace_id derived field
Tempo ←→ Loki: traceToLogs
Tempo ←→ Prometheus: traceToMetrics
```

**이것이 Observability "Correlation"의 핵심인 이유:**

3 Pillars (Metrics, Traces, Logs)를 각각 운영하면 "대시보드 3개를 따로 보는 것"에 불과하다. Correlation이 없으면:

1. 메트릭 알림 발생 → Grafana에서 Tempo로 이동 → 수동으로 시간대 필터링 → 트레이스 찾기 (5~10분)
2. 트레이스 → 로그 연결 불가 → 별도 Loki 쿼리 작성 (시간 + 서비스명 수동 입력)

Correlation이 있으면:

1. 메트릭 알림 → Exemplar 클릭 → 해당 시점의 정확한 트레이스로 1클릭 이동
2. 트레이스 → traceToLogs → 해당 트레이스의 로그 자동 필터링
3. MTTR(Mean Time To Resolve) 체감 50% 이상 단축

**Exemplar 동작 원리:**

```
[Spring Boot] → HTTP 요청 처리 → micrometer가 메트릭 기록 시 현재 trace_id를 exemplar로 첨부
→ {__name__="http_server_requests_seconds_count", trace_id="abc123"}
→ Mimir에 저장 → Grafana 그래프에서 점(dot) 클릭 → Tempo에서 trace abc123 조회
```

---

### 2.5 metric_relabel_configs — 저가치 메트릭 드롭

```yaml
metric_relabel_configs:
  - source_labels: [ __name__ ]
    regex: 'go_.*|promhttp_.*|process_.*'
    action: drop
```

**왜 드롭하는가:**

| 메트릭 패턴        | 내용                                   | 드롭 이유                                  |
|---------------|--------------------------------------|----------------------------------------|
| `go_.*`       | Go 런타임 메트릭 (goroutine, gc, memstats) | Exporter 자체의 Go 런타임 정보. 모니터링 대상 앱과 무관  |
| `promhttp_.*` | Prometheus HTTP handler 메트릭          | Exporter의 scrape 엔드포인트 자체 메트릭. 운영에 무의미 |
| `process_.*`  | Exporter 프로세스 메트릭 (CPU, memory, fd)  | Exporter 프로세스 자체 리소스. 모니터링 대상과 무관      |

**비용 절감 효과:**

- 서버당 약 200~300개 시리즈 드롭
- 77대 기준: 약 15,000~23,000개 불필요 시리즈 제거
- Mimir 스토리지, 쿼리 성능, ingestion rate 여유 확보
- `max_global_series_per_user: 1,500,000` 한도 내에서 유의미한 메트릭에 더 많은 공간 확보

**Anti-pattern 경고:** 처음부터 과도한 드롭은 위험하다. 실제로 `go_goroutines`는 OTel Collector 자체 모니터링에 유용할 수 있다. 우리는 2주간 "드롭 대상 메트릭이
대시보드/알림에 사용되는지" 검증 후 적용했다.

---

### 2.6 Dynatrace → LGTM 전환 의사결정

**의사결정 매트릭스:**

| 기준             | Dynatrace            | LGTM Stack                       | 판단           |
|----------------|----------------------|----------------------------------|--------------|
| **연간 비용**      | ~1.7억 (호스트 당 라이선스)   | 서버 리소스만 (수백만 원)                  | LGTM 압승      |
| **벤더 락인**      | Dynatrace 전용 쿼리/대시보드 | 오픈소스 표준 (PromQL, TraceQL, LogQL) | LGTM 우위      |
| **자동 계측**      | OneAgent 자동 (강점)     | OTel SDK/Agent 수동 설정 필요          | Dynatrace 우위 |
| **AI 근본원인 분석** | Davis AI (강점)        | 직접 알림 룰 설계 필요                    | Dynatrace 우위 |
| **커스텀 자유도**    | 제한적                  | 무제한 (OTel Collector 파이프라인)       | LGTM 압승      |
| **역량 성장**      | 벤더 제품 운영 스킬          | 오픈소스 생태계 깊은 이해                   | LGTM 우위      |

**전환 리스크 관리:**

1. **병행 운영 (2개월)**: Dynatrace + LGTM 동시 운영, 동일 메트릭/알림 비교 검증
2. **대시보드 매핑**: Dynatrace 대시보드를 Grafana로 1:1 마이그레이션 (PromQL 재작성)
3. **알림 검증**: 동일 시나리오에서 양쪽 알림 동시 발생 확인 후 Dynatrace 해제
4. **롤백 계획**: Dynatrace 에이전트 비활성화만 하고 삭제하지 않음 (1개월 유예)

---

## 3. 심화 Q&A — 팀 토론 결과

---

### [팀원1: 박준혁 - 인프라 엔지니어 (8년차)]

> 관점: 인프라 설계, 네트워크, 용량 계획

---

**Q1. Dynatrace에서 LGTM Stack으로 전환한 의사결정 과정을 설명해주세요.**

- **꼬리질문 1**: Dynatrace 대비 LGTM의 단점은 무엇이고, 이를 어떻게 보완했나요?
- **꼬리질문 2**: 전환 과정에서 모니터링 공백이 발생하지 않도록 어떤 전략을 사용했나요?
- **질문 의도**: 비용 vs 기능 트레이드오프 판단력, 전환 리스크 관리 능력, 1인 DevOps로서의 의사결정 근거
- **모범 답변 키포인트**:
    1. 연 1.7억 절감 (Dynatrace 호스트 기반 라이선스 vs LGTM 인프라 비용만) — 경영진에게 ROI 수치로 제안
    2. 병행 운영 2개월 → 대시보드/알림 1:1 매핑 검증 → Dynatrace 에이전트 비활성화 (삭제 아닌 비활성화로 롤백 가능)
    3. LGTM 단점(자동 계측 없음, AI 분석 없음)은 OTel SDK 수동 계측 + AlertManager inhibition rules 6개로 보완

---

**Q2. OTel Collector를 단일 인스턴스(Gateway 패턴)로 운영하는데, SPOF(단일 장애점) 리스크는 어떻게 관리하나요?**

- **꼬리질문 1**: Collector가 죽으면 메트릭/트레이스/로그 모두 유실되는데, 어떤 완화책이 있나요?
- **꼬리질문 2**: 향후 트래픽이 늘어나면 Collector를 어떻게 스케일아웃 할 계획인가요?
- **질문 의도**: SPOF 인식 능력, 아키텍처 한계를 알고 있는지, 성장 계획
- **모범 답변 키포인트**:
    1. 현재 77대 규모에서 단일 Gateway의 리소스 사용률이 낮아 (CPU < 20%, Memory < 2GB) 이중화보다 운영 단순성을 택함
    2. 앱 측 OTel SDK는 자체 retry/buffering이 있어 Collector 일시 장애 시 데이터 유실 최소화 (retry backoff 최대 5분)
    3. 스케일아웃 계획: Load Balancer 뒤에 Collector 2대 + consistent hashing으로 target 분배 (Prometheus scrape의 경우 hashmod relabel)

---

**Q3. 서버 77대에 Node Exporter, Promtail, JMX Exporter를 어떻게 배포/관리하나요?**

- **꼬리질문 1**: Ansible playbook 606라인이면 상당한 규모인데, 멱등성은 어떻게 보장하나요?
- **꼬리질문 2**: 에이전트 버전 업그레이드는 어떤 절차로 진행하나요?
- **질문 의도**: 대규모 에이전트 관리 능력, IaC 수준
- **모범 답변 키포인트**:
    1. Ansible `deploy-observability-agents.yml` (606라인)로 Node Exporter + Promtail + JMX Exporter 일괄 배포. 호스트 그룹별 (
       DEV/STG/LIVE) 분리 실행
    2. `open-observability-firewall.yml` (864라인)로 17개 호스트 그룹 방화벽 일괄 관리. 에이전트 포트(9100, 3100, 5556 등) 인바운드 허용
    3. 버전 업그레이드: Ansible variable로 버전 관리 → DEV 먼저 적용 → STG 검증 → LIVE 순차 롤아웃 (canary 아닌 환경별 순차)

---

**Q4. relabel_configs로 IP를 호스트명으로 변환하는데, 서버가 추가/제거될 때 유지보수 비용은?**

- **꼬리질문 1**: 동적 환경(Auto Scaling)에서는 이 방식이 어떤 한계가 있나요?
- **꼬리질문 2**: Consul이나 DNS 기반 서비스 디스커버리로 개선할 수 있지 않나요?
- **질문 의도**: 정적 설정의 한계 인식, 개선 방향 제시 능력
- **모범 답변 키포인트**:
    1. 현재 온프레미스 77대는 거의 정적이라 relabel 수동 관리 가능. 서버 추가 시 Ansible로 에이전트 배포 + OTel Collector 설정 업데이트를 함께 수행
    2. 한계 인정: Auto Scaling 환경이면 이 방식은 스케일 안 됨. file_sd_configs + 자동 생성 JSON 또는 Consul SD로 전환 필요
    3. Kubernetes 환경 전환 시 ServiceMonitor/PodMonitor + relabeling으로 자동 디스커버리 전환 계획

---

### [팀원2: 이서연 - SRE (9년차)]

> 관점: SLO/SLI, 가용성, 알림 설계, 장애 대응

---

**Q1. OTel Collector 듀얼 파이프라인 분리는 어떤 장애 시나리오에서 효과를 발휘하나요?**

- **꼬리질문 1**: 실제로 파이프라인 분리 덕분에 장애를 격리한 경험이 있나요?
- **꼬리질문 2**: 두 파이프라인 간 리소스 경합은 어떻게 관리하나요?
- **질문 의도**: 이론이 아닌 실전 경험, 리소스 관리 능력
- **모범 답변 키포인트**:
    1. 장애 격리: 앱 서버 대량 재시작 시 OTLP push burst가 발생해도 Prometheus scrape 파이프라인은 독립적으로 인프라 메트릭 수집 지속. 인프라 모니터링 공백 제로
    2. 리소스 경합: Prometheus 파이프라인에 `memory_limiter` 프로세서 적용 (limit_mib, spike_limit_mib). OTLP 파이프라인은 별도 메모리 풀. Collector
       전체 메모리는 4GB 할당
    3. 분리의 부수 효과: 파이프라인별 독립 헬스체크 가능. 한쪽 파이프라인 장애 시 알림 발생하면서도 다른 쪽은 정상 동작

---

**Q2. Mimir ingestion_rate을 50,000으로 올렸는데, 이 수치는 어떻게 산정했나요?**

- **꼬리질문 1**: ingestion_rate 초과 시 어떤 증상이 나타나나요?
- **꼬리질문 2**: rate를 너무 높게 잡으면 어떤 부작용이 있나요?
- **질문 의도**: 수치의 근거를 설명할 수 있는지, 모니터링 시스템 자체를 모니터링하는 능력
- **모범 답변 키포인트**:
    1. 산정 근거: 앱 서버 19대 × 평균 500 series × 30s push + 인프라 12 scrape jobs × 15s interval. 정상 시 약 25,000~30,000 samples/s →
       피크(재시작 burst) 시 2배 가정 → 50,000
    2. 초과 증상: Mimir가 HTTP 429 (Too Many Requests) 반환 → OTel Collector retry queue 적재 → 결국 OTel Collector 메모리 증가 → OOM 가능
    3. 과도한 rate 설정의 부작용: Mimir가 실제 이상 트래픽(카디널리티 폭발)도 수용해버려 스토리지 폭발 감지 지연. 적정 rate + 알림이 더 안전

---

**Q3. out_of_order_time_window 15분은 어떤 시나리오를 기반으로 설정했나요?**

- **꼬리질문 1**: 이 값을 0으로 두면 어떤 일이 벌어지나요?
- **꼬리질문 2**: 15분이 아니라 30분이나 1시간으로 늘리면 안 되나요?
- **질문 의도**: OTel→Mimir 데이터 흐름의 타이밍 이해, 트레이드오프 인식
- **모범 답변 키포인트**:
    1. 시나리오: OTel Collector batch timeout 5분 + 네트워크 장애 시 retry backoff 최대 5분 + 안전 마진 5분 = 15분. 실제 네트워크 장애 복구 후 과거 타임스탬프
       데이터가 정상 수집됨을 확인
    2. 0이면: 네트워크 복구 후 전송되는 "과거 데이터"가 전부 reject → 장애 기간 메트릭 영구 손실 → 장애 분석 불가
    3. 30분~1시간: 가능하지만 Mimir ingester 메모리 사용량 증가 (out-of-order 처리를 위한 in-memory 버퍼 확대). 15분이면 실측 기반 충분하고 메모리 오버헤드 최소

---

**Q4. AlertManager의 6개 inhibition rules는 어떤 원칙으로 설계했나요?**

- **꼬리질문 1**: 알림 폭풍(alert storm) 상황에서 inhibition이 어떻게 동작하나요?
- **꼬리질문 2**: severity 기반 routing은 어떤 구조인가요?
- **질문 의도**: 알림 시스템 설계 역량, 알림 피로도 관리
- **모범 답변 키포인트**:
    1. 설계 원칙: "상위 장애가 하위 장애를 억제" — 노드 다운 시 해당 노드의 모든 서비스 알림 억제, 네트워크 장애 시 해당 네트워크의 연결 실패 알림 억제
    2. 알림 폭풍 시: 서버 1대 다운 → node_down (critical) 발생 → 해당 서버의 process_down, disk_full, cpu_high 등 10여 개 알림이 inhibit되어
       운영자에게 1개만 전달
    3. Severity routing: critical → Slack + 이메일 에스컬레이션 (5분 미확인 시 팀장), warning → Slack only, info → Grafana 대시보드만. 7개
       receiver로 분기

---

**Q5. Observability correlation(메트릭→트레이스→로그) 구현 후 실제 장애 대응에서 어떤 차이가 있었나요?**

- **꼬리질문 1**: Exemplar가 없었다면 같은 장애를 어떻게 분석했을까요?
- **꼬리질문 2**: correlation 설정에서 가장 까다로웠던 부분은 무엇인가요?
- **질문 의도**: Observability의 본질(시그널 간 연결) 이해, 실전 경험
- **모범 답변 키포인트**:
    1. Before: 메트릭 알림 → Loki에서 시간대 + 서비스명으로 수동 검색 → 로그에서 에러 찾기 → 트레이스 ID 복사 → Tempo에서 검색 (평균 15~20분)
    2. After: 메트릭 그래프의 Exemplar 점 클릭 → Tempo 트레이스 → traceToLogs로 Loki 자동 필터링 (평균 3~5분). MTTR 체감 70% 단축
    3. 까다로운 부분: Loki의 derived field 설정. 로그 포맷이 앱마다 달라 trace_id 추출 정규식을 앱별로 맞춰야 했음. JSON 로그 표준화 후 해결

---

### [팀원3: 최민수 - 보안 엔지니어 (7년차)]

> 관점: 데이터 보안, 접근 제어, 컴플라이언스

---

**Q1. LGTM 스택에서 수집하는 로그/트레이스에 민감정보(PII)가 포함될 수 있는데, 어떻게 처리하나요?**

- **꼬리질문 1**: OTel Collector 레벨에서 PII 마스킹을 적용할 수 있나요?
- **꼬리질문 2**: 로그에 신용카드 번호나 주민번호가 포함된 것을 사후에 발견하면 어떻게 대응하나요?
- **질문 의도**: 보안 관점의 Observability 인식, 규제 대응 능력
- **모범 답변 키포인트**:
    1. OTel Collector의 `attributes` 프로세서 또는 `transform` 프로세서로 정규식 기반 PII 마스킹 가능 (카드번호, 주민번호 패턴). 현재는 앱 레벨에서 로그 출력 시
       마스킹하는 것이 1차 방어선
    2. Loki retention policy로 일정 기간 후 자동 삭제. Compactor의 deletion API로 특정 로그 라인 삭제 가능 (단, 인덱스에서 완전 제거까지 시간 소요)
    3. 예방 조치: 앱 로깅 가이드라인 배포 (민감 필드는 반드시 마스킹 후 출력), 정기적으로 로그 샘플링 검사

---

**Q2. Grafana/Mimir/Loki/Tempo에 대한 접근 제어는 어떻게 구성되어 있나요?**

- **꼬리질문 1**: Grafana RBAC으로 팀별 대시보드 접근을 분리하고 있나요?
- **꼬리질문 2**: Mimir/Loki의 데이터소스에 직접 접근하는 것을 어떻게 막나요?
- **질문 의도**: 모니터링 시스템 자체의 보안 수준
- **모범 답변 키포인트**:
    1. Grafana: Organization + Team 기반 RBAC. 개발팀은 자기 서비스 대시보드만 조회, 인프라팀은 전체 접근. Admin 역할은 DevOps팀만
    2. Mimir/Loki/Tempo: 내부 네트워크에서만 접근 가능 (방화벽). Grafana만 프록시 역할로 외부 노출. 직접 쿼리 API 접근은 IP 화이트리스트
    3. 싱글 테넌트 모드이므로 테넌트 간 데이터 격리는 불필요. 멀티 테넌트 전환 시 X-Scope-OrgID 헤더 기반 격리 필요

---

**Q3. 방화벽 설정 864라인(17개 호스트 그룹)의 관리 전략은?**

- **꼬리질문 1**: 불필요한 포트가 열려있는지 정기적으로 감사하나요?
- **꼬리질문 2**: 방화벽 규칙 변경의 승인 프로세스는 어떻게 되나요?
- **질문 의도**: 네트워크 보안 관리의 성숙도
- **모범 답변 키포인트**:
    1. Ansible `open-observability-firewall.yml`로 방화벽 규칙을 코드로 관리 (IaC). Git PR 리뷰 필수로 변경 이력 추적
    2. 최소 권한 원칙: Observability 에이전트 포트(9100, 3100, 5556)만 필요한 호스트 그룹에 인바운드 허용. 전체 개방 아닌 호스트 그룹 단위 세분화
    3. 감사: 분기별 방화벽 규칙 리뷰. 사용하지 않는 규칙 정리 (decommissioned 서버의 규칙 등). Ansible dry-run으로 현재 상태와 코드 차이 확인

---

### [팀원4: 김하준 - 플랫폼 엔지니어 (6년차)]

> 관점: Developer Experience (DX), Self-service, 대시보드/알림 플랫폼

---

**Q1. 개발팀이 직접 대시보드를 만들고 알림을 설정할 수 있는 self-service 환경을 제공하나요?**

- **꼬리질문 1**: 개발자가 잘못된 PromQL로 Mimir에 부하를 주는 것은 어떻게 방지하나요?
- **꼬리질문 2**: 대시보드/알림 설정의 표준 템플릿을 제공하나요?
- **질문 의도**: 플랫폼 엔지니어링 사고방식, 내부 고객(개발팀) 지원 수준
- **모범 답변 키포인트**:
    1. Grafana에서 팀별 폴더 분리, Editor 역할 부여로 자체 대시보드 생성 가능. 알림은 Grafana Alerting(Unified Alerting) 활용
    2. PromQL 부하 방지: Mimir의 `max_fetched_series_per_query: 200,000` + `query_timeout` 설정으로 무거운 쿼리 자동 종료. 추가로 Grafana에서
       query inspector로 series 수 사전 확인 가이드
    3. 표준 템플릿: Spring Boot 앱용 대시보드 템플릿 (RED metrics: Rate/Error/Duration), Kafka Consumer Lag 대시보드, 인프라 노드 대시보드를 사전 제공

---

**Q2. micrometer-registry-otlp 전환 시 앱 개발팀의 반발이나 어려움은 없었나요?**

- **꼬리질문 1**: 개발팀이 변경해야 할 부분은 구체적으로 무엇이었나요?
- **꼬리질문 2**: 마이그레이션 가이드를 어떻게 제공했나요?
- **질문 의도**: 기술 변경의 조직적 측면, 커뮤니케이션 능력
- **모범 답변 키포인트**:
    1. 앱 코드 변경 최소화: `build.gradle`에 의존성 1줄 추가 + `application.yml`에 OTLP endpoint 설정 3줄. 기존 커스텀 메트릭 코드 변경 불필요 (micrometer
       추상화 레이어 덕분)
    2. Confluence에 마이그레이션 가이드 문서 작성 + Slack 채널에서 실시간 지원. DEV 환경에서 먼저 적용하여 성공 사례 공유
    3. `/actuator/prometheus` 엔드포인트 제거로 앱 서버의 불필요한 HTTP 엔드포인트 노출 감소 → 보안팀도 긍정적 반응

---

**Q3. Grafana 대시보드의 provisioning은 어떻게 관리하나요?**

- **꼬리질문 1**: 대시보드 JSON을 Git으로 관리하나요, Grafana UI에서 직접 수정하나요?
- **꼬리질문 2**: 대시보드 버전 관리와 롤백은 어떻게 하나요?
- **질문 의도**: Grafana 운영 성숙도, GitOps 적용 수준
- **모범 답변 키포인트**:
    1. 핵심 대시보드 (인프라, SLO)는 Grafana provisioning(YAML + JSON)으로 Git 관리 → 배포 시 자동 적용. 팀별 커스텀 대시보드는 UI에서 자유롭게 수정
    2. Grafana 내장 버전 히스토리로 대시보드 변경 이력 추적. 실수로 깨진 경우 이전 버전으로 1클릭 복원
    3. 향후 Grafana Terraform Provider로 대시보드/데이터소스/알림을 완전 IaC화 계획

---

**Q4. Observability 도입 후 개발팀의 장애 대응 문화가 어떻게 변했나요?**

- **꼬리질문 1**: 개발팀이 직접 로그/트레이스를 조회하나요, 아니면 DevOps팀에 요청하나요?
- **꼬리질문 2**: On-call 체계에 Observability가 어떻게 통합되어 있나요?
- **질문 의도**: 도구 도입 너머의 문화적 변화, 조직 임팩트
- **모범 답변 키포인트**:
    1. Before: 장애 발생 → 개발팀 "로그 좀 봐주세요" 요청 → DevOps가 서버 접속해서 로그 전달 (평균 30분). After: 개발팀이 Grafana에서 직접 로그/트레이스 조회 (즉시)
    2. Grafana 알림 → Slack 채널 → 담당 개발팀이 직접 초기 대응. DevOps는 인프라 레벨 이슈만 개입. 장애 대응 오너십이 앱팀으로 이동
    3. 주간 장애 리뷰 미팅에서 Grafana 대시보드를 함께 보며 분석. Observability가 "공통 언어"가 됨

---

### [팀원5: 정유진 - CI/CD 엔지니어 (5년차)]

> 관점: 배포 자동화, 에이전트 배포, 파이프라인 통합

---

**Q1. Observability 에이전트(Node Exporter, Promtail, JMX Exporter) 배포를 CI/CD와 어떻게 통합했나요?**

- **꼬리질문 1**: 에이전트 설정 변경 시 서비스 재시작 없이 적용 가능한가요?
- **꼬리질문 2**: 에이전트 배포 실패 시 롤백 절차는?
- **질문 의도**: 배포 자동화 수준, 에이전트 라이프사이클 관리
- **모범 답변 키포인트**:
    1. Ansible playbook `deploy-observability-agents.yml` (606라인)을 Jenkins pipeline에서 호출. 앱 배포 파이프라인과 별도로 Observability
       전용 파이프라인 운영
    2. Promtail은 설정 변경 시 SIGHUP으로 reload (재시작 불필요). Node Exporter는 대부분 설정 변경 없음 (collector flags만). JMX Exporter는 설정 파일
       변경 후 Java 앱 재시작 필요 (JMX Agent 특성)
    3. 롤백: Ansible의 이전 버전 바이너리/설정을 backup 디렉토리에 보관 → 실패 시 rollback task 실행. 단, 에이전트는 데이터 수집만 하므로 배포 실패가 서비스 장애로 이어지지 않음

---

**Q2. OTel Collector Gateway 설정 775라인을 어떻게 관리하고 배포하나요?**

- **꼬리질문 1**: 설정 변경의 검증은 어떻게 하나요? (문법 체크, dry-run 등)
- **꼬리질문 2**: Collector 설정 오류로 데이터 유실이 발생한 적 있나요?
- **질문 의도**: Critical 인프라 설정의 변경 관리 프로세스
- **모범 답변 키포인트**:
    1. Git 관리 + PR 리뷰. OTel Collector는 `--config` 파일을 Ansible로 배포. 변경 시 DEV → STG → LIVE 순차 적용
    2. 검증: `otelcol validate --config=config.yaml` 명령으로 문법 검증. DEV 환경에서 1시간 이상 안정성 확인 후 STG 적용
    3. 데이터 유실 사례: 초기 OTLP exporter의 endpoint 오타로 Mimir 연결 실패 → Collector 로그에서 `connection refused` 확인 → 5분 내 수정. 이후
       Collector 자체 메트릭(`otelcol_exporter_sent_metric_points`)을 모니터링하여 전송 실패 즉시 알림

---

**Q3. 앱 배포 시 Observability 관련 설정(micrometer, OTel endpoint)이 환경별로 다를 텐데, 어떻게 관리하나요?**

- **꼬리질문 1**: DEV/STG/LIVE 환경별 OTel Collector 엔드포인트가 다른가요?
- **꼬리질문 2**: 환경별 설정 차이로 인한 장애 경험이 있나요?
- **질문 의도**: 환경별 설정 관리, Configuration Drift 방지
- **모범 답변 키포인트**:
    1. Spring Boot `application-{profile}.yml`에서 환경별 OTel endpoint 분리. DEV: `otel-collector-dev:4318`, STG:
       `otel-collector-stg:4318`, LIVE: `otel-collector:4318`
    2. 환경별 Collector는 각각 독립 운영 (DEV/STG는 단일 Collector, LIVE는 전용 Collector). 메트릭이 섞이지 않도록 Mimir 테넌트 또는 label로 분리
    3. 교훈: STG에서 LIVE Collector endpoint를 잘못 설정 → STG 메트릭이 LIVE Mimir에 유입 → label 오염. 이후 endpoint 설정을 환경 변수로 관리하고 CI에서 값
       검증 추가

---

### [팀원6: 한소윤 - Engineering Manager (10년차)]

> 관점: 의사결정 프레임워크, ROI, 조직 협업, 커리어 성장

---

**Q1. 1인 DevOps로서 Dynatrace → LGTM 전환을 경영진에게 어떻게 설득했나요?**

- **꼬리질문 1**: 경영진이 "Dynatrace가 이미 잘 되고 있는데 왜 바꾸나?"라고 물으면?
- **꼬리질문 2**: 전환 실패 시 책임 문제는 어떻게 다뤘나요?
- **질문 의도**: 기술 의사결정의 비즈니스 커뮤니케이션 능력, 리스크 관리
- **모범 답변 키포인트**:
    1. ROI 중심 설득: "연 1.7억 비용 절감 + 벤더 독립성 확보 + 오픈소스 커스텀 자유도". 엔지니어링 관점이 아닌 비즈니스 관점으로 제안서 작성
    2. 리스크 완화 제시: 2개월 병행 운영 → 동일 수준 확인 후 전환 → Dynatrace 에이전트 비활성화(삭제 아님)로 30일 롤백 가능. "실패해도 원복 가능" 메시지
    3. 점진적 증명: DEV 환경에서 먼저 LGTM 구축 → 1개월 안정성 증명 → STG → LIVE 순차 확장. 각 단계에서 대시보드/알림 품질 비교 리포트 제출

---

**Q2. 1인 DevOps 체제에서 LGTM 스택 전체를 운영하는 것의 리스크는 무엇인가요?**

- **꼬리질문 1**: 본인이 퇴사하면 이 시스템을 누가 운영하나요?
- **꼬리질문 2**: 기술 부채를 어떻게 관리하고 있나요?
- **질문 의도**: 조직 리스크 인식, 지속 가능성 관점
- **모범 답변 키포인트**:
    1. Bus Factor 1 리스크 인정. 보완책: 모든 설정을 Git + Ansible로 IaC화 (코드만 보면 재구성 가능), Confluence에 운영 가이드/트러블슈팅 문서 상세 작성
    2. 기술 부채: Mimir Monolithic → 향후 Read-Write 모드 전환, filesystem → S3 스토리지 전환, Collector HA 구성 등을 기술 부채 백로그로 관리
    3. 팀 빌딩 제안: 분기별로 "Observability 스택 운영 현황 + 향후 투자 필요 영역" 리포트를 CTO에게 공유. 인원 충원의 근거 자료로 활용

---

**Q3. Observability 도입의 비즈니스 임팩트를 어떻게 측정하고 보고하나요?**

- **꼬리질문 1**: MTTR 개선을 정량적으로 측정한 데이터가 있나요?
- **꼬리질문 2**: 비용 절감 외에 개발 생산성 향상을 어떻게 증명했나요?
- **질문 의도**: 엔지니어링 성과의 비즈니스 번역 능력
- **모범 답변 키포인트**:
    1. 비용: Dynatrace 라이선스 연 1.7억 → LGTM 인프라 비용 수백만 원. 순 절감 약 1.5억+
    2. MTTR: 장애 접수 → 근본 원인 파악까지 평균 시간. Before(Dynatrace): 수동 로그 분석 15~20분 → After(LGTM + Correlation):
       Exemplar/traceToLogs로 3~5분. 약 70% 단축
    3. 개발 생산성: "로그 봐주세요" DevOps 요청 건수 80% 감소 (개발팀 직접 조회). DevOps팀(1인)의 시간을 인프라 개선에 재투자 가능

---

## 4. 심화 질문 — 예상 추가 질문

### 4.1 아키텍처 깊이 질문

| 질문                                | 핵심 답변 방향                                                                        |
|-----------------------------------|---------------------------------------------------------------------------------|
| "왜 Prometheus가 아니라 Mimir를 선택했나요?" | Prometheus는 장기 저장/HA가 없음. Mimir는 Prometheus 호환 + S3 장기 저장 + 수평 확장. 같은 PromQL 사용 |
| "Thanos 대신 Mimir를 선택한 이유는?"       | Thanos는 Sidecar 패턴(기존 Prometheus 필요), Mimir는 독립형. LGTM 통합 생태계(Grafana Labs) 시너지 |
| "Loki vs Elasticsearch 비교해주세요"    | Loki: 인덱스를 label만(저비용, 저용량). ES: 풀텍스트 인덱스(고비용, 강력한 검색). 77대 규모에서 Loki가 비용효율 압승  |
| "Tempo vs Jaeger 비교해주세요"          | Tempo: 인덱스리스(trace_id만으로 조회, 저비용). Jaeger: ES/Cassandra 필요(운영 부담). LGTM 생태계 통합  |

### 4.2 장애 시나리오 질문

| 질문                     | 핵심 답변 방향                                                                                                     |
|------------------------|--------------------------------------------------------------------------------------------------------------|
| "OTel Collector가 죽으면?" | 앱 OTel SDK retry 5분 + Prometheus scrape는 다음 interval에 자동 복구. 메트릭 gap은 out_of_order_time_window로 수용           |
| "Mimir 디스크가 가득 차면?"    | Compactor retention 7일로 자동 정리. 긴급 시 수동 compaction 트리거. 알림: `mimir_ingester_tsdb_head_series` + disk usage    |
| "카디널리티 폭발이 일어나면?"      | `max_global_series_per_metric: 100,000`으로 1차 방어. metric_relabel_configs로 문제 label 드롭. 근본: 앱팀과 label 가이드라인 합의 |

### 4.3 성장 질문

| 질문                      | 핵심 답변 방향                                                                                               |
|-------------------------|--------------------------------------------------------------------------------------------------------|
| "Kubernetes 환경으로 전환하면?" | OTel Collector → DaemonSet/Deployment, Mimir → Helm chart (Microservices 모드), ServiceMonitor로 자동 디스커버리 |
| "멀티 클러스터면?"             | Mimir 멀티 테넌트 (X-Scope-OrgID), Collector per cluster → central Mimir. 또는 Grafana Cloud로 중앙화             |
| "서버가 500대로 늘어나면?"       | Mimir Read-Write 모드 전환, S3 backend, Collector HA (2대 + LB), Prometheus scrape는 hashmod로 target 분배      |

---

## 5. 답변 체크리스트

최종 확인 항목:

- [ ] LGTM 각 컴포넌트의 역할을 30초 내에 설명할 수 있는가
- [ ] 듀얼 파이프라인 분리 이유를 장애 시나리오로 설명할 수 있는가
- [ ] Mimir limits 5개 값의 산정 근거를 각각 설명할 수 있는가
- [ ] out_of_order_time_window 15분 = batch(5m) + retry(5m) + margin(5m)을 즉시 답할 수 있는가
- [ ] Exemplar → Tempo → traceToLogs 흐름을 화이트보드에 그릴 수 있는가
- [ ] Dynatrace → LGTM 전환의 ROI를 비즈니스 언어로 1분 내에 설명할 수 있는가
- [ ] "왜 Prometheus 대신 Mimir?" "왜 Elasticsearch 대신 Loki?"에 즉답할 수 있는가
- [ ] 1인 DevOps의 Bus Factor 리스크와 보완책을 솔직하게 답할 수 있는가
- [ ] metric_relabel_configs로 드롭하는 메트릭 3종과 이유를 설명할 수 있는가
- [ ] 서버 규모가 10배 늘어났을 때의 스케일링 계획을 제시할 수 있는가
