# Traffic/Weather Trino·Marquez 운영 hotfix 설계

- 상태: 사용자 검토 요청
- 기준 이슈: [ASK-Seoul #38](https://github.com/ASAC-DE-bigkk/ASK-Seoul/issues/38)
- 기준 branch: `fix/38-trino-openlineage-starvation`
- 대상 환경: local dev smoke runtime
- 관련 이슈: [ASAC-DAG #426](https://github.com/ASAC-DE-bigkk/ASAC-DAG/issues/426), [ASAC-DBT #257](https://github.com/ASAC-DE-bigkk/ASAC-DBT/issues/257)

## 1. 결론

Marquez를 제거하거나 OpenLineage를 상시 비활성화하지 않는다. Marquez는 이 프로젝트가 채택한 local dev lineage backend로 유지하고, base Airflow emitter와 backend의 수명주기를 같은 배포 단위로 묶는다.

Trino 처리량은 한 번에 모든 잠금을 풀지 않는다. 다음 두 경계를 분리한다.

1. Airflow scheduling 경계: Traffic 전용 1 lane과 Weather 전용 1 lane을 둬 한 도메인의 연속 작업이 다른 도메인을 starvation시키지 못하게 한다.
2. Trino engine 경계: `hardConcurrencyLimit=2`는 query memory 예산을 낮춘 canary로만 열고, 실패 시 Airflow lane은 유지한 채 엔진만 즉시 1로 되돌린다.

이 구조는 Traffic Gold exact-set fence와 Weather의 동일 relation 임시 table 충돌 방지 의도를 유지하면서, 전체 시스템에는 최대 두 개의 독립 도메인 작업 진입로를 제공한다.

## 2. 기존 의도와 이번 결정

### 2.1 OOM 보호 의도

root commit `054fe0c`는 실제 OS OOM 이후 아래 보호 장치를 하나의 세트로 도입했다.

- Trino container memory limit 9 GiB
- JVM `MaxRAMPercentage=55`로 약 4.95 GiB heap 상한
- query user memory 2 GiB, heap headroom 2 GiB
- resource group `hardConcurrencyLimit=1`
- Airflow `trino_heavy=1`

이번 변경은 이 보호 세트를 단순히 숫자 2로 치환하지 않는다. query cap, dbt threads, Airflow fairness, exact-set fence, rollback을 함께 설계한다. `query.low-memory-killer.policy=none`과 spill 정책은 기존 commerce OOM 대응 의도를 유지하며 이번 hotfix에서 바꾸지 않는다.

### 2.2 lineage 의도

기존 root #25는 Marquez 미기동 시에도 task 자체는 실패시키지 않는 fail-open emitter와 Traffic/Weather opt-in overlay를 도입했다. 다만 base compose에는 transport가 항상 있고 Marquez는 `lineage` profile 뒤에 있어, backend 없이 emitter만 켜지는 유효하지 않은 조합이 가능했다.

2026-07-18 사용자 결정에 따라 Marquez 채택을 유지한다. fail-open은 일시적인 backend 장애가 business task를 실패시키지 않는 런타임 정책으로만 남긴다. 정상 dev 배포가 backend 자체를 누락해도 된다는 뜻으로 해석하지 않는다.

## 3. 장애 증거

### 3.1 Weather starvation

- `trino_heavy=1`을 Traffic Bronze와 Traffic transform이 연속 점유했다.
- Weather transform run은 `dbt_test_gold`에서 1시간 42분 이상 `scheduled`로 대기했다.
- 해당 run은 최종적으로 2시간 28분 대기 후, 재배포 사이에 run-local `dbt_packages`가 사라져 실패했다.
- 대체 Weather run은 shared slot을 확보한 뒤 27분 08초에 성공했다.

즉 Weather의 장시간 wall time은 SQL 실행만의 문제가 아니라 shared Airflow pool 대기와 package artifact lifetime이 결합된 결과다.

### 3.2 Marquez 연결 불능

2026-07-18 live runtime에서 확인한 상태는 다음과 같다.

- Airflow scheduler env에는 `http://marquez-api:5000/api/v1/lineage` transport가 존재했다.
- `marquez-db`, `marquez-api`, `marquez-web`은 모두 2026-07-17 05:05:17 UTC에 함께 `ExitCode=255`로 종료돼 있었다.
- 세 컨테이너 모두 `OOMKilled=false`였고, 종료 직전 API는 lineage POST에 `201`을 반환했다.
- 오늘 Airflow는 revision-locked dev harness의 base compose + generated override로 재배포됐고, `lineage` profile 및 Traffic/Weather overlay는 포함되지 않았다.
- scheduler와 stopped `marquez-api`는 같은 `elt_net`에 속했지만 stopped container에는 IP가 없어 `marquez-api` DNS가 해석되지 않았다.

따라서 원인은 Marquez 자체 장애가 아니라 emitter/backend lifecycle 불일치다.

### 3.3 즉시 복구 결과

실행 중인 Airflow와 Trino를 재생성하지 않고 Marquez 세 서비스만 같은 compose project에 다시 기동했다.

- `marquez-db`: healthy
- `marquez-api`: running
- `marquez-web`: running
- scheduler 내부 `marquez-api` DNS: 정상
- host API `/api/v1/namespaces`: HTTP 200
- 실제 OpenLineage POST: HTTP 201
- 보존된 namespace: `ask-seoul-dev-airflow`, `ask-seoul-dev-dbt`, `commerce-elt`, `trino://trino:8080`

복구 직후 관측 memory는 DB 약 54 MiB, API 약 328 MiB, Web 약 22 MiB로 합계 약 0.4 GiB였다. 이 값은 Trino concurrency canary의 host memory 예산에 포함한다.

현재 Marquez API에는 container memory limit이 없고 JVM ergonomic `MaxHeapSize`가 약 4.15 GB로 확인됐다. 현재 RSS만 보고 무제한으로 두면 Trino 9 GiB cap과 합산한 host OOM 위험이 남는다. always-on 전환과 동시에 lineage 서비스에도 독립된 memory budget을 둔다.

Marquez API의 `OpenSearch not available` 오류는 수집 API 실패와 분리한다. 현재 image의 `marquez.dev.yml`은 `SEARCH_ENABLED` 기본값이 true라 optional search index를 찾지만, metadata POST와 PostgreSQL 저장은 201로 성공한다. hotfix에서는 메모리 사용량이 큰 OpenSearch를 추가하지 않고 `SEARCH_ENABLED=false`를 명시한다. lineage graph와 PostgreSQL metadata가 우선이며 keyword search는 별도 용량 설계 뒤 활성화한다.

## 4. 목표 구조

```text
revision-locked dev deploy
  ├─ core: Postgres, Trino, Airflow
  ├─ lineage: Marquez DB/API/Web (항상 기동, restart 정책)
  ├─ Traffic/Weather lineage overlay (항상 병합)
  └─ generated exact-ref mount override

Airflow scheduling
  ├─ trino_traffic_heavy: 1 slot
  │    └─ Traffic Bronze / resolver / Silver / Gold / recovery
  └─ trino_weather_heavy: 1 slot
       └─ Weather Bronze / transform / recovery / smoke

Trino resource group
  ├─ stage 1: hardConcurrencyLimit=1
  └─ stage 2 canary: hardConcurrencyLimit=2
```

## 5. Marquez lifecycle 설계

### 5.1 항상 유효한 compose 조합

base compose의 Airflow transport가 유지되는 동안 Marquez 서비스를 optional profile로 남기지 않는다. 다음을 한 변경 단위로 적용한다.

- `marquez-db`, `marquez-api`, `marquez-web`의 `profiles: ["lineage"]` 제거
- 세 서비스에 `restart: unless-stopped` 적용
- `marquez-api`에 admin port `5001/healthcheck` 기반 healthcheck 추가
- `marquez-api`에 `SEARCH_ENABLED: "false"` 명시
- `marquez-api`: `mem_limit=1536m`, `JAVA_OPTS`의 `MaxRAMPercentage=50`로 heap 약 768 MiB 상한
- `marquez-db`: `mem_limit=512m`
- `marquez-web`: `mem_limit=256m`
- 기존 localhost-only API/UI port binding 유지
- secret은 기존 `.env` 주입 계약을 유지하고 compose/config/log 검증에서 출력하지 않음

base `docker compose up -d --build --wait`만 실행해도 emitter와 backend가 함께 존재해야 한다.

Marquez 합산 memory budget은 최대 2.25 GiB다. 이 값은 서비스별 RSS 합계가 아니라 hard container cap 합계이며, API 201 처리량과 PostgreSQL checkpoint가 cap 안에서 유지되는지 dev load로 검증한다. cap 초과로 Marquez가 재시작해도 data task fail-open은 유지하되 deployment/canary는 실패로 판정한다.

### 5.2 Traffic/Weather model lineage

revision-locked dev harness는 compose 파일을 다음 순서로 병합한다.

1. `docker-compose.yml`
2. `docker-compose.traffic-weather-lineage.yml`
3. generated exact-ref mount override

구현 seam은 `scripts/lib/DevDeployHarness.psm1`의 `Invoke-DevDockerCompose`다. 현재 base와 generated override만 조합하는 `$composeArgs`에 repo-local Traffic/Weather lineage overlay를 generated override보다 먼저 추가한다. 모든 `config`, `up`, `ps`, `exec`, mount 검증이 같은 compose file set을 사용해야 하므로 `deploy-dev.ps1`에서 별도 one-off compose command를 만들지 않는다.

deployment lock에는 `lineage_overlay_path`와 해당 tracked file의 git blob/SHA-256 fingerprint를 기록한다. `-WhatIf` 출력도 overlay 경로를 보여 주되 env 값은 출력하지 않는다. 실행 중인 container의 Compose labels가 base + lineage overlay + generated override를 가리키지 않으면 verification을 실패시킨다.

Traffic/Weather overlay는 다음 역할만 가진다.

- Airflow namespace를 `ask-seoul-dev-airflow`로 설정
- `AIRFLOW__OPENLINEAGE__SELECTIVE_ENABLE=true`
- Traffic/Weather DAG opt-in adapter 활성화
- `ASK_SEOUL_DBT_OPENLINEAGE_ENABLED=true`
- dbt materialization phase를 `dbt-ol`로 실행해 model relation lineage 전송

generated mount override는 lineage 설정을 덮어쓰지 않는다. dev harness의 compose config test가 병합 결과를 검증한다.

`scripts/verify-dev-deploy.ps1`은 기존 exact-ref mount 검증 뒤 다음을 추가한다.

1. `marquez-db`, `marquez-api`, `marquez-web` container 존재와 running/healthy 상태
2. scheduler 내부 `getent hosts marquez-api`
3. Marquez admin `/healthcheck` HTTP 200과 metadata API HTTP 200
4. scheduler의 OpenLineage transport/namespace 및 Traffic/Weather selective/dbt enable key 존재
5. `airflow pools get` 또는 pools list를 통한 Traffic/Weather 1-slot 확인
6. Marquez restart count와 container memory limit 확인

secret 값은 출력하지 않는다. transport URL과 namespace는 repo에 고정된 non-secret 기대값과 boolean equality로만 검증하고, 전체 container env dump를 verification artifact로 남기지 않는다.

### 5.3 fail-open과 배포 실패의 구분

- 실행 중 Marquez의 짧은 장애: OpenLineage 전송 warning을 남기되 data task exit code는 보존한다.
- 배포 시 Marquez 누락 또는 healthcheck 실패: `deploy-dev.ps1`/`verify-dev-deploy.ps1`가 실패한다.
- API가 201을 반환하지만 optional search만 실패: deployment health는 성공으로 보되 명시적 warning metric으로 기록한다.

## 6. Airflow pool 설계

### 6.1 단일 2-slot pool을 채택하지 않는 이유

현재 Traffic Gold fence는 Gold run/test 사이에 Traffic Bronze write가 들어오지 않는다는 1-slot invariant에 의존한다. `trino_heavy=2`만 적용하면 높은 priority의 Gold test가 한 slot을 잡는 동안 Bronze가 다른 slot에서 실행될 수 있어 exact reconciliation이 다시 깨진다.

Weather W2 recovery도 normal Weather writer와 같은 1-slot pool을 사용해 고정 `__dbt_tmp` relation 충돌을 막는다. 따라서 동일 pool의 slot 수만 2로 올리면 두 도메인 모두 숨은 correctness invariant를 잃는다.

### 6.2 두 개의 domain lane

Traffic과 Weather의 resource adapter가 서로 다른 pool 이름을 제공한다.

| Pool | Slot | 소유 task | 보존되는 invariant |
| --- | ---: | --- | --- |
| `trino_traffic_heavy` | 1 | Traffic Bronze, resolver, transform, recovery | Gold exact-set fence, Traffic write 직렬화 |
| `trino_weather_heavy` | 1 | Weather Bronze, transform, W1/W2 smoke/recovery | Weather 임시 relation write 직렬화 |

`dbt_deps`는 Trino query를 실행하지 않으므로 두 heavy pool 모두 사용하지 않는다.

root `airflow-init`은 재실행 가능하게 다음 pool을 `airflow pools set`으로 upsert한다.

- `trino_traffic_heavy 1 "Serialize Traffic Trino writes and exact tests"`
- `trino_weather_heavy 1 "Serialize Weather Trino writes and recovery"`
- legacy `trino_heavy 1`은 inventory가 끝날 때까지 유지

이 구조에서 Traffic가 5분 Bronze backlog를 연속 처리해도 Weather lane을 점유할 수 없다. Weather task가 1시간 이상 `scheduled`로 굶는 현재 증상을 Airflow scheduler 단계에서 제거한다.

### 6.3 `trino_heavy` 호환성

다른 도메인이 기존 `trino_heavy`를 사용할 가능성을 위해 root pool을 즉시 삭제하지 않는다. Traffic/Weather가 새 lane으로 이관된 뒤 사용자를 inventory하고, 미사용이 확인된 후 별도 cleanup issue에서 제거한다.

## 7. Trino hard concurrency canary

### 7.1 단계적 활성화

#### Stage 1 — scheduler fairness 검증

- `trino_traffic_heavy=1`, `trino_weather_heavy=1`
- Trino `hardConcurrencyLimit=1` 유지
- dbt materialization `--threads 2`
- Traffic Gold fence와 Weather starvation 개선을 먼저 검증

이 단계에서는 두 Airflow task가 동시에 running일 수 있지만 Trino는 query를 한 번에 하나만 실행한다. SQL 동시 실행을 늘리지 않고 scheduler 대기 문제와 resource adapter 변경을 먼저 검증한다.

#### Stage 2 — engine concurrency 2 canary

- `hardConcurrencyLimit=2`
- `query.max-memory-per-node=1280MB`
- `query.max-memory=1280MB`
- `query.max-total-memory=2560MB`
- heap headroom 2GB, container 9GiB, JVM heap 비율 55%, task concurrency 2 유지
- dbt `--threads 2` 유지

두 query의 user memory 상한 합계 약 2.5 GiB와 2 GiB headroom을 약 4.95 GiB heap 아래에 둔다. 이 계산은 보장값이 아니라 canary 진입 조건이며, system/revocable memory와 native memory는 runtime 관측으로 판정한다.

### 7.2 canary workload

다음 조합을 dev schema에서 최소 세 cycle 관찰한다.

1. Traffic Incident 또는 Flow Bronze materialization
2. Traffic transform의 resolver/Silver/Gold
3. Weather transform 또는 Weather Bronze
4. Marquez lineage event 수집

관측 항목은 Trino container memory, restart count, JVM/Trino OOM log, query queue/run 수, Airflow pool wait, Weather scheduled wait, Traffic Gold reconciliation, dbt phase wall time이다.

### 7.3 즉시 중단 기준

다음 중 하나면 Stage 2를 중단하고 engine hard concurrency만 1로 되돌린다.

- Trino restart count 또는 `OOMKilled` 증가
- `OutOfMemoryError`, `Killed`, `EXCEEDED_LOCAL_MEMORY_LIMIT`, cluster OOM 발생
- Trino container memory가 8.0 GiB 이상으로 2회 연속 관측
- Traffic Gold exact reconciliation 실패 또는 Bronze interleave 확인
- Iceberg write conflict나 중복 key 발생
- runnable Weather task가 새 Weather lane에서도 15분 이상 `scheduled` 대기
- resolver batch hotfix 뒤에도 Traffic transform이 30분을 초과

Airflow의 두 domain lane은 rollback하지 않는다. engine을 1로 되돌리면 Trino가 query를 직렬 queueing하면서도 Weather task는 Traffic 때문에 Airflow `scheduled`에 묶이지 않는다.

## 8. 검증

### 8.1 정적 검증

- base compose에서 Marquez 세 서비스가 profile 없이 포함됨
- 세 서비스 `restart: unless-stopped`
- API healthcheck와 `SEARCH_ENABLED=false`
- Marquez API/DB/Web memory cap과 API JVM heap 비율
- dev harness compose 병합 순서에 Traffic/Weather lineage overlay 포함
- generated override가 lineage env를 제거하지 않음
- deployment lock/WhatIf/Compose label이 동일한 3-file compose set을 증명
- `trino_traffic_heavy=1`, `trino_weather_heavy=1` bootstrap
- Stage 1 hard=1 fixture와 Stage 2 hard=2/memory budget fixture
- 기존 OpenLineage fail-open probe 유지
- `.env`/secret 값 비출력 검증 유지

### 8.2 runtime 검증

- Marquez DB healthy, API healthcheck 200, event POST 201
- Marquez 세 서비스 restart count와 memory cap 준수
- Airflow scheduler에서 `marquez-api` DNS 해석
- Marquez UI `http://127.0.0.1:3000` 접근
- namespace `ask-seoul-dev-airflow`, `ask-seoul-dev-dbt`에 새 run 반영
- `verify-dev-deploy.ps1`가 Marquez/DNS/overlay env/domain pool 누락을 실패로 판정
- Traffic/Weather DAG 이외 selective-disabled DAG의 의도치 않은 opt-in 없음
- Traffic와 Weather task가 각 domain lane에서 동시에 running 가능
- Stage 1/2별 query running count와 memory 기록

## 9. 롤백

1. `traffic_incident_transform`을 pause한다.
2. Trino resource group을 `hardConcurrencyLimit=1`로 되돌리고 Trino만 재시작한다.
3. query memory cap은 기존 2GB/4GB 값으로 복구하거나, 실패 원인이 query cap이 아니면 보수적인 1280MB 값을 유지한다.
4. Traffic/Weather domain lane은 유지한다.
5. Bronze와 Weather drain, Trino health, Gold exact test를 확인한 뒤 transform을 재개한다.

Marquez는 Trino concurrency rollback 대상이 아니다. lineage backend 장애가 별도로 발생하면 Marquez 세 서비스만 재기동하고 data task fail-open 계약을 유지한다.

## 10. 완료 조건

- normal dev deploy가 Marquez를 누락할 수 없다.
- Traffic/Weather Airflow 및 dbt model lineage가 각각 올바른 namespace에 수집된다.
- optional OpenSearch 부재가 매 event ERROR를 만들지 않는다.
- Traffic 연속 작업 중 Weather가 shared pool 때문에 15분 이상 `scheduled`로 남지 않는다.
- Traffic Gold exact-set reconciliation과 Weather writer 직렬화가 유지된다.
- hard concurrency 2 canary가 세 cycle을 통과하거나, 실패 시 engine 1 rollback 증거가 기록된다.
- 실행 결과에는 DAG run id, task 상태·시간, row count, 생성 object/table, Trino memory/restart, Marquez POST 상태를 `LessonRun.md`에 남긴다.

## 11. 범위 밖

- production Marquez 인증·TLS·외부 DB 전환
- OpenSearch 도입
- Trino worker 분리 또는 cluster 확장
- `query.low-memory-killer.policy` 변경
- Traffic/Weather 이외 도메인의 pool 재설계
- prod bucket/schema 실행
