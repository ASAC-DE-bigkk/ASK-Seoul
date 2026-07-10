# Ask Seoul LessonRun

작성일: 2026-06-29

## 오늘 작업 요약

- ASAC-DAG PR #11: 날씨 도메인 KMA `getVilageFcst` Bronze/raw 적재 DAG 추가
  - Issue: ASAC-DAG #9
  - Branch: `feat/9-kma-vilage-fcst-bronze`
  - File: `domains/weather/kma_vilage_fcst_bronze.py`
  - PR: https://github.com/ASAC-DE-bigkk/ASAC-DAG/pull/11
- ASAC-DAG PR #14: 교통 도메인 서울 TOPIS `AccInfo` 돌발정보 Bronze/raw 적재 DAG 추가
  - Issue: ASAC-DAG #13
  - Branch: `feat/13-seoul-traffic-incident-bronze`
  - File: `domains/traffic/seoul_traffic_incident_bronze.py`
  - PR: https://github.com/ASAC-DE-bigkk/ASAC-DAG/pull/14
- 두 PR 모두 DAG repo의 합의 구조인 `domains/<domain>/...` 아래에 DAG 파일을 배치했다.
- 교통 돌발정보는 dev target 기본 schedule을 매분(`* * * * *`) 실행으로 설정했다.
- prod target은 명시적인 `ASK_SEOUL_TRAFFIC_DAG_SCHEDULE` env가 없으면 자동 실행하지 않도록 유지했다.

## 개념 정리

### R2 raw object와 object key

R2는 S3 호환 object storage다. 파일 하나를 object라고 부르고, 그 object의 경로처럼 보이는 이름이 object key다.

예:

```text
bucket: seoul-dev
object_key:
bronze/weather_forecast/kma_vilage_fcst/load_date=2026-06-29/20260629T144613KST_base-202606291400_<request_id>.json
```

R2에 실제 폴더가 있는 것은 아니지만 `/`가 들어간 object key를 쓰면 콘솔에서는 폴더 구조처럼 보인다. 이 덕분에 domain/source/load_date 기준으로 원본을 찾기 쉽다.

### Raw와 Bronze의 차이

- Raw: API 응답 원본 JSON/XML을 R2에 그대로 저장한다.
- Bronze Iceberg table: 원본에서 row로 뽑은 값과 수집 metadata를 Parquet 기반 테이블로 저장한다.

Bronze metadata 예:

```text
request_id
source_id
request_params_json
http_status
result_code
result_msg
total_count / item_count / row_count
collected_at
load_date
payload_hash
raw_object_key
dag_run_id
```

`raw_object_key`는 Bronze row가 어떤 R2 원본 object에서 왔는지 추적하는 연결고리다.

### Trino, dbt, Iceberg의 역할

- Trino: SQL을 실제로 실행하는 query engine이다.
- dbt: SQL 모델을 컴파일하고 Trino에 실행 요청을 보내는 transformation 도구다.
- Iceberg: R2 위의 Parquet data file과 metadata를 테이블처럼 관리하는 table format이다.
- R2: raw object와 Iceberg data/metadata file이 저장되는 object storage다.

Bronze PR에서는 Airflow Python task가 Trino에 `CREATE TABLE`, `INSERT`, `SELECT` SQL을 직접 보낸다. Silver/Gold 단계에서는 Airflow가 `dbt run/test`를 실행하고, dbt가 모델 SQL을 Trino에 보낸다.

### Iceberg snapshot

Iceberg snapshot은 특정 시점의 테이블 상태다. INSERT가 일어나면 기존 파일을 직접 덮어쓰기보다 새 Parquet file과 새 metadata가 생기고, snapshot은 "현재 테이블은 어떤 data file들의 조합인가"를 기록한다.

JSON/XML raw object 자체가 바로 Iceberg table이 되는 것은 아니다. JSON/XML은 raw 보관용이고, 테이블로 조회하려면 파싱해서 Iceberg table row로 적재해야 한다.

### schema라는 말의 분리

- Trino schema: catalog 안 namespace. 예: `iceberg_dev.<dev_schema>`
- Bronze table schema: Iceberg table의 컬럼 구조
- dbt `schema.yml`: dbt model test/contract 정의
- raw payload schema: API JSON/XML 응답 구조

오늘 PR은 주로 Trino schema와 Bronze table schema를 다뤘다. dbt `schema.yml` contract는 Silver/Gold 작업 전에 별도 합의가 필요하다.

## 오늘 발생한 이슈와 Lesson Learned

### 1. GitHub 이슈/PR 본문 한글 깨짐

PowerShell pipe로 `gh issue create --body`를 넘기면서 한글이 `???`로 깨진 이슈가 있었다.

Lesson:

- 한글이 포함된 긴 GitHub issue/PR body는 UTF-8 파일을 만든 뒤 `--body-file`로 넘긴다.
- 생성/수정 후 `gh issue view` 또는 `gh pr view`로 `???` 패턴이 없는지 확인한다.

### 2. 공용 이슈 템플릿 prefix 임의 변경

Issue #9 제목을 `[Weather]`로 바꿨다가 공용 템플릿 prefix인 `[Ingest]`와 어긋났다.

Lesson:

- 이슈 제목은 공용 템플릿 규칙을 유지한다.
- 도메인은 제목 본문에 넣더라도 prefix는 `[Ingest]`로 맞춘다.

최종 제목:

```text
[Ingest] weather 도메인 원천 데이터 적재 (기상청 단기예보)
[Ingest] traffic 도메인 원천 데이터 적재 (서울 TOPIS 돌발정보)
```

### 3. PR 템플릿은 이슈 form처럼 YAML 선택형으로 만들 수 없음

GitHub issue는 YAML form을 지원하지만, PR은 issue form처럼 dropdown/input 검증을 지원하지 않는다. PR은 Markdown template을 사용한다.

Lesson:

- 이슈는 작업 성격별 form으로 나눈다.
- PR은 구현/검증/영향 공유용 공통 Markdown 템플릿 하나로 유지한다.

### 4. DAG repo 폴더 구조 합의

초기에는 DAG 파일을 repo root에 두었다가, 이후 도메인별 관리 구조로 합의했다.

최종 구조:

```text
dags/
  domains/
    weather/
      kma_vilage_fcst_bronze.py
    traffic/
      seoul_traffic_incident_bronze.py
```

Lesson:

- 각 도메인 작업자는 `domains/<domain>/` 아래에 본인 DAG 파일이나 하위 폴더를 둔다.
- 여러 도메인에서 공유하는 런타임 로직은 `dags/common/`에 두는 것이 맞다.
- sample repo의 `common/`은 통합 실행 환경 보조 도구용이고, 실제 Airflow DAG import 대상 공통 로직은 DAG repo 안에 있어야 한다.

### 5. AccInfo 갱신주기와 호출량

서울 TOPIS `AccInfo` 공식 문서에는 갱신주기가 분 단위로 명시되지 않고 `수시` 또는 `실시간`으로 표시된다.

현재 결정:

- dev target 기본 schedule: 매분 1회
- 정상 호출량: 1,440 calls/day
- Airflow retry 3회가 모두 발생하는 최악 호출량: 5,760 calls/day
- prod target: 명시적인 schedule env 없으면 자동 실행 안 함

Lesson:

- 돌발정보는 목표 feature에 중요한 변수라 dev coverage를 넓게 가져간다.
- 일일 최대 호출량은 공개 문서에서 숫자를 찾기 어렵고, 서울 열린데이터광장 인증키 관리 화면 또는 담당부서 확인이 필요하다.

### 6. submodule repo 경계

현재 작업 루트는 sample repo지만, `dags/`와 `dbt/`는 각각 별도 Git repo다.

Lesson:

- ASAC-DAG 변경은 `dags/` 안에서 branch/commit/push/PR을 만든다.
- ASAC-DBT 변경은 `dbt/` 안에서 별도 branch/commit/PR을 만든다.
- sample root는 통합 실행 환경과 submodule pointer/documentation을 관리한다.

## 다음에 이어서 할 일

- PR #14 실제 dev Airflow run 수행 후 PR 본문에 DAG run id, task 상태, row count를 추가한다.
- Silver/dbt 작업 전에 API별 schema contract와 dedup 기준을 합의한다.
- `dags/common/` 후보를 논의한다.
  - `required_env`
  - R2 env 선택
  - Trino cursor
  - SQL literal helpers
  - raw object key builder
- dbt 로컬 변경은 아직 별도 PR로 정리되지 않았다. Silver/Gold 계약 합의 후 진행한다.

## 2026-07-10 — dev Silver/Gold 복구 및 공통축 검증

- 실행 환경: `iceberg_dev` catalog만 사용했고, transform DAG의 paused 상태는 변경하지 않았다.
- 관련 이슈: ASAC-DBT #53, ASAC-DAG #167, #168.

### Weather (KMA 단기예보)

- native grid Silver를 보존하고, 대표점 격자 매핑을 이용한 행정동 grain `silver_weather_forecast_by_admin_dong`을 추가했다.
- Airflow 검증 run: `manual__2026-07-10T01:42:02.259216+00:00` — 성공.
- 최종 dev row count:
  - `silver_kma_vilage_fcst`: 4,137,240
  - `silver_weather_forecast_by_admin_dong`: 22,046,864
  - `gold_weather_forecast_by_place`: 1,331,386
- 행정동 Silver와 장소 Gold의 `admin_dong_code`, `gu_code`, `latitude`, `longitude` null 및 `event_at != forecast_at`는 모두 0건이다.
- 최신 Bronze 격자 중 행정동 파생 Silver에 더 늦게 들어오지 않은 14개 격자는 427개 행정동 대표점 매핑 범위 밖이었다. Grid Silver에는 Bronze 최신 `collected_at`까지 정상 반영됐다.

### Traffic (TOPIS 돌발정보)

- #55의 incremental merge 복구(임시 테이블 물질화 및 layered TM→WGS84 변환)가 dev에서 재현 없이 성공했다.
- Airflow 검증 run: `manual__2026-07-10T01:50:11.061806+00:00` — 성공.
- 최종 dev row count:
  - `silver_seoul_traffic_incident`: 838
  - `gold_traffic_incident_summary.row_count`: 838
- Silver의 `event_at != occurred_at`는 0건이고, Bronze와 Silver의 최대 `collected_at`는 모두 `2026-07-10 01:50:12 UTC`였다.
- 838건 중 8건은 WGS84 좌표는 있으나 행정동 boundary seed와 `ST_Intersects`하지 않아 `admin_dong_code`/`gu_code`가 NULL이다. 이는 현재 계약에서 boundary miss를 허용하고 coverage로 감시하는 경우이며, 자동 재활성화 전 팀이 fallback 정책(유지·nearest 매핑·boundary seed 보완)을 결정해야 한다.

### Lesson

- Silver test selector가 아직 생성하지 않은 Gold 교차 테스트를 포함하면 구조적으로 실패한다. Silver 단계에서 해당 Gold 테스트를 제외하고, Gold 재생성 후 Gold 단계에서 실행해야 한다.
- `DBT_PROJECT_DIR`와 `DBT_PROFILES_DIR`가 전역 `elt_smoke`로 설정된 런타임에서는 도메인 DAG가 두 값을 각 도메인 프로젝트로 명시해야 한다.
- commit/PR 및 paused DAG 재활성화는 검증 결과와 boundary miss 정책을 리뷰한 뒤 dev 기준으로 진행한다.
