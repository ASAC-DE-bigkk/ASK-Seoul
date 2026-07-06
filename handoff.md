# Handoff - 2026-07-06

집에서 바로 이어받을 수 있게 오늘 작업한 DAG/DBT 상태와 다음 확인 순서를 정리한다.
secret 원문은 적지 않았고, `.env`/webhook/API key 값은 커밋하지 않았다.

## 오늘 기준 상태

- root repo branch: `workspace/mac-sync`
- ASAC-DAG local branch: `dev`
- ASAC-DAG 최신 commit: `83dc1f7 Merge pull request #164`
- ASAC-DBT local branch: `dev`
- ASAC-DBT 최신 commit: `fa978a7 Merge pull request #49`
- root repo에는 다른 미커밋 변경이 남아 있다. 오늘 handoff 공유 커밋은 `handoff.md`만 포함한다.

## 오늘 직접 처리한 핵심 작업

### 1. Iceberg metadata 유지보수 DAG

- Issue: https://github.com/ASAC-DE-bigkk/ASAC-DAG/issues/153
- PR: https://github.com/ASAC-DE-bigkk/ASAC-DAG/pull/155
- 상태: `MERGED`
- merge commit: `ee0b3e5`

변경 내용:

- weather/traffic bronze 테이블 대상으로 Iceberg 유지보수 DAG를 추가했다.
- 유지 대상:
  - `bronze_kma_vilage_fcst`
  - `bronze_seoul_traffic_incident`
  - `bronze_seoul_traffic_incident_request_audit`
  - `bronze_collection_run_manifest`
- 기능:
  - `optimize`
  - `expire_snapshots`
  - `remove_orphan_files`
- 기본 retention은 `7d`다.
- 목적은 이전에 자잘한 DML/commit 때문에 커진 Iceberg metadata를 주기적으로 정리하는 것이다.

검증:

- Airflow task test로 4개 테이블 유지보수 실행 확인.
- 실행 후 Iceberg metadata/history/snapshot/manifest/file 쪽 지표를 조회해 정리 효과를 확인했다.

### 2. raw_object_key 기반 Bronze-only backfill DAG

- Issue: https://github.com/ASAC-DE-bigkk/ASAC-DAG/issues/163
- PR: https://github.com/ASAC-DE-bigkk/ASAC-DAG/pull/164
- 상태: `MERGED`
- merge commit: `83dc1f7`

변경 내용:

- 새 DAG:
  - `weather_vilage_fcst_bronze_backfill`
  - `traffic_incident_bronze_backfill`
- API를 다시 호출하지 않고 R2 raw 원본 key만 받아 Bronze 적재를 다시 수행한다.
- 기존 `load_kma_bronze`, `load_seoul_traffic_bronze`, verify 로직을 재사용한다.
- schedule은 없다. 수동 실행 전용이다.

실행 conf 예시:

```json
{
  "raw_object_keys": [
    "raw/weather_forecast/kma_vilage_fcst/load_date=2026-07-05/nx=56/ny=130/20260705T082000KST_base-202607050800_request-id.json"
  ]
}
```

운영 방어선:

1. 같은 DAG run에서 `load_bronze` task만 재시도한다.
2. 그래도 안 되면 `raw_object_key` 기반 backfill DAG를 수동 실행한다.
3. raw 원본이 없거나 깨졌을 때만 API recollect DAG를 실행한다.

검증:

- `python -m compileall domains/weather/weather_vilage_fcst_bronze.py domains/traffic/traffic_incident_bronze.py`
- `python -m pytest domains/weather/tests/test_weather_kma_landing_checkpoint.py domains/traffic/tests/test_traffic_bronze_backfill.py -q` -> 7 passed
- `python -m pytest domains/weather/tests domains/traffic/tests -q` -> 55 passed

주의:

- 이번 PR branch를 실수로 `codex/163-...`로 만들었다.
- 다음부터 공용 규칙대로 `feat/<issue>-...` 또는 `fix/<issue>-...`로만 만든다.
- squash merge는 사용하지 않는다. 오늘 PR도 일반 merge commit으로 머지했다.

## 오늘 같이 확인한 팀 작업

### ASAC-DAG 공통 행정동 마스터

- Issue: https://github.com/ASAC-DE-bigkk/ASAC-DAG/issues/154
- PR: https://github.com/ASAC-DE-bigkk/ASAC-DAG/pull/159
- 추가 수정 PR: https://github.com/ASAC-DE-bigkk/ASAC-DAG/pull/160
- 상태: `MERGED`
- 최신 dev에 포함됨.
- `common_admin_dong_bronze` DAG가 추가됐고, 행정동 마스터 원천 수집이 들어갔다.

### ASAC-DBT 공통 시간/공간축

- Issue: https://github.com/ASAC-DE-bigkk/ASAC-DBT/issues/48
- PR: https://github.com/ASAC-DE-bigkk/ASAC-DBT/pull/49
- 상태: `MERGED`
- merge commit: `fa978a7`
- `packages/asac_axes`가 추가됐다.
- 공통 시간축/공간축 매크로, 행정동 dim/source/seed 구조가 들어갔다.

## 집에서 이어받는 순서

```bash
cd ask-seoul-sample
git fetch origin --prune
git switch workspace/mac-sync
git pull --ff-only origin workspace/mac-sync
```

DAG 최신화 확인:

```bash
cd dags
git switch dev
git pull --ff-only origin dev
git log --oneline -3
```

DBT 최신화 확인:

```bash
cd ../dbt
git switch dev
git pull --ff-only origin dev
git log --oneline -3
```

Airflow에서 확인할 DAG:

- `ask_seoul_iceberg_maintenance`
- `weather_vilage_fcst_bronze_backfill`
- `traffic_incident_bronze_backfill`
- 기존 정기 수집:
  - `weather_vilage_fcst_bronze`
  - `traffic_incident_bronze`

## 다음에 보면 좋은 것

- 실제 실패 run 하나를 기준으로 `raw_object_keys`를 뽑아 backfill DAG를 수동 실행해보기.
- Discord 리포트나 manifest 조회 결과에 backfill용 raw key 후보를 더 쉽게 보여줄지 결정하기.
- Iceberg metadata 비율이 다시 50%를 넘는지 며칠 더 모니터링하기.
- 브랜치 생성 전 반드시 이슈 번호와 prefix 확인하기: `feat/<issue>-...`, `fix/<issue>-...`.

---

# Handoff - 2026-07-03

회사에서 오늘 로컬/PR 작업 흐름을 빠르게 확인할 수 있게 정리한 공유용 문서입니다.
secret 원문은 적지 않았고, Discord webhook은 로컬 `.env`에만 둔 상태입니다.

## 작업 기준

- 작업 기준 branch: `dev`
- 대상 repo:
  - ASAC-DAG: `/Users/mason/Projects/asac-pr-work/sample/dags`
  - ASAC-DBT: `/Users/mason/Projects/asac-pr-work/sample/dbt`
  - 공유용 handoff 개인 repo: `/Users/mason/Projects/ask-seoul-sample-workspace`
- 목표 흐름:
  - API 호출
  - R2 raw 저장
  - Airflow task에서 Trino SQL로 Iceberg Bronze 적재
  - dbt로 Silver/Gold 변환
  - Discord 운영 알림은 env 기반으로만 동작

## dev 반영 완료 PR

### ASAC-DBT #36

- PR: https://github.com/ASAC-DE-bigkk/ASAC-DBT/pull/36
- 제목: `test(weather/traffic): Bronze metadata dbt 계약 강화`
- 상태: `MERGED`
- base: `dev`
- head: `codex/weather-traffic-dbt-metadata-contracts`
- merge 시각: 2026-07-03 00:52 KST
- dev 반영 commit: `919bf66 test(weather/traffic): strengthen dbt metadata contracts (#36)`
- 영향 범위:
  - `domains/weather/models/schema.yml`
  - `domains/weather/models/sources.yml`
  - `domains/weather/docs/dbt_contracts.md`
  - `domains/traffic/models/schema.yml`
  - `domains/traffic/models/sources.yml`
  - `domains/traffic/docs/dbt_contracts.md`
- 다른 도메인 파일 변경 없음

핵심 변경:

- Bronze source metadata 계약을 weather/traffic에 명시했습니다.
- `request_id`, `raw_object_key`, `payload_hash`, `dag_run_id`, source native id 계열 not-null/contract를 보강했습니다.
- Bronze 성공 실행만 Silver/Gold downstream에 반영한다는 기존 방향을 metadata contract 쪽에서 더 강하게 맞췄습니다.

### ASAC-DAG #97

- PR: https://github.com/ASAC-DE-bigkk/ASAC-DAG/pull/97
- 제목: `feat(weather/traffic): dbt transform DAG 추가`
- 상태: `MERGED`
- base: `dev`
- head: `codex/weather-traffic-transform-dags`
- merge 시각: 2026-07-03 00:52 KST
- dev 반영 commit: `4c08524 feat(weather/traffic): add dbt transform dags (#97)`
- 영향 범위:
  - `domains/weather/weather_vilage_fcst_transform.py`
  - `domains/traffic/traffic_incident_transform.py`
- 다른 도메인 파일 변경 없음

핵심 변경:

- weather/traffic 도메인 각각에 dbt transform DAG를 추가했습니다.
- task chain은 `dbt_run_silver -> dbt_test_silver -> dbt_run_gold -> dbt_test_gold`입니다.
- Bronze DAG와 Silver/Gold 변환 DAG를 분리해서, Bronze 수집 실패와 downstream 변환 실패를 독립적으로 볼 수 있게 했습니다.

### ASAC-DAG #98

- PR: https://github.com/ASAC-DE-bigkk/ASAC-DAG/pull/98
- 제목: `refactor(weather/traffic): raw landing과 Bronze 적재 task 분리`
- 상태: `MERGED`
- base: `dev`
- head: `codex/weather-traffic-bronze-task-split`
- merge 시각: 2026-07-03 00:53 KST
- dev 반영 commit: `baa3dea refactor(weather/traffic): split raw landing from bronze loading (#98)`
- 영향 범위:
  - `domains/weather/weather_vilage_fcst_bronze.py`
  - `domains/weather/weather_ingest/common/runtime.py`
  - `domains/traffic/traffic_incident_bronze.py`
  - `domains/traffic/traffic_ingest/common/runtime.py`
- 다른 도메인 파일 변경 없음

핵심 변경:

- weather Bronze DAG:
  - `record_kma_run_started -> land_kma_raw -> load_kma_bronze -> verify_kma_bronze_runtime`
- traffic Bronze DAG:
  - `record_seoul_traffic_run_started -> land_seoul_traffic_raw -> load_seoul_traffic_bronze -> verify_seoul_traffic_bronze_runtime`
- `land_*_raw`는 API 호출, 응답 성공 검증, R2 raw upload까지만 담당합니다.
- `load_*_bronze`는 R2 raw payload를 다시 읽어서 Trino/Iceberg Bronze insert만 담당합니다.
- Bronze insert task만 실패하면 API를 다시 호출하지 않고 `load_*_bronze`만 재시도할 수 있습니다.
- traffic pagination incomplete 검증은 raw landing 단계에서 먼저 실패시키고, load 단계에서도 R2 raw 재파싱 기준으로 한 번 더 확인합니다.

## 오늘 구조 판단

팀 논의 기준으로는 weather/traffic 수집 DAG를 별도 raw DAG와 bronze DAG로 나누는 것보다, 같은 DAG 안에서 task를 나누는 방식이 더 맞습니다.

이유:

- API 호출과 raw landing은 같은 수집 주기와 같은 실패 단위입니다.
- 평상시에는 raw가 성공했는데 bronze DAG가 언제 집어가느냐는 조율 문제를 만들 필요가 없습니다.
- 대신 `land_raw >> load_bronze >> verify_bronze`로 나누면, Bronze insert 실패 시 API 재호출 없이 load task만 재시도할 수 있습니다.
- raw만 남아 있고 Bronze만 다시 적재하는 backfill 요구가 커지면 그때 별도 DAG나 parameterized recollect/backfill DAG를 추가하는 편이 낫습니다.

Silver/Gold 변환은 별도 transform DAG로 두는 게 맞습니다.

- Bronze는 외부 API/R2/Trino ingest 책임입니다.
- Silver/Gold는 dbt model run/test 책임입니다.
- Bronze 성공 기준이 manifest/publishable gate로 잡히면 transform DAG는 성공한 Bronze run만 읽도록 제어할 수 있습니다.
- 오늘 DBT dev에는 이미 Bronze publishable gate 쪽 commit도 반영되어 있습니다.

## 검증 기록

PR 생성 전 검증:

- DAG domain tests:
  - `python3 -m pytest domains/weather/tests domains/traffic/tests`
  - 결과: 27 passed
- DAG compile:
  - Bronze split 변경 파일 compile 통과
  - transform DAG 파일 compile 통과
- Docker Airflow import smoke:
  - `weather_vilage_fcst_bronze`: `record_kma_run_started`, `land_kma_raw`, `load_kma_bronze`, `verify_kma_bronze_runtime`
  - `traffic_incident_bronze`: `record_seoul_traffic_run_started`, `land_seoul_traffic_raw`, `load_seoul_traffic_bronze`, `verify_seoul_traffic_bronze_runtime`
  - `weather_vilage_fcst_transform`: `dbt_run_silver`, `dbt_test_silver`, `dbt_run_gold`, `dbt_test_gold`
  - `traffic_incident_transform`: `dbt_run_silver`, `dbt_test_silver`, `dbt_run_gold`, `dbt_test_gold`
- DBT:
  - weather/traffic `dbt parse`는 Docker runtime 기준으로 확인
  - YAML contract 파일 parse 확인
- secret check:
  - 작업 코드에 Discord webhook URL 원문 추가 없음

merge 후 dev 기준 재확인:

- ASAC-DAG `dev`:
  - `python3 -m pytest domains/weather/tests domains/traffic/tests`
  - 결과: 27 passed
  - `python3 -m compileall` 변경/new DAG 파일 통과
- ASAC-DBT `dev`:
  - weather/traffic `schema.yml`, `sources.yml` 4개 YAML parse 통과

## 브랜치 정리

remote branch는 PR merge 시 삭제했습니다.

- ASAC-DBT:
  - `codex/weather-traffic-dbt-metadata-contracts`
- ASAC-DAG:
  - `codex/weather-traffic-transform-dags`
  - `codex/weather-traffic-bronze-task-split`

local branch도 삭제했습니다.

- ASAC-DBT는 `dev...origin/dev` clean
- ASAC-DAG는 `dev...origin/dev` clean

참고:

- `/Users/mason/Projects/asac-pr-work/sample` root repo는 submodule pointer가 최신 dev commit으로 이동해서 `dags`, `dbt`가 modified로 보입니다.
- 이번 요청은 submodule PR merge와 개인 handoff 공유까지라 root sample pointer commit은 만들지 않았습니다.

## Discord 알림 관련

- webhook URL은 repo에 커밋하지 않았습니다.
- 로컬 `.env`에만 둔 상태입니다.
- weather/traffic Bronze DAG의 성공/실패 알림은 각 도메인 DAG 안에 유지했습니다.
- transform DAG는 dbt run/test 책임만 추가했고, 별도 Discord 전송 로직은 넣지 않았습니다.
- 아침 9시 종합 리포트형 알림은 별도 report DAG가 필요합니다. 오늘 merge한 #97 transform DAG는 Silver/Gold 변환용이며, 09:00 요약 리포트 DAG는 아닙니다.

## 회사에서 확인할 것

1. ASAC-DAG `dev` 최신화:
   - `git fetch origin --prune`
   - `git switch dev`
   - `git pull --ff-only origin dev`
2. ASAC-DBT `dev` 최신화:
   - `git fetch origin --prune`
   - `git switch dev`
   - `git pull --ff-only origin dev`
3. Airflow UI에서 task chain 확인:
   - `weather_vilage_fcst_bronze`
   - `traffic_incident_bronze`
   - `weather_vilage_fcst_transform`
   - `traffic_incident_transform`
4. 실제 Trino/R2 연결 환경에서 확인:
   - Bronze DAG 수동 실행
   - Bronze success manifest/publishable 상태 확인
   - transform DAG 수동 실행
   - Silver/Gold row count 및 dbt tests 확인

## 남은 개선 후보

- 09:00 KST Discord 종합 리포트 DAG를 org PR로 다시 설계할지 결정
- weather/traffic transform DAG schedule을 Bronze 완료 이벤트 기반으로 묶을지, cron offset으로 둘지 팀 합의
- 공통 HTTP client / 공통 error module이 확정되면 weather/traffic fetch runtime을 공통 모듈로 이동
- dbt shared generic test는 3개 이상 도메인에서 반복 패턴이 확인되면 별도 package/macro로 승격
