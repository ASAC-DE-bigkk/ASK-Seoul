# Traffic/Weather lineage 검증 보강 설계

## 목표

Traffic/Weather 선택적 OpenLineage overlay가 의존하는 버전을 재현 가능하게 고정하고, global Trino lineage 부재와 Marquez 장애 시 dbt primary command exit status 보존을 실제 동작으로 검증한다.

## 결정

- Airflow image의 `apache-airflow-providers-openlineage`는 `2.19.0`, dbt venv의 `openlineage-dbt`는 `1.51.0`으로 exact pin한다.
- Compose JSON 문자열 검색에 의존하지 않고, 렌더된 `trino` service의 `/etc/trino` bind mount source를 추적해 모든 mounted file을 직접 검사한다.
- fail-open probe는 repo-local 최소 dbt project를 현재 `Dockerfile.airflow`로 재빌드한 `elt-infra-airflow:local` image에 read-only mount한다.
- probe는 dbt command보다 먼저 image 내부의 `apache-airflow-providers-openlineage==2.19.0`과 `openlineage-dbt==1.51.0` 실제 설치 버전을 격리된 Python command로 검사한다. 불일치하면 raw/wrapped command를 실행하지 않는다.
- probe는 `--network none`에서 raw `dbt compile`과 wrapped `dbt-ol compile`을 실행한다. wrapped 실행은 닫힌 `127.0.0.1:1` endpoint를 사용한다.
- 성공 판정은 raw/wrapped exit code 동일성과, 동일 structured log record 또는 bounded multiline exception block 안의 OpenLineage emission warning·닫힌 endpoint·실제 connection failure marker를 모두 요구한다.
- probe는 고정된 요약 값만 출력하고 container 원문 로그나 환경 값을 출력하지 않는다.
- 최종 ready 판정은 검증된 Traffic/Weather DAG/DBT commit을 root의 두 submodule gitlink가 가리키고, 그 상태에서 image rebuild와 actual probe를 통과한 뒤에만 가능하다.

## 안전 경계

- live Compose service를 stop/restart하지 않는다.
- Trino에 연결하거나 query/data write를 수행하지 않는다.
- `.env`, API key, token, password를 probe container에 전달하지 않는다.
- 기존 commerce Compose 기본 동작과 Traffic/Weather 외 domain 코드는 변경하지 않는다.

## 검증

- exact pin regression test
- mounted Trino config의 정상 상태 및 악성 fixture 탐지 test
- probe command isolation·판정 로직 unit test
- 전체 root unittest와 `docker compose ... config --no-env-resolution --quiet`
- 실제 Docker fail-open probe
