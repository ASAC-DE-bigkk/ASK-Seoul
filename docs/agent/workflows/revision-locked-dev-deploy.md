# Revision-locked dev 배포 workflow

이 문서는 `dags`와 `dbt`의 병합된 `origin/dev` revision을 로컬 Airflow 런타임에 올릴 때 쓰는 운영 절차다. feature branch나 임의 SHA 검증 절차가 아니라, 이미 dev에 merge된 결과를 재현 가능하게 배포하고 증거를 남기는 절차다.

## Entry points

`scripts/deploy.sh`는 main 기반 배포 경로다. 내부에서 `scripts/update-nested-git.sh`를 실행하고, root의 `dags/`와 `dbt/` submodule을 각각 `main`으로 checkout한 뒤 `origin/main`을 fast-forward merge한다. 그래서 merged `dev` runtime validation에는 유효하지 않다.

merged `dev` 배포는 아래 PowerShell 명령만 사용한다.

```powershell
powershell.exe -NoProfile -File ./scripts/deploy-dev.ps1
powershell.exe -NoProfile -File ./scripts/verify-dev-deploy.ps1
```

`deploy-dev.ps1`는 `origin/dev`만 받는다. feature ref, branch name, SHA 인자를 받는 mode는 없다. `verify-dev-deploy.ps1`도 public argument를 받지 않는다.

## What is locked

`deploy-dev.ps1`는 `dags`와 `dbt`에서 `origin/dev`를 fetch하고 SHA를 resolve한다. root의 source checkout은 배포 source로 직접 mount하지 않고, 아래 runtime worktree를 detached 상태로 맞춘다.

```text
.runtime/dev/
  dags/
  dbt/
  deployment-lock.json
  docker-compose.generated.yml
```

`deployment-lock.json`에는 다음 증거가 들어간다.

- requested ref: `origin/dev`
- `dags.sha`와 `dbt.sha`
- detached runtime worktree absolute path
- generated compose override absolute path
- required DBT project: `/opt/airflow/dbt/domains/traffic_weather/dbt_project.yml`

generated compose override는 다섯 Airflow service에 같은 runtime source를 mount한다.

- `airflow-init`
- `airflow-apiserver`
- `airflow-scheduler`
- `airflow-dag-processor`
- `airflow-triggerer`

각 service는 locked DAG worktree를 `/opt/airflow/dags:ro`, locked DAG plugins path를 `/opt/airflow/plugins:ro`, locked DBT worktree를 `/opt/airflow/dbt`로 mount한다.

## What is verified

`verify-dev-deploy.ps1`는 lock 파일을 기준으로 실행 중인 Docker 상태를 다시 읽는다. 성공 조건은 다음과 같다.

- 다섯 Airflow service의 실제 Docker mount source가 lock의 runtime worktree path와 일치한다.
- scheduler container 내부의 `/opt/airflow/dags` Git HEAD가 `dags.sha`와 일치한다.
- scheduler container 내부의 `/opt/airflow/dbt` Git HEAD가 `dbt.sha`와 일치한다.
- `/opt/airflow/dbt/domains/traffic_weather/dbt_project.yml`이 scheduler container 안에 존재한다.
- `airflow-apiserver`와 `airflow-scheduler` health가 `healthy`다.

실패한 검증은 non-zero로 끝나며 성공으로 간주하지 않는다. mount mismatch, SHA mismatch, DBT project 누락, unhealthy service는 원인을 진단한 뒤 다시 실행한다.

## Safety gate

`deploy-dev.ps1`는 source root의 `dags/`와 `dbt/`를 fetch source로만 사용한다. 이 경로에는 checkout, reset, merge, clean을 수행하지 않는다. root submodule pointer도 이 로컬 dev 배포만으로 갱신하지 않는다.

runtime worktree가 이미 존재하고 dirty 상태면 revision을 바꾸기 전에 실패한다. dirty runtime worktree를 자동 정리하지 않는 이유는 이전 검증 흔적이나 사람이 만든 변경을 덮어쓰지 않기 위해서다.

`.env`는 로컬에 있어야 하지만 내용은 출력하지 않는다. secret, token, password, R2 key 값은 lock, 문서, LessonRun, issue/PR 본문에 기록하지 않는다.

## Merge-to-local routine

1. DAG, DBT, 관련 root harness 변경을 각각 해당 repository의 `dev`에 merge한다.
2. root repository에서 이 harness가 들어간 branch를 최신 상태로 맞춘다.
3. local `.env`가 있는지 확인하되 값을 출력하지 않는다.
4. root에서 `powershell.exe -NoProfile -File ./scripts/deploy-dev.ps1`를 실행한다.
5. 이어서 `powershell.exe -NoProfile -File ./scripts/verify-dev-deploy.ps1`를 실행한다.
6. `.runtime/dev/deployment-lock.json`을 열어 `dags.sha`, `dbt.sha`, runtime path, compose override path를 확인한다.
7. Airflow DAG run id, 성공/실패 task, 최종 row count, 생성 raw object/table, lock SHA를 `LessonRun.md`에 기록한다.

이 feature worktree에서는 live Docker deployment를 수행하지 않는다. live 검증은 local `.env`가 준비된 root에서 위 절차를 따라 별도로 실행한다.
