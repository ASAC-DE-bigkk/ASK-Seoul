# origin/dev revision-locked 로컬 Airflow deploy harness 설계

## 목적

ASAC-DAG와 ASAC-DBT의 `dev` 병합본을 로컬 Airflow에 배포할 때, 컨테이너가 정확히 같은 revision을 mount했음을 기계적으로 보장한다. root checkout의 dirty 상태, submodule pointer, 수동 compose override는 배포 대상으로 사용하지 않는다.

## 범위

- 입력은 첫 버전에서 고정된 `origin/dev`뿐이다. branch, SHA, feature ref 인자는 받지 않는다.
- 대상은 `dags/`와 `dbt/` submodule, Airflow의 `airflow-init`, `airflow-apiserver`, `airflow-scheduler`, `airflow-dag-processor`, `airflow-triggerer` service다.
- harness는 clean runtime worktree, generated compose override, deployment lock, 런타임 검증을 소유한다.
- feature branch 검증, CI/release image bake, prod 배포, root submodule pointer 갱신은 이번 범위에서 제외한다.

## 핵심 interface

```powershell
./scripts/deploy-dev.ps1
./scripts/verify-dev-deploy.ps1
```

두 명령은 인자를 받지 않는다. `deploy-dev.ps1`은 runtime worktree를 refresh하고, lock과 compose override를 생성한 뒤 compose를 기동하고 `verify-dev-deploy.ps1`를 호출한다. `verify-dev-deploy.ps1`는 이미 기록된 lock을 단일 진실원으로 사용해 배포된 컨테이너를 검사한다.

## module과 seam

`scripts/lib/DevDeployHarness.psm1`이 deep module이다. 호출자는 두 public command만 알면 되고, Git worktree 준비, YAML 생성, Docker compose·inspect 호출, JSON lock 검증의 implementation은 모두 module 안에 둔다.

외부 seam은 실제 Git/Docker process 실행이다. 첫 버전에서 adapter는 production process adapter 하나만 둔다. Pester test는 process 실행 함수를 module 내부 seam으로 mock하여 filesystem과 Docker daemon 없이 interface를 검증한다.

## runtime layout

```text
<root>/.runtime/dev/
  dags/                         # ASAC-DAG origin/dev detached worktree
  dbt/                          # ASAC-DBT origin/dev detached worktree
  docker-compose.generated.yml  # 모든 Airflow service의 bind mount override
  deployment-lock.json          # requested/resolved SHA와 mount 증거
  deploy.lock                   # 동시 실행 방지용 일시 lock
```

`.runtime/`은 Git 추적 대상이 아니다. harness는 root `dags/`와 `dbt/`를 fetch source로만 사용하며 checkout, reset, merge, clean을 실행하지 않는다. submodule이 없거나 `origin` remote이 없으면 명시적으로 실패한다.

## deployment lock 계약

`deployment-lock.json`은 다음 필드를 포함한다.

```json
{
  "schema_version": 1,
  "requested_ref": "origin/dev",
  "generated_at_utc": "2026-07-16T00:00:00Z",
  "dags": { "sha": "<40-char SHA>", "worktree_path": "<absolute path>" },
  "dbt": { "sha": "<40-char SHA>", "worktree_path": "<absolute path>" },
  "compose_override_path": "<absolute path>",
  "required_dbt_project": "/opt/airflow/dbt/domains/traffic_weather/dbt_project.yml"
}
```

lock은 compose 실행 전 write하고, runtime 검증은 lock 이외의 revision 값을 허용하지 않는다. lock write는 임시 파일 후 atomic rename으로 수행한다.

## generated compose override 계약

override는 5개 Airflow service 각각에 `!override` volumes를 선언한다. DAG source는 lock의 `dags.worktree_path`에서 `/opt/airflow/dags:ro`로, DBT source는 lock의 `dbt.worktree_path`에서 `/opt/airflow/dbt`로 bind mount한다. 각 service의 `airflow_logs` volume도 유지한다.

사용자가 `docker compose`를 직접 실행해 기본 compose만 적용하는 것은 harness의 지원 경로가 아니다. `deploy-dev.ps1`은 generated override 없이 compose를 호출하지 않는다.

## 실패 조건

다음 조건 중 하나라도 발생하면 즉시 non-zero exit로 실패하고 compose 기동 성공을 보고하지 않는다.

- runtime worktree HEAD가 fetched `origin/dev` SHA와 다름
- runtime worktree에 tracked/untracked 변경이 있음
- generated compose config가 유효하지 않음
- Docker inspect의 5개 service mount source가 lock의 absolute path와 다름
- container 내부 `git -C /opt/airflow/dags rev-parse HEAD` 또는 DBT HEAD가 lock SHA와 다름
- required dbt project file이 없음
- scheduler/apiserver health가 healthy가 아님

secret, `.env` 값, Docker environment 값은 lock·로그·오류에 기록하지 않는다.

## 성공 조건과 증거

성공한 deploy는 requested/resolved SHA, generated override path, service별 mount 검증, container HEAD 검증, dbt project 존재, compose service health를 요약 출력한다. 검증 명령은 같은 lock으로 재실행할 수 있어 handoff와 장애 분석에 재사용된다.

## 테스트 전략

- Pester unit tests: `origin/dev` resolve, dirty runtime 거부, lock JSON, generated override의 5 service mount, mismatch 오류를 mock process adapter로 검증한다.
- PowerShell syntax test: `.psm1`, 두 public script import/parse를 검증한다.
- Docker compose config test: generated override와 base compose를 합성해 parse한다.
- local integration: clean `origin/dev` worktree를 만들고 deploy 후 Docker inspect와 container SHA/dbt project 검증을 실행한다.

## 후속 확장 seam

feature 검증은 `requested_ref`를 명시적으로 받는 별도 interface로만 추가한다. 기존 `deploy-dev.ps1`의 무인자 `origin/dev` 계약을 변경하지 않아, 병합본 배포 경로의 실수 방지 성질을 유지한다.
