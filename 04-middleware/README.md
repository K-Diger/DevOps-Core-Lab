# 04. Middleware (Kong, Kafka, Redis, Harbor) — 기술 심화 가이드

> **리뷰어 관점**: 11년차 DevOps 팀 리드 + 6명 팀원 (인프라, SRE, 보안, 플랫폼, CI/CD, EM)
> **지원자**: 1년차 DevOps (스마일게이트, 1인 DevOps), Kong HA / Kafka 3-broker / Redis 3-node 클러스터 운영

---

## 1. 미들웨어 아키텍처 Overview

```
[External Client]
       │
   DMZ Nginx Proxy (/in/*, /out/*)
       │
   L4/L7 Switch VIP: 10.125.241.37
       │
   ┌───┴───┐
   │ Kong  │  Docker Compose: gw01(10.125.11.80), gw02(10.125.11.167) :8000/:8443
   │ Kong  │  K8s: 3 replicas, NodePort 30080/30443, Pod anti-affinity
   └───┬───┘
       │
   ┌───┴────────────────────────────┐
   │         Backend Services        │
   │                                 │
   │  ┌─────────┐  ┌──────────┐    │
   │  │ Kafka   │  │ Redis    │    │
   │  │ 3-broker│  │ 3-node   │    │
   │  │ 2-conn  │  │ cluster  │    │
   │  └─────────┘  └──────────┘    │
   │                                 │
   │  Harbor: registry.example.com │
   └─────────────────────────────────┘
```

**핵심 설계 원칙**: 미들웨어 각 컴포넌트는 **최소 3-node**로 구성하여 **1-node 장애 허용(N-1 tolerance)**을 보장한다. Kong은 VIP + upstream weight로
DC-to-K8s 무중단 마이그레이션 경로를 제공하고, Kafka는 `replication.factor=3, min.insync.replicas=2`로 데이터 유실 방지, Redis는 `allkeys-lru` +
AOF로 캐시 안정성과 영속성을 양립한다.

---

## 2. 핵심 설정 해설

### 2.1 Kong Gateway HA 구성

#### 아키텍처 구조

| 구분    | Docker Compose (Legacy)                 | Kubernetes (Target)           |
|-------|-----------------------------------------|-------------------------------|
| 노드    | gw01(10.125.11.80), gw02(10.125.11.167) | 3 replicas, Pod anti-affinity |
| 포트    | :8000(HTTP), :8443(HTTPS)               | NodePort 30080/30443          |
| HA 방식 | L4/L7 VIP: 10.125.241.37                | 동일 VIP 뒤에서 NodePort로 수신       |

#### 트래픽 흐름

```
Client → DMZ Nginx(/in/*, /out/*) → L4/L7 VIP(10.125.241.37) → Kong → Backend
```

- **DMZ Nginx Proxy**: 외부 콜백(`/in/*`)과 아웃바운드(`/out/*`)를 분리하여 방화벽 정책 단순화
- **L4/L7 스위치 VIP**: Kong 인스턴스들 앞단에 위치, Health Check 기반 failover
- **Kong Admin API upstream weight**: DC IP와 K8s NodePort를 동시에 upstream target으로 등록 후 weight를 점진적으로 이동 (예: DC 100→0, K8s
  0→100)

#### 왜 이렇게 설계했는가

1. **VIP 기반 HA**: DNS failover는 TTL 전파 지연이 있어 실시간 트래픽 전환에 부적합. L4/L7 VIP는 Health Check 주기(기본 5초) 내 failover 가능
2. **upstream weight 마이그레이션**: Blue/Green이나 Canary 배포와 동일한 원리. Kong Admin API의
   `PATCH /upstreams/{name}/targets/{target}/weight` 하나로 트래픽 비율 제어가 가능하므로 별도 LB 설정 변경 없이 마이그레이션 수행
3. **Pod anti-affinity**: `requiredDuringSchedulingIgnoredDuringExecution`으로 같은 노드에 Kong Pod가 2개 이상 배치되지 않도록 강제. 노드 장애 시
   모든 Kong이 동시에 죽는 SPOF 방지

#### 설정 포인트

```yaml
# K8s Kong Deployment (anti-affinity 핵심)
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchExpressions:
            - key: app
              operator: In
              values: [ "kong" ]
        topologyKey: "kubernetes.io/hostname"
```

```bash
# 마이그레이션: upstream target weight 조절
# DC → K8s 전환 시
curl -X PATCH http://kong-admin:8001/upstreams/my-service/targets/10.125.11.80:8080 \
  --data "weight=0"
curl -X PATCH http://kong-admin:8001/upstreams/my-service/targets/k8s-nodeport:30080 \
  --data "weight=100"
```

---

### 2.2 Kafka 클러스터 설계

#### 클러스터 토폴로지

| 역할               | IP            | 비고                 |
|------------------|---------------|--------------------|
| Broker 1         | 10.125.11.137 | JMX Exporter :9102 |
| Broker 2         | 10.125.11.20  | JMX Exporter :9102 |
| Broker 3         | 10.125.11.41  | JMX Exporter :9102 |
| Connect (Source) | 10.125.11.248 | Port 9102          |
| Connect (Sink)   | 10.125.11.111 | Port 9103          |

#### 핵심 설정과 근거

```properties
# kafka-broker.yml 핵심 설정
# JVM Heap
-Xms16g -Xmx16g
# Replication
default.replication.factor=3
min.insync.replicas=2
# Producer Idempotence
enable.idempotence=true
```

**왜 `replication.factor=3, min.insync.replicas=2`인가:**

이것은 **2/3 quorum** 패턴이다.

- `replication.factor=3`: 모든 파티션 데이터가 3개 브로커에 복제
- `min.insync.replicas=2`: Producer가 `acks=all`로 전송할 때, 최소 2개 replica가 write를 확인해야 성공 응답
- **1대 장애 허용**: 3대 중 1대가 죽어도 나머지 2대가 ISR(In-Sync Replicas)을 구성하므로 데이터 유실 없이 서비스 지속
- **2대 동시 장애 시**: ISR이 1대뿐이므로 `min.insync.replicas=2`를 충족하지 못해 **쓰기 거부(NotEnoughReplicasException)**. 이는 의도적 설계로, 데이터
  유실보다 **가용성 차단**을 선택한 것

**왜 16GB heap인가:**

- Kafka 브로커는 OS Page Cache를 적극 활용하므로 heap이 과도하면 오히려 GC pause가 길어짐
- 16GB는 LinkedIn의 권장 범위(6~16GB) 상한. 물리 메모리의 50% 이하를 heap에 할당하고, 나머지는 Page Cache로 활용하는 것이 Best Practice
- Full GC가 발생하면 broker가 ZooKeeper session timeout(기본 18초)을 넘길 수 있어, ISR에서 빠지는 위험 존재

**왜 `enable.idempotence=true`인가:**

- 네트워크 재시도 시 메시지 중복 전송 방지
- Kafka는 내부적으로 Producer ID + Sequence Number를 추적하여 동일 메시지의 재전송을 감지하고 무시
- 이것이 없으면 `retries > 0` 설정 시 broker 응답 timeout → 재전송 → 중복 메시지 발생 가능

#### Consumer 운영 패턴

| 서비스                       | Consumer 상태 | 의미                    |
|---------------------------|-------------|-----------------------|
| TLM                       | ON          | 실시간 처리 활성             |
| EAM, GEA, Common, CheckIn | OFF         | 데이터 적재만 하고 소비하지 않는 상태 |

- Consumer OFF 상태에서도 Producer는 계속 메시지를 적재 → **retention.ms** 설정에 따라 일정 기간 보관
- 필요 시 Consumer를 ON하면 **offset부터 재소비** 가능 (이것이 Kafka의 핵심 장점: 생산과 소비의 완전한 분리)

#### Connect 아키텍처

```
[Source Systems] → Connect Source(:9102, 10.125.11.248) → Kafka Brokers
                                                              ↓
[Target Systems] ← Connect Sink(:9103, 10.125.11.111) ← Kafka Brokers
```

- Source/Sink를 별도 노드로 분리한 이유: Source 커넥터의 부하(외부 DB polling 등)가 Sink(ES/DB write 등)에 영향을 주지 않도록 격리
- 포트 분리(9102/9103): 모니터링 시 Source/Sink 메트릭을 명확히 구분

---

### 2.3 Redis 클러스터

#### 클러스터 토폴로지

| 역할        | 호스트             |
|-----------|-----------------|
| Master    | olvkch-eptmrd01 |
| Replica 1 | olvkch-eptmrc01 |
| Replica 2 | olvkch-eptmrc02 |

- **Cross-placement**: Master와 Replica가 물리적으로 다른 서버(랙/호스트)에 배치
- 호스트명 패턴: `eptmrd`(Data/Master), `eptmrc`(Cache/Replica) — 역할 기반 네이밍

#### 핵심 설정과 근거

```conf
# redis.conf
maxmemory 16gb
maxmemory-policy allkeys-lru
cluster-enabled yes
appendonly yes
```

**왜 `allkeys-lru`인가:**

Redis의 eviction policy 선택지:

| Policy           | 대상         | 동작                         |
|------------------|------------|----------------------------|
| `noeviction`     | -          | 메모리 초과 시 쓰기 거부 (OOM Error) |
| `volatile-lru`   | TTL 설정된 키만 | TTL 키 중 LRU 제거             |
| `allkeys-lru`    | 모든 키       | **전체 키 중 LRU 제거**          |
| `allkeys-random` | 모든 키       | 랜덤 제거                      |

- `allkeys-lru` 선택 이유: 캐시 용도에서는 모든 키가 eviction 대상이어야 함. `volatile-lru`는 TTL이 설정되지 않은 키를 영원히 보관하므로, TTL 미설정 키가 메모리를 점유하면
  결국 OOM 발생
- 대기업 운영에서는 모든 개발팀이 TTL을 빠짐없이 설정할 것이라고 가정하기 어렵기 때문에, **방어적으로 `allkeys-lru`를 선택**하는 것이 Best Practice

**왜 `appendonly yes`(AOF)인가:**

| 방식                     | 데이터 유실              | 복구 속도     | 파일 크기  |
|------------------------|---------------------|-----------|--------|
| RDB (snapshotting)     | 마지막 스냅샷 이후 유실       | 빠름        | 작음     |
| AOF (append-only file) | 최대 1초 유실 (everysec) | 느림        | 큼      |
| RDB + AOF              | 최대 1초 유실            | AOF 우선 복구 | 둘 다 유지 |

- 캐시 용도이지만 AOF를 켠 이유: Redis restart 시 캐시가 완전히 비면 **Cache Stampede**(모든 요청이 동시에 DB로 향함) 발생. AOF로 최소한의 데이터를 복구하면 restart
  직후에도 일정 hit rate 유지 가능
- `appendfsync everysec`(기본값): 1초마다 fsync하므로 최악의 경우 1초분 데이터만 유실. 성능과 안정성의 균형점

**왜 `cluster-enabled yes`(Redis Cluster)인가:**

- Sentinel vs Cluster: Sentinel은 failover 전용이고 데이터 샤딩을 하지 않음. Cluster는 16384개 hash slot으로 데이터를 분산하면서 자동 failover도 제공
- 3-node(Master 1 + Replica 2) 구성에서는 샤딩보다 HA가 주 목적. Master 장애 시 Replica 중 하나가 자동 promote
- 현재 구성의 한계: Master가 1대이므로 write 성능 확장은 불가. 향후 write 부하 증가 시 Multi-Master(3 Master + 3 Replica) 전환 필요

#### Redis Exporter

```
Redis Exporter(:9121) → Prometheus scrape → Grafana 대시보드
```

- 주요 메트릭: `redis_connected_clients`, `redis_used_memory_bytes`, `redis_evicted_keys_total`,
  `redis_keyspace_hits_total / misses_total`(hit rate 계산)
- **hit rate < 80%이면 캐시 효용이 낮다**는 신호 → 캐시 전략 재검토 필요

---

### 2.4 Harbor 사설 레지스트리

#### 구성

- URL: `registry.example.com`
- Build Server: 10.125.11.146

#### 프로젝트 구조

| 프로젝트           | 용도                          |
|----------------|-----------------------------|
| `k8s/`         | Kubernetes 시스템 이미지          |
| `cilium/`      | CNI 플러그인 이미지                |
| `istio/`       | Service Mesh 이미지            |
| `argocd/`      | GitOps 이미지                  |
| `gatekeeper/`  | OPA/Policy 이미지              |
| `dockerhub/`   | Docker Hub 미러 (proxy cache) |
| `helm-charts/` | Helm Chart 저장소              |
| `ep-be-*/`     | 서비스별 Backend 이미지            |

#### 왜 Harbor인가 (폐쇄망 컨텍스트)

1. **폐쇄망에서 외부 레지스트리 접근 불가**: Docker Hub, GCR, Quay 등에 직접 접근할 수 없으므로, 내부에 이미지 공급 체인 구축 필수
2. **이미지 보안 스캐닝**: Harbor는 Trivy 기반 취약점 스캔 내장. 폐쇄망이라도 이미지 내부의 CVE는 존재하므로 스캔 필수
3. **Proxy Cache**: `dockerhub/` 프로젝트를 proxy cache로 구성하면, 최초 1회만 외부에서 pull하고 이후는 Harbor 캐시에서 제공 (인터넷 연결 가능 구간에서)
4. **RBAC**: 프로젝트별 접근 제어. `ep-be-*` 프로젝트는 해당 서비스 팀만 push 가능

#### 이미지 공급 체인 흐름

```
[외부 레지스트리] → (DMZ 경유, 수동/자동 sync) → Harbor(harbor-registry) → K8s containerd pull
                                                        ↑
                                              CI/CD Pipeline push (Build Server)
```

---

## 3. 심화 Q&A — 팀 토론 결과

---

### [팀원1: 박준혁 — 인프라 엔지니어, 8년차]

> "미들웨어 인프라 설계의 핵심은 장애 격리와 확장 경로다. 1년차가 이걸 직접 설계하고 운영했다면, 설계 의도와 한계를 정확히 아는지 봐야 한다."

#### Q1. Kong Gateway를 Docker Compose와 K8s 두 환경에서 동시에 운영한 이유는?

**의도**: 마이그레이션 전략 수립 능력. DC-to-K8s 전환이 한 번에 되지 않는다는 현실을 이해하는지.

**키포인트**:

1. **무중단 마이그레이션**: 기존 DC(Docker Compose)와 신규 K8s를 upstream weight로 병행 운영하며 점진적 전환. 한 번에 전환(Big Bang)하면 롤백이 불가능
2. **VIP 불변성**: L4/L7 VIP(`10.125.241.37`)는 클라이언트에 노출된 엔드포인트. 이 주소를 바꾸지 않으면서 백엔드만 전환해야 하므로, Kong upstream level에서 weight
   제어가 유일한 방법
3. **검증 기간 확보**: K8s Kong에 10% 트래픽만 보내면서 에러율/레이턴시 비교 후 점진 증가. 문제 발생 시 weight만 되돌리면 즉시 롤백

**꼬리질문 1**: "upstream weight를 조절하는 동안 세션 유지(sticky session)는 어떻게 처리했나요?"

**키포인트**:

1. Kong의 `hash_on` 설정(consumer, ip, header 등)을 사용하면 consistent hashing으로 특정 클라이언트를 동일 upstream target에 고정 가능
2. 단, weight 전환 중 hash ring이 변경되면 기존 세션이 끊길 수 있음. 이를 해결하려면 세션 스토어를 Redis로 외부화하거나, 전환 시점을 트래픽이 적은 시간대로 선정
3. Stateless 설계가 되어 있다면 sticky session 자체가 불필요. JWT 토큰 기반 인증이면 어느 Kong 인스턴스가 받아도 동일하게 처리

**꼬리질문 2**: "Kong이 L4/L7 스위치 뒤에 있는데, 왜 Kong 앞에 별도 LB가 필요한 건가요? Kong 자체가 LB 아닌가요?"

**키포인트**:

1. Kong은 **L7 API Gateway**(라우팅, 인증, rate limiting 등)이지 L4 LB가 아님. Kong 인스턴스 자체의 HA를 위해 앞단에 L4/L7 스위치가 필요
2. "LB가 LB한다"는 계층 구조: L4 스위치 → Kong(L7 라우팅) → Backend. 각 계층의 역할이 다름
3. 만약 Kong이 단일 인스턴스라면 SPOF. 2대 이상 Kong을 묶으려면 앞단에 VIP가 반드시 필요

---

#### Q2. Kafka `min.insync.replicas=2`를 `1`로 바꾸면 어떤 일이 벌어지는가?

**의도**: 설정값의 의미를 숫자 레벨에서 정확히 이해하는지. "3-2 = 1대 장애 허용"이라는 공식 너머의 trade-off를 아는지.

**키포인트**:

1. `min.insync.replicas=1`이면 **Leader replica 혼자만 write 확인해도 성공 응답**. 이 순간 Leader가 죽으면 아직 다른 replica에 복제되지 않은 데이터가 유실됨
2. `acks=all`과 `min.insync.replicas`는 세트로 동작. `acks=all` + `min.isr=1`은 사실상 `acks=1`과 동일한 내구성 수준
3. `min.isr=2`의 비용: 2대 동시 장애 시 쓰기 불가(`NotEnoughReplicasException`). 가용성을 일부 희생하여 내구성을 확보하는 선택

**꼬리질문 1**: "브로커 3대 중 2대가 동시에 죽으면 어떻게 대응하나요?"

**키포인트**:

1. `min.insync.replicas=2`이므로 쓰기 불가 상태 진입. Producer에서 `NotEnoughReplicasException` 발생
2. 읽기(Consumer)는 남은 1대의 Leader에서 계속 가능할 수 있으나, 해당 파티션의 Leader가 죽은 브로커에 있었다면 읽기도 불가
3. 복구 전략: (1) 죽은 브로커를 최대한 빨리 복구, (2) 불가능하면 `min.insync.replicas`를 일시적으로 1로 낮춰 서비스 복구 후 원복. 이 결정은 **데이터 유실 감수 vs 서비스 중단
   지속** 사이의 비즈니스 판단

**꼬리질문 2**: "`enable.idempotence=true`가 exactly-once를 보장하는 건가요?"

**키포인트**:

1. `enable.idempotence=true`는 **Producer-to-Broker 구간**에서만 중복 방지. Broker에 메시지가 정확히 1번 기록됨을 보장
2. **End-to-end exactly-once**는 Kafka Transactions(`transactional.id`)가 필요. Consumer-Producer 패턴(
   consume-transform-produce)에서 offset commit과 produce를 원자적으로 처리
3. Consumer 측에서 동일 메시지를 2번 처리하는 것은 idempotence로 막을 수 없음. Consumer의 idempotent 처리(예: DB upsert, 중복 체크 키)는 애플리케이션 레벨 책임

---

#### Q3. Redis `maxmemory 16gb`는 어떤 기준으로 산정했는가?

**의도**: 용량 산정(Capacity Planning)을 감으로 했는지, 데이터 기반으로 했는지.

**키포인트**:

1. Redis는 싱글 스레드이므로 CPU보다 **메모리 + 네트워크 대역폭**이 병목. 16GB는 물리 서버 메모리의 일부를 할당한 것 (OS + 기타 프로세스 + fork 시 COW 오버헤드 고려)
2. `maxmemory`는 반드시 물리 메모리보다 작아야 함. Redis가 fork(BGSAVE, AOF rewrite)할 때 COW(Copy-On-Write)로 최대 2배 메모리를 순간 사용할 수 있으므로, *
   *물리 메모리의 50~60%** 이하가 안전
3. 모니터링 기반 조정: `redis_used_memory_bytes / redis_maxmemory`로 사용률 추적. 80% 이상이면 eviction이 빈번해지므로 증설 검토

**꼬리질문 1**: "AOF rewrite 중에 OOM이 발생할 수 있다고 했는데, 실제로 경험했나요?"

**키포인트**:

1. AOF rewrite는 `BGREWRITEAOF`로 child process를 fork하는데, 이때 COW가 발생. 쓰기가 많은 시점에 fork하면 변경된 page를 복사하므로 메모리 급증
2. 리눅스 `vm.overcommit_memory` 설정이 0(기본값)이면 커널이 fork를 거부할 수 있음. Redis 공식 문서는 `vm.overcommit_memory=1` 권장
3. 대응: `auto-aof-rewrite-percentage`와 `auto-aof-rewrite-min-size`로 rewrite 빈도 조절. 트래픽이 적은 시간대에 수동 rewrite 실행도 방법

**꼬리질문 2**: "Redis Cluster에서 Master가 1대인데, write 병목이 생기면 어떻게 확장하나요?"

**키포인트**:

1. 현재 구성(Master 1 + Replica 2)은 HA 목적이지 샤딩 목적이 아님. Write가 모두 1대의 Master에 집중
2. 확장: Master를 3대로 늘려 hash slot을 분산 (예: Master1: 0-5460, Master2: 5461-10922, Master3: 10923-16383). 각 Master에 Replica를
   붙여 3M+3R = 6-node 구성
3. `CLUSTER RESHARD` 명령으로 온라인 중 slot 이동 가능. 단, resharding 중 해당 slot의 키에 대한 latency 증가 가능성 있으므로 트래픽이 적은 시간대 권장

---

#### Q4. DMZ Nginx Proxy에서 `/in/*`과 `/out/*`을 분리한 구체적 이유는?

**의도**: 네트워크 보안 아키텍처(DMZ, 방화벽 정책)에 대한 이해도.

**키포인트**:

1. `/in/*`(인바운드 콜백): 외부 서비스(결제 PG, OAuth Provider 등)가 내부 서비스를 호출하는 경로. 방화벽에서 **외부→내부** 방향만 허용
2. `/out/*`(아웃바운드): 내부 서비스가 외부 API를 호출할 때 Nginx를 forward proxy로 경유. 방화벽에서 **내부→외부** 방향만 허용
3. 분리 이유: 방화벽 규칙을 경로 기반으로 세분화. `/in/*`은 source IP를 화이트리스트로 제한하고, `/out/*`은 destination 도메인을 화이트리스트로 제한. 하나의 Nginx에서 처리하되
   경로로 정책을 분리하면 관리 복잡도를 줄일 수 있음

**꼬리질문 1**: "DMZ Nginx 자체가 SPOF가 될 수 있는데, 이 부분의 HA는?"

**키포인트**:

1. DMZ Nginx도 2대 이상으로 구성하고 앞단에 L4 LB(또는 VIP)를 배치하는 것이 표준
2. 대안: Keepalived로 Active-Standby VIP 구성. VRRP 프로토콜 기반 failover
3. 클라우드 환경이라면 NLB/ALB가 이 역할을 대체하지만, 온프레미스에서는 Keepalived + Nginx가 가장 일반적

**꼬리질문 2**: "Kong이 이미 L7 프록시인데 왜 DMZ에 Nginx를 따로 두나요?"

**키포인트**:

1. **네트워크 존(Zone) 분리**: DMZ Nginx는 외부 네트워크와 직접 통신하는 위치에 있고, Kong은 내부 네트워크에 위치. Kong을 DMZ에 노출하면 공격 표면이 넓어짐
2. DMZ Nginx는 최소 기능(리버스 프록시, IP 필터링)만 수행하여 공격 표면을 최소화. Kong의 Admin API 등이 외부에 노출되면 치명적
3. **심층 방어(Defense in Depth)**: DMZ Nginx → 방화벽 → Kong → Backend. 각 계층이 하나의 보안 경계를 형성

---

### [팀원2: 이서연 — SRE, 6년차]

> "미들웨어는 장애 시 영향 반경이 크다. SRE 관점에서 모니터링, 장애 대응, 복구 시나리오를 얼마나 구체적으로 준비했는지 본다."

#### Q1. Kafka 브로커 1대가 갑자기 죽었을 때, 서비스에 어떤 영향이 있고 어떻게 대응하나요?

**의도**: 장애 시나리오를 머릿속에서 시뮬레이션할 수 있는지. 단순 "replica가 있으니 괜찮아요"가 아닌 구체적 영향도를 아는지.

**키포인트**:

1. **Leader 파티션이 있던 브로커가 죽은 경우**: 해당 파티션의 ISR 중 하나가 새 Leader로 선출(Controller broker가 결정). 선출 동안(밀리초~수초) 해당 파티션의
   produce/consume이 일시 중단
2. **Follower 파티션만 있던 브로커가 죽은 경우**: 서비스 영향 없음. 단, ISR이 3→2로 줄어 `min.insync.replicas=2`의 여유가 0이 됨. 추가 1대 장애 시 쓰기 불가
3. **대응**: (1) 알림 확인(JMX Exporter → Prometheus Alert), (2) ISR 상태 확인(`kafka-topics.sh --describe`), (3) Under-Replicated
   Partitions 메트릭 모니터링, (4) 브로커 복구 또는 신규 브로커 투입 후 `kafka-reassign-partitions.sh`로 파티션 재분배

**꼬리질문 1**: "`Under-Replicated Partitions` 메트릭이 0이 아닌 상태가 지속되면 어떤 의미인가요?"

**키포인트**:

1. 일부 파티션의 replica가 Leader를 따라잡지 못하고 있다는 의미. ISR에서 빠진 replica 존재
2. 원인: 네트워크 지연, 디스크 I/O 병목, 브로커 과부하(특정 브로커에 Leader 파티션 쏠림)
3. `replica.lag.time.max.ms`(기본 30초) 이상 지연되면 ISR에서 제거됨. 지속 시 `preferred-replica-election`이나 파티션 재분배로 부하 분산

**꼬리질문 2**: "Kafka Connect 노드가 죽으면 커넥터 태스크는 어떻게 되나요?"

**키포인트**:

1. Kafka Connect는 **분산 모드**에서 Worker 그룹을 형성. Worker가 죽으면 나머지 Worker가 해당 태스크를 **리밸런싱**하여 인계
2. 현재 Source 1대, Sink 1대이므로 하나가 죽으면 **해당 방향의 모든 커넥터 태스크가 중단**됨. SPOF 구조
3. 개선: Source/Sink 각각 2대 이상으로 구성하여 리밸런싱 가능하게 확장. 또는 K8s Deployment로 전환하여 자동 복구

---

#### Q2. Redis 캐시 hit rate이 급격히 떨어졌을 때의 트러블슈팅 절차는?

**의도**: 모니터링 메트릭 해석과 원인 분석 능력.

**키포인트**:

1. **확인 순서**: (1) `redis_evicted_keys_total` 급증 여부 → 메모리 부족으로 키 제거 중, (2) `redis_used_memory_bytes` 추이 → `maxmemory`에
   도달했는지, (3) 애플리케이션 배포 이력 → 캐시 키 패턴 변경이나 TTL 설정 누락
2. **eviction 급증 시**: `allkeys-lru`에 의해 오래된 키부터 제거 → 자주 사용되는 키도 밀려남 → hit rate 하락의 악순환
3. **대응**: (1) `maxmemory` 증설(단기), (2) 캐시 키 패턴 분석으로 불필요한 대용량 키 식별(`MEMORY USAGE key`), (3) TTL 최적화로 자연 만료 유도

**꼬리질문 1**: "Redis `SLOWLOG`는 어떻게 활용하나요?"

**키포인트**:

1. `SLOWLOG GET 10`으로 최근 느린 명령어 10개 확인. `slowlog-log-slower-than` 설정(기본 10000마이크로초=10ms) 이상 걸린 명령어 기록
2. `KEYS *` 같은 O(N) 명령어가 잡히면 즉시 해당 애플리케이션 팀에 `SCAN`으로 변경 요청
3. `SORT`, `SMEMBERS`(대용량 Set) 등도 빈번히 잡힘. 데이터 구조 재설계 필요 여부 판단 근거

**꼬리질문 2**: "Redis Cluster의 failover 시간은 얼마나 걸리고, 그 동안 서비스 영향은?"

**키포인트**:

1. Redis Cluster의 `cluster-node-timeout`(기본 15초) 이후 failover 시작. 실제 failover 완료까지 추가 수초 소요. 총 **15~20초** 정도 해당 Master의
   write 불가
2. 읽기는 `READONLY` 모드의 Replica에서 가능하나, 애플리케이션이 이를 지원해야 함
3. `cluster-node-timeout`을 낮추면(예: 5초) failover가 빨라지지만, 일시적 네트워크 지터를 장애로 오판할 위험 증가. 환경에 맞는 튜닝 필요

---

#### Q3. Kong Gateway의 Health Check 실패 시 트래픽 처리 흐름은?

**의도**: 장애 전파 경로를 계층별로 추적할 수 있는지.

**키포인트**:

1. **L4/L7 스위치 레벨**: 스위치가 Kong 인스턴스에 TCP/HTTP Health Check 수행. 실패 시 해당 Kong 인스턴스를 풀에서 제거, 나머지 인스턴스로 트래픽 전달
2. **Kong 레벨**: Kong이 upstream backend에 Active/Passive Health Check 수행. Active는 주기적 probe, Passive는 실제 트래픽 응답 코드 기반. 실패
   시 해당 backend을 circuit break
3. **이중 Health Check**: L4/L7 → Kong, Kong → Backend 두 계층에서 각각 Health Check. Kong 자체가 죽으면 L4/L7이 처리하고, Backend이 죽으면
   Kong이 처리

**꼬리질문 1**: "Kong의 Active Health Check과 Passive Health Check의 차이와 어떤 것을 선호하나요?"

**키포인트**:

1. **Active**: 별도 Health Check 요청을 주기적으로 전송. Backend이 트래픽 없이도 상태를 감지 가능. 단, 불필요한 요청 발생
2. **Passive**: 실제 트래픽의 응답 코드/타임아웃을 분석. 추가 요청 없지만, 트래픽이 없으면 장애를 감지하지 못함
3. **Best Practice**: Active + Passive 병행. Passive로 빠른 감지, Active로 복구 감지(`healthy.successes` threshold 달성 시 다시 풀에 추가)

**꼬리질문 2**: "Kong을 K8s로 완전 마이그레이션한 후에도 L4/L7 스위치가 필요한가요?"

**키포인트**:

1. K8s 내부에서는 Service(ClusterIP) + Ingress Controller가 L4/L7 역할을 대체 가능
2. 그러나 **외부 트래픽 진입점**에서는 여전히 필요. NodePort는 특정 노드 IP에 의존하므로, 노드 장애 시 해당 IP로의 요청 실패. L4 스위치가 여러 노드의 NodePort를 묶어서 HA 제공
3. 대안: MetalLB(온프레미스 LoadBalancer 타입 Service)나 External LB를 사용하면 L4/L7 스위치 의존도를 낮출 수 있음

---

#### Q4. JMX Exporter(Kafka :9102) 메트릭 중 가장 중요하게 보는 3가지는?

**의도**: 실제 운영에서 어떤 메트릭을 보고 판단하는지. 교과서적 답변이 아닌 실전 경험.

**키포인트**:

1. **`kafka_server_ReplicaManager_UnderReplicatedPartitions`**: 0이 아니면 즉시 확인. ISR 부족 = 데이터 유실 위험
2. **`kafka_server_BrokerTopicMetrics_MessagesInPerSec`**: 초당 메시지 유입량. 급증하면 Producer 측 이상(재시도 폭풍 등), 급감하면 Producer 장애
3. **`kafka_network_RequestMetrics_TotalTimeMs`**: Produce/Fetch 요청의 총 처리 시간. p99가 임계치를 넘으면 브로커 과부하나 디스크 I/O 병목

**꼬리질문 1**: "Consumer Lag 모니터링은 어떻게 하나요?"

**키포인트**:

1. `kafka_consumergroup_lag` 메트릭(Kafka Exporter 또는 Burrow 사용). Consumer가 Producer를 따라잡지 못하는 정도를 offset 차이로 측정
2. Lag이 지속 증가하면: (1) Consumer 처리 속도 부족 → Consumer 인스턴스 증설(파티션 수 이하까지), (2) 특정 파티션에 메시지 쏠림 → 키 분배 전략 재검토
3. 현재 Consumer OFF인 서비스(EAM, GEA 등)는 Lag이 계속 증가하는 것이 정상. retention.ms 이내에 소비를 시작해야 데이터 유실 방지

**꼬리질문 2**: "Kafka 메트릭과 Redis 메트릭을 같은 Prometheus에서 수집하나요? 스케일 이슈는?"

**키포인트**:

1. 소규모(브로커 3대, Redis 3노드)에서는 단일 Prometheus로 충분. 카디널리티가 낮으므로 성능 이슈 없음
2. 대규모로 확장 시: Prometheus Federation이나 Thanos/Mimir로 장기 저장 + 다중 클러스터 집계
3. Kafka 메트릭은 JMX 기반이라 cardinality가 높을 수 있음(토픽명 × 파티션 수 × 메트릭 종류). `relabel_configs`로 불필요한 라벨 제거하여 카디널리티 관리

---

### [팀원3: 최민수 — 보안 엔지니어, 9년차]

> "미들웨어는 데이터가 통과하는 핵심 경로다. 보안 관점에서 암호화, 접근 제어, 감사 로그를 제대로 하고 있는지 본다."

#### Q1. Kafka 브로커 간 통신과 클라이언트-브로커 통신에 암호화를 적용하고 있나요?

**의도**: 미들웨어 구간의 데이터 암호화 인식 수준.

**키포인트**:

1. **Inter-broker 통신**: `security.inter.broker.protocol=SSL` 또는 `SASL_SSL`로 설정하면 브로커 간 복제 트래픽이 TLS로 암호화
2. **Client-broker 통신**: `listeners`에 `SSL://` 또는 `SASL_SSL://` 프로토콜을 설정. Producer/Consumer가 TLS 인증서를 사용하여 연결
3. **현실적 판단**: 폐쇄망 내부 통신이라면 암호화 오버헤드(CPU 10~20%, latency 증가)를 감수할 이유가 약할 수 있음. 그러나 컴플라이언스(개인정보 포함 메시지 등)에 따라 필수일 수 있음

**꼬리질문 1**: "Kafka ACL은 어떻게 관리하고 있나요?"

**키포인트**:

1. `kafka-acls.sh`로 토픽별 produce/consume 권한을 서비스 계정(SASL user) 단위로 제어
2. 운영 팁: `--allow-principal User:service-a --operation Read --topic orders` 형태로 최소 권한 원칙 적용
3. ACL 미적용 시 모든 클라이언트가 모든 토픽에 접근 가능 → 잘못된 Consumer가 다른 서비스의 토픽을 소비하는 사고 발생 가능

**꼬리질문 2**: "Harbor 이미지 취약점 스캔 결과를 어떻게 활용하나요?"

**키포인트**:

1. Harbor의 Trivy 스캔으로 이미지 push 시 자동 스캔. Critical/High CVE가 있으면 배포 차단 가능(`Prevent vulnerable images from running` 정책)
2. **Admission Controller 연동**: OPA Gatekeeper나 Kyverno로 취약점 등급이 일정 이상인 이미지의 Pod 생성을 차단
3. 폐쇄망에서 Trivy DB 업데이트가 과제. 주기적으로 외부에서 DB를 다운로드하여 내부에 sync하는 파이프라인 필요

---

#### Q2. Redis에 저장되는 데이터의 암호화와 접근 제어는 어떻게 하고 있나요?

**의도**: 캐시에도 민감 데이터가 저장될 수 있다는 인식이 있는지.

**키포인트**:

1. **전송 암호화**: Redis 6.0+에서 TLS 지원(`tls-port`, `tls-cert-file`, `tls-key-file`). 클라이언트-Redis 구간 암호화
2. **접근 제어**: Redis 6.0+ ACL(`ACL SETUSER`). 사용자별 허용 명령어와 키 패턴 제한 가능 (예: `+get +set ~session:*` = session 키에 대해 get/set만
   허용)
3. **저장 데이터 암호화**: Redis 자체는 at-rest encryption을 제공하지 않음. 필요 시 애플리케이션 레벨에서 암호화한 데이터를 저장하거나, 디스크 레벨 암호화(LUKS 등) 적용

**꼬리질문 1**: "Redis의 `FLUSHALL` 같은 위험 명령어를 어떻게 차단하나요?"

**키포인트**:

1. `rename-command FLUSHALL ""` (redis.conf)으로 명령어 자체를 비활성화
2. Redis 6.0+ ACL로 특정 사용자에게만 위험 명령어 허용. 운영 계정만 `+flushall` 권한
3. 추가 방어: 네트워크 레벨에서 Redis 포트(6379)에 접근 가능한 IP를 `bind` 설정과 방화벽으로 제한

**꼬리질문 2**: "Kong Gateway에서 API 인증은 어떻게 처리하나요?"

**키포인트**:

1. Kong 플러그인: `key-auth`, `jwt`, `oauth2`, `basic-auth` 등. Route/Service 단위로 적용 가능
2. **Best Practice**: JWT 플러그인으로 토큰 검증을 Kong에서 수행, Backend는 인증 로직 없이 비즈니스 로직에 집중 (관심사 분리)
3. Rate Limiting 플러그인과 조합: 인증된 사용자도 분당 요청 수 제한으로 DDoS/남용 방지

---

#### Q3. Harbor 폐쇄망에서 이미지 공급 체인의 무결성을 어떻게 보장하나요?

**의도**: Supply Chain Security(SLSA, Sigstore 등)에 대한 인식.

**키포인트**:

1. **이미지 서명**: Harbor는 Cosign/Notation 기반 이미지 서명을 지원. CI 파이프라인에서 빌드 후 서명, 배포 시 서명 검증
2. **Content Trust**: Docker Content Trust(Notary)를 Harbor에서 활성화. 서명되지 않은 이미지의 pull을 차단
3. **SBOM(Software Bill of Materials)**: 이미지 내 패키지 목록을 생성하여 Harbor에 첨부. Trivy 스캔과 연동하여 특정 라이브러리 버전에 CVE가 발견되면 영향받는 이미지를
   역추적

**꼬리질문 1**: "폐쇄망에서 외부 이미지를 어떤 절차로 내부에 반입하나요?"

**키포인트**:

1. **Air-gap 전송**: 인터넷 연결 가능한 별도 시스템에서 이미지를 `docker save`로 tar로 추출 → 물리적/논리적 경로(SFTP, USB 등)로 내부 전송 → `docker load` →
   Harbor에 push
2. **Proxy Cache 방식**: Harbor의 `dockerhub/` 프로젝트를 Docker Hub의 proxy cache로 설정. DMZ 경유로 최초 pull 시 캐싱. 이후 내부에서는 Harbor에서만
   pull
3. **보안 검토**: 반입 전 이미지 스캔 필수. 외부 이미지는 기본적으로 불신하고, 스캔 통과 + 승인 절차 후 프로덕션 프로젝트로 promotion

**꼬리질문 2**: "`dockerhub/` 프로젝트와 `k8s/` 프로젝트를 분리한 이유는?"

**키포인트**:

1. **RBAC 분리**: `dockerhub/`은 미러링 자동화 계정만 push 가능, `k8s/`는 인프라 팀만 push 가능. 역할별 접근 제어
2. **정책 분리**: `dockerhub/`은 proxy cache 모드(자동 동기화), `k8s/`는 manual push 모드(승인 후 push). 같은 프로젝트에 두면 정책 혼선
3. **감사 추적**: 프로젝트별 감사 로그가 분리되어, 누가 언제 어떤 이미지를 push/pull했는지 추적이 명확

---

### [팀원4: 김하준 — 플랫폼 엔지니어, 7년차]

> "1인 DevOps로 이 모든 미들웨어를 운영했다면, 자동화와 표준화를 얼마나 했는지가 핵심이다. 매번 수동으로 했다면 확장 불가능한 구조."

#### Q1. Kafka 브로커 설정 변경(예: `log.retention.hours`)을 어떻게 배포하나요?

**의도**: 미들웨어 설정 관리의 자동화/IaC 수준.

**키포인트**:

1. **수동 방식**: 각 브로커 서버에 SSH 접속 → `server.properties` 수정 → `kafka-server-stop.sh` / `kafka-server-start.sh` 롤링 재시작. 3대
   순차적으로 (한 대씩 재시작하며 ISR 유지 확인)
2. **자동화 방식**: Ansible playbook으로 설정 파일 템플릿화 + 롤링 재시작 자동화. `serial: 1`로 한 대씩 진행, `wait_for`로 브로커 재합류 확인 후 다음 진행
3. **Dynamic Config**: Kafka의 일부 설정은 재시작 없이 동적 변경 가능(`kafka-configs.sh --alter`). 예: `log.retention.ms`,
   `log.retention.bytes`. 그러나 `listeners`, `log.dirs` 등은 재시작 필요

**꼬리질문 1**: "Kafka를 K8s로 마이그레이션할 계획이 있나요? StatefulSet으로 운영할 때의 주의점은?"

**키포인트**:

1. **StatefulSet 필수**: Pod 이름이 고정(kafka-0, kafka-1, kafka-2)되어 broker.id와 매핑. PVC로 데이터 영속
2. **주의점**: (1) PVC는 Pod 삭제 시에도 유지되어야 함(`reclaimPolicy: Retain`), (2) `advertised.listeners`에 Pod DNS(
   kafka-0.kafka-headless.namespace.svc)를 사용해야 클라이언트가 올바른 브로커에 연결, (3) 롤링 업데이트 시 `partition.assignment.strategy` 재분배 고려
3. **Operator 사용 권장**: Strimzi나 Confluent Operator가 StatefulSet 관리, 롤링 업데이트, 모니터링을 자동화. 직접 StatefulSet을 작성하면 운영 복잡도가 높음

**꼬리질문 2**: "Kafka Connect의 커넥터 설정도 IaC로 관리하나요?"

**키포인트**:

1. Kafka Connect REST API(`POST /connectors`)로 커넥터 생성/수정. JSON 기반이므로 Git에 커넥터 설정 JSON을 저장하고 CI/CD에서 API 호출
2. 주의: Connect 클러스터가 재시작되면 `config.storage.topic`에서 설정을 복원하지만, Git과의 drift 가능. GitOps 패턴처럼 주기적으로 desired state와 actual
   state를 비교하는 reconciliation 로직 필요
3. Strimzi Operator의 `KafkaConnector` CRD를 사용하면 K8s native하게 커넥터를 선언적으로 관리 가능

---

#### Q2. Redis Cluster의 노드 교체(예: 하드웨어 장애)는 어떤 절차로 하나요?

**의도**: 상태를 가진(Stateful) 미들웨어의 노드 교체 경험.

**키포인트**:

1. **Replica 교체(영향 적음)**: (1) 장애 Replica를 클러스터에서 `CLUSTER FORGET`으로 제거, (2) 새 서버에 Redis 설치 및 동일 redis.conf 적용, (3)
   `CLUSTER MEET`으로 새 노드 추가, (4) `CLUSTER REPLICATE <master-node-id>`로 Master에 연결 → 자동으로 데이터 동기화
2. **Master 교체(영향 있음)**: (1) 먼저 Replica 중 하나를 `CLUSTER FAILOVER`로 승격(수동 failover), (2) 기존 Master가 Replica로 강등, (3) 이후 기존
   Master 노드를 제거하고 새 노드를 Replica로 추가
3. **핵심**: Master를 직접 제거하지 않고, 반드시 **Replica로 강등 후 제거**. 직접 제거하면 hash slot이 비는 시간이 발생

**꼬리질문 1**: "Redis 데이터 백업은 어떻게 하나요?"

**키포인트**:

1. **RDB 스냅샷**: `BGSAVE`로 특정 시점의 전체 데이터를 dump.rdb 파일로 저장. 주기적으로 외부 스토리지에 복사
2. **AOF**: 모든 write 명령어를 기록. `appendonly yes` 상태에서 AOF 파일 자체가 백업 역할
3. **Replica 활용**: Replica에서 `BGSAVE`를 실행하면 Master에 영향 없이 백업 가능. Master에서 fork하면 write 많을 때 latency 영향

**꼬리질문 2**: "현재 Redis 구성에서 가장 개선하고 싶은 점은?"

**키포인트**:

1. **Multi-Master 전환**: 현재 Master 1대 구조는 write 확장에 한계. 3-Master + 3-Replica 구성으로 전환하면 write 처리량 3배 향상
2. **모니터링 강화**: Redis Exporter(:9121) 기반 Grafana 대시보드에 `redis_connected_clients`, `redis_used_memory_peak_bytes`,
   `redis_evicted_keys_total` 알림 추가
3. **접근 제어**: Redis 6.0+ ACL 적용하여 서비스별 접근 권한 분리. 현재 단일 비밀번호 공유 구조라면 서비스 간 격리 불가

---

#### Q3. 미들웨어(Kong, Kafka, Redis) 설정 파일을 Git으로 관리하고 있나요?

**의도**: Configuration as Code 실천 여부.

**키포인트**:

1. **Git 관리 대상**: `docker-compose.yml`(Kong), `kafka-broker.yml`/`server.properties`(Kafka), `redis.conf`(Redis) 모두 Git에
   저장하는 것이 원칙
2. **민감 정보 분리**: 비밀번호, 인증서 경로 등은 `.env` 파일이나 Vault에서 주입. Git에는 템플릿만 커밋
3. **변경 추적**: Git history로 "누가, 언제, 왜" 설정을 변경했는지 추적 가능. 장애 발생 시 최근 설정 변경 이력이 1차 원인 분석 대상

**꼬리질문 1**: "설정 파일 변경 후 실제 적용까지의 파이프라인은?"

**키포인트**:

1. 이상적 흐름: Git push → CI(lint/validate) → PR 리뷰 → Merge → CD(Ansible/ArgoCD) → 롤링 적용
2. 현실적 과제: Kafka/Redis는 Stateful이므로 ArgoCD 같은 GitOps로 직접 관리하기 어려움. Ansible이나 수동 적용이 현실적
3. 개선 방향: K8s Operator(Strimzi, Redis Operator)를 사용하면 CRD 기반 선언적 관리 → ArgoCD 연동 가능

**꼬리질문 2**: "1인 DevOps에서 이 모든 미들웨어의 설정 관리가 가능했던 이유는?"

**키포인트**:

1. **자동화 투자**: 초기에 Ansible playbook, 모니터링(Prometheus + Grafana) 등 자동화 인프라에 투자. 이후 반복 작업은 자동화로 처리
2. **표준화**: 모든 미들웨어의 설정 파일 구조, 네이밍, 모니터링 패턴을 통일. 예: JMX Exporter는 모두 :9102, Redis Exporter는 :9121
3. **문서화**: 운영 runbook 작성. 장애 시 판단 기준과 대응 절차를 문서화해두면 1인이어도 일관된 대응 가능

---

### [팀원5: 정유진 — CI/CD 엔지니어, 5년차]

> "Harbor는 이미지 공급 체인의 핵심이고, 미들웨어 자체의 배포 파이프라인도 중요하다. 어떻게 안전하게 변경을 배포하는지 본다."

#### Q1. Harbor에서 이미지 정리(Garbage Collection) 정책은 어떻게 운영하나요?

**의도**: 레지스트리 운영의 현실적 과제(스토리지 관리) 인식.

**키포인트**:

1. **Tag Retention Policy**: 프로젝트별로 "최근 N개 태그만 유지" 또는 "최근 N일 이내 태그만 유지" 정책 설정
2. **Garbage Collection**: Harbor의 GC는 두 단계 — (1) 참조되지 않는 blob 식별, (2) 실제 삭제. GC 중에는 push가 차단될 수 있으므로 트래픽이 적은 시간대에 스케줄링
3. **주의**: `latest` 태그만 사용하면 이전 이미지를 추적/롤백할 수 없음. **Semantic Versioning** 또는 **Git SHA 기반 태그**를 사용하고, 정책으로 오래된 태그를 자동 정리

**꼬리질문 1**: "Harbor가 다운되면 K8s 배포에 어떤 영향이 있나요?"

**키포인트**:

1. **이미 배포된 Pod**: 영향 없음. 컨테이너 이미지는 노드의 containerd 캐시에 존재
2. **새로운 Pod 생성/스케일링**: `ImagePullBackOff` 발생. 이미지를 pull할 수 없으므로 새 Pod가 뜨지 않음
3. **대응**: (1) Harbor HA 구성(Harbor Helm Chart의 `replicas` 설정), (2) 모든 워커 노드에 이미지 사전 pull(`imagePullPolicy: IfNotPresent`
   활용), (3) 각 노드에 이미지 캐시 유지 시간 설정(`imageGCHighThresholdPercent`)

**꼬리질문 2**: "CI 파이프라인에서 Harbor로 push할 때 인증은 어떻게 관리하나요?"

**키포인트**:

1. **Robot Account**: Harbor에서 프로젝트별 Robot Account 생성. 토큰 기반 인증으로 push/pull 권한 부여. 개인 계정이 아닌 서비스 계정 사용
2. **CI Secret 관리**: Robot Account 토큰을 CI 도구(Jenkins, GitLab CI 등)의 Secret/Credential에 저장. 코드에 직접 포함하지 않음
3. **토큰 로테이션**: Robot Account 토큰에 만료 기한 설정. 주기적 갱신으로 유출 시 영향 최소화

---

#### Q2. Kong Gateway의 Route/Plugin 설정 변경을 어떻게 배포하나요?

**의도**: API Gateway 설정의 CI/CD 파이프라인.

**키포인트**:

1. **decK(declarative Kong)**: Kong의 설정을 YAML 파일로 선언하고 `deck sync`로 적용. Git에 YAML을 저장하면 GitOps 패턴 구현
2. **Kong Admin API 직접 호출**: `curl`로 Route/Service/Plugin을 CRUD. 빠르지만 추적이 어려움
3. **Best Practice**: decK YAML을 Git에 저장 → PR 리뷰 → Merge → CI에서 `deck diff`(변경 사항 확인) → `deck sync`(적용). 이 흐름이면 설정 변경도
   코드 리뷰를 거침

**꼬리질문 1**: "Kong 플러그인 설정에 오류가 있어서 트래픽 장애가 발생하면 어떻게 롤백하나요?"

**키포인트**:

1. decK 사용 시: Git에서 이전 커밋으로 revert → `deck sync`로 이전 설정 복원. 수 분 내 롤백 가능
2. Admin API 사용 시: 문제 플러그인을 `PATCH`로 `enabled: false` 처리. 삭제가 아닌 비활성화로 빠르게 대응
3. **Canary 적용**: 특정 Consumer나 Route에만 플러그인을 먼저 적용하고, 문제 없으면 전체 확대. 한 번에 전체 적용은 위험

**꼬리질문 2**: "Kong 설정 변경이 무중단으로 적용되나요?"

**키포인트**:

1. Kong은 **DB-mode**(PostgreSQL)와 **DB-less mode**가 있음. DB-mode에서는 Admin API로 설정 변경 시 즉시 반영(핫 리로드). 재시작 불필요
2. DB-less mode에서는 설정 파일(`kong.yml`)을 reload해야 함. `kong reload` 명령으로 graceful reload 가능
3. **주의**: Kong의 declarative config(`deck sync`)는 DB를 직접 수정하므로 즉시 반영. 그러나 여러 Kong 인스턴스가 있으면 DB에서 설정을 읽어가는 캐시 주기(기본 5초)만큼
   지연 가능

---

#### Q3. Kafka Connect 커넥터의 배포/업데이트 프로세스는?

**의도**: Stateful 미들웨어의 변경 배포 경험.

**키포인트**:

1. **커넥터 설정 변경**: REST API `PUT /connectors/{name}/config`로 설정 업데이트. 커넥터가 자동으로 재시작됨
2. **커넥터 플러그인(JAR) 업데이트**: Connect Worker 재시작 필요. 새 JAR를 `plugin.path`에 배치 후 롤링 재시작
3. **주의**: Source 커넥터 재시작 시 offset이 보존되므로 중복/유실 없이 재개. 단, Sink 커넥터는 `auto.offset.reset` 설정에 따라 동작이 다를 수 있음

**꼬리질문 1**: "커넥터가 실패(FAILED) 상태에 빠지면 어떻게 복구하나요?"

**키포인트**:

1. `GET /connectors/{name}/status`로 상태 확인. Task 레벨에서 FAILED인 경우 `POST /connectors/{name}/tasks/{id}/restart`로 개별 Task
   재시작
2. 전체 커넥터 재시작: `POST /connectors/{name}/restart`
3. 근본 원인 분석: Connect Worker 로그에서 에러 확인. 일반적 원인은 (1) Source/Sink 시스템 연결 불가, (2) 스키마 변경, (3) 권한 부족

**꼬리질문 2**: "Connect에서 Dead Letter Queue(DLQ)를 사용하고 있나요?"

**키포인트**:

1. Sink 커넥터에서 `errors.tolerance=all` + `errors.deadletterqueue.topic.name=dlq-topic` 설정으로 처리 실패 메시지를 DLQ 토픽으로 전송
2. DLQ 없이 `errors.tolerance=none`(기본값)이면 하나의 불량 메시지가 전체 커넥터를 FAILED로 만듦
3. DLQ에 쌓인 메시지는 별도 Consumer로 분석/재처리. 원인 파악 후 수정된 메시지를 원래 토픽으로 재전송

---

### [팀원6: 한소윤 — EM(Engineering Manager), 10년차]

> "기술적 깊이도 중요하지만, 1인 DevOps로 이 규모의 미들웨어를 운영한 경험에서 얻은 교훈과 성장 가능성을 본다."

#### Q1. 이 미들웨어 스택을 혼자 운영하면서 가장 큰 장애 경험은?

**의도**: 장애 대응 능력과 사후 분석(Post-mortem) 문화.

**키포인트**:

1. **구체적 시나리오 제시**: "Kafka 브로커 1대의 디스크가 가득 찼을 때", "Redis Master가 OOM으로 죽었을 때", "Kong 설정 실수로 모든 API가 503을 반환했을 때" 등 실제 경험
   기반
2. **대응 과정**: (1) 감지(알림/사용자 보고), (2) 진단(로그/메트릭 확인), (3) 완화(임시 조치), (4) 해결(근본 원인 수정), (5) 재발 방지(모니터링 추가/설정 변경)
3. **교훈**: "이 장애 이후에 어떤 것을 바꿨다"가 핵심. 단순 "고쳤다"가 아니라 시스템적 개선(알림 추가, runbook 작성, 설정 변경 등)

**꼬리질문 1**: "1인 DevOps에서 On-call 체계는 어떻게 운영했나요?"

**키포인트**:

1. 1인이므로 24/7 On-call이 현실적으로 불가능. **알림 등급화**로 대응: Critical(즉시 대응), Warning(업무 시간 내 확인), Info(주간 리뷰)
2. Critical 알림만 PagerDuty/Slack 알림으로 설정하고, 나머지는 다음 날 확인
3. 한계 인정: 1인 체제의 가장 큰 리스크는 "사람의 SPOF". 팀 확장 시 가장 먼저 On-call 로테이션을 도입해야 함

**꼬리질문 2**: "장애 후 Post-mortem은 작성했나요? 어떤 형식으로?"

**키포인트**:

1. 구글 SRE 스타일의 Blameless Post-mortem: (1) 타임라인, (2) 근본 원인, (3) 영향 범위, (4) 대응 과정, (5) Action Items
2. Action Items에는 반드시 **담당자와 기한**을 명시. 1인이더라도 자기 자신에게 기한을 부여
3. Post-mortem 작성 자체가 중요한 것이 아니라, **Action Items의 실행률**이 핵심. 작성만 하고 실행하지 않으면 동일 장애 재발

---

#### Q2. 현재 아키텍처의 가장 큰 기술 부채(Tech Debt)는 무엇이라고 생각하나요?

**의도**: 자기 시스템의 한계를 객관적으로 평가할 수 있는 능력.

**키포인트**:

1. **Kafka Connect SPOF**: Source/Sink 각 1대. 한 대가 죽으면 해당 방향의 데이터 파이프라인 전체 중단
2. **Redis Master 단일 구성**: Write 확장 불가. Master 장애 시 failover 동안(~20초) write 불가
3. **수동 설정 관리**: Ansible 등 자동화가 부분적이거나 미적용이면 설정 drift 발생. 서버마다 미묘하게 다른 설정이 존재할 수 있음

**꼬리질문 1**: "이 기술 부채를 해결하기 위한 우선순위와 로드맵은?"

**키포인트**:

1. **P0(즉시)**: Kafka Connect 2대 이상 확장 → SPOF 제거. 비용 대비 효과가 가장 큼
2. **P1(3개월)**: 미들웨어 설정의 Git 관리 + Ansible 자동화 완성. 설정 drift 제거
3. **P2(6개월)**: Kafka/Redis의 K8s 마이그레이션 검토. Operator 기반 운영으로 자동화 수준 한 단계 향상

**꼬리질문 2**: "대기업으로 이직하면 이 경험이 어떻게 활용될 것 같나요?"

**키포인트**:

1. **End-to-end 이해**: 대기업에서는 역할이 세분화되지만, 전체 흐름(LB → Gateway → 메시지 큐 → 캐시 → 스토리지)을 경험한 사람은 드물다. 이 경험이 팀 간 소통과 장애 분석에서 큰
   강점
2. **스케일업 관점**: 1인이 운영 가능한 수준에서 설계했지만, 대규모로 확장할 때의 병목(write 확장, 파티션 분배, 메모리 관리)을 이미 인식하고 있음
3. **자동화 마인드셋**: 1인이었기 때문에 자동화하지 않으면 생존이 불가능했던 경험. 이 마인드셋이 대기업에서도 팀의 생산성 향상에 기여

---

#### Q3. 미들웨어 기술 선정 시 왜 이 조합(Kong + Kafka + Redis)을 선택했나요?

**의도**: 기술 선택의 근거와 대안 검토 능력.

**키포인트**:

1. **Kong**: NGINX 기반으로 성능이 검증되고, 플러그인 생태계가 풍부. 대안(Envoy, Traefik)과 비교 시, Admin API를 통한 동적 설정 변경이 강점. 폐쇄망에서도 플러그인만 설치하면
   확장 가능
2. **Kafka**: 높은 처리량(초당 수십만 메시지)과 내구성(disk 기반). 대안(RabbitMQ, Pulsar)과 비교 시, Kafka는 메시지 재소비(replay)가 가능하고 생태계(Connect,
   Streams)가 성숙. Consumer ON/OFF 패턴도 Kafka의 offset 기반 소비 모델이기에 가능
3. **Redis**: 단순 캐시를 넘어 세션 스토어, 분산 락 등 다용도. 대안(Memcached)과 비교 시, Redis는 데이터 구조(Hash, Set, Sorted Set)가 풍부하고
   Cluster/Persistence 지원

**꼬리질문 1**: "만약 다시 설계한다면 다르게 선택할 부분이 있나요?"

**키포인트**:

1. **Kafka → NATS/Pulsar**: 소규모 트래픽이라면 Kafka의 운영 복잡도가 과할 수 있음. NATS JetStream은 더 가볍고 K8s 친화적
2. **Kong → Envoy/Istio**: 이미 K8s를 사용하고 있다면 Service Mesh(Istio) 기반의 Envoy가 사이드카 패턴으로 더 자연스러울 수 있음
3. **Redis Cluster → Redis Sentinel**: Master 1대 + Replica 2대 구성에서 실제 샤딩을 하지 않으므로 Sentinel로도 충분했을 수 있음. Cluster의 복잡도가
   불필요했을 가능성

**꼬리질문 2**: "오픈소스 미들웨어의 버전 업그레이드 전략은?"

**키포인트**:

1. **보수적 접근**: Major 버전은 최소 1~2개 Minor 릴리스가 나온 후 적용. 초기 버전의 버그 리스크 회피
2. **Staging 환경 테스트**: 프로덕션과 동일한 구성의 Staging에서 새 버전을 먼저 운영. 1~2주 안정성 확인 후 프로덕션 적용
3. **롤백 계획**: 업그레이드 전 스냅샷/백업 필수. Kafka는 `inter.broker.protocol.version`으로 프로토콜 호환성 유지하며 점진적 업그레이드 가능

---

## 참고 자료

- [Kong Gateway 공식 문서 - Load Balancing](https://docs.konghq.com/gateway/latest/how-kong-works/load-balancing/)
- [Kong decK 공식 문서](https://docs.konghq.com/deck/latest/)
- [Apache Kafka 공식 문서 - Configuration](https://kafka.apache.org/documentation/#configuration)
- [Kafka Replication 설계](https://kafka.apache.org/documentation/#replication)
- [Redis Cluster Tutorial](https://redis.io/docs/management/scaling/)
- [Redis Persistence (AOF vs RDB)](https://redis.io/docs/management/persistence/)
- [Harbor 공식 문서](https://goharbor.io/docs/)
- [Strimzi Kafka Operator](https://strimzi.io/documentation/)
