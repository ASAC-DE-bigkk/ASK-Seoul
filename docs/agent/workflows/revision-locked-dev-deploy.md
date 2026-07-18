# Revision-locked dev 배포 workflow

이 문서는 `dags`와 `dbt`의 병합된 `origin/dev` revision을 로컬 Airflow 런타임에 올릴 때 쓰는 운영 절차다. feature branch나 임의 SHA 검증 절차가 아니라, 이미 dev에 merge된 결과를 재현 가능하게 배포하고 증거를 남기는 절차다.

## Entry points

`scripts/deploy.sh`는 main 기반 배포 경로다. 내부에서 `scripts/update-nested-git.sh`를 실행하고, root의 `dags/`와 `dbt/` submodule을 각각 `main`으로 checkout한 뒤 `origin/main`을 fast-forward merge한다. 그래서 merged `dev` runtime validation에는 유효하지 않다.

merged `dev` 배포는 아래 PowerShell 명령만 사용한다.

```powershell
powershell.exe -NoProfile -File ./scripts/deploy-dev.ps1
powershell.exe -NoProfile -File ./scripts/verify-dev-deploy.ps1
```

`deploy-dev.ps1` accepts only literal `origin/dev`. It has no feature-ref, branch-name, arbitrary-ref, or SHA input mode. `verify-dev-deploy.ps1`도 public argument를 받지 않는다.

root runtime의 `Marquez always-on` 계약에 따라 `marquez-db`, `marquez-api`, `marquez-web`은 profile 없이 기동한다. Traffic/Weather lineage 환경은 서비스 기동 여부와 분리되어 `docker-compose.traffic-weather-lineage.yml` overlay로만 선택된다.

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

- `schema_version=2`
- requested ref: `origin/dev`
- `dags.sha`와 `dbt.sha`
- detached runtime worktree absolute path
- generated compose override absolute path
- `lineage_overlay_path`와 `lineage_overlay_sha256`
- ordered exact `compose_files`
- required DBT project: `/opt/airflow/dbt/domains/traffic_weather/dbt_project.yml`

모든 harness Compose 호출은 아래 exact 3-file set을 같은 순서로 사용한다.

1. `docker-compose.yml`
2. `docker-compose.traffic-weather-lineage.yml`
3. `.runtime/dev/docker-compose.generated.yml`

```powershell
docker compose -f .\docker-compose.yml -f .\docker-compose.traffic-weather-lineage.yml -f .\.runtime\dev\docker-compose.generated.yml config --quiet
```

배포 `up`은 10개 서비스의 `compose labels`가 같은 exact set을 가리키도록 `--force-recreate`를 사용한다. Docker Compose는 effective config가 같은 기존 container를 재사용하면서 예전 `project.config_files` label을 남길 수 있기 때문이다. named volume은 삭제하지 않으므로 Postgres와 Marquez metadata는 보존하지만, container 재시작 동안 실행 중 query/task는 중단될 수 있다. 따라서 실제 배포 직전 Traffic을 pause하고 active Traffic/Weather/Bronze 작업이 모두 종료됐는지 확인한다. `down -v`는 사용하지 않는다.

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
- host runtime DAG/DBT worktree의 Git HEAD와 clean 상태가 각각 `dags.sha`, `dbt.sha`와 일치한다.
- Docker inspect로 다섯 Airflow service의 bind mount source가 같은 host runtime worktree인지 검증한다.
- `/opt/airflow/dbt/domains/traffic_weather/dbt_project.yml`이 scheduler container 안에 존재한다.
- `airflow-apiserver`와 `airflow-scheduler` health가 `healthy`다.
- 현재 lineage overlay SHA-256이 lock의 `lineage_overlay_sha256`과 일치한다.
- Airflow, Trino, Marquez container의 Docker `compose labels`가 lock의 ordered exact 3-file set과 일치한다.
- scheduler lineage 환경이 selective Traffic/Weather 계약과 일치하고 `marquez-api` DNS가 해석된다.
- `marquez-db`, `marquez-api`, `marquez-web`의 running/health, `512MB`/`1536MB`/`256MB` cap, `unless-stopped`, restart count `0`, OOM false를 확인한다.
- Marquez admin health와 metadata API가 HTTP `200`이다. optional search는 `SEARCH_ENABLED=false`로 비활성화한다.
- Airflow pool은 `trino_traffic_heavy=1`, `trino_weather_heavy=1`, legacy `trino_heavy=1`이다.

실패한 검증은 non-zero로 끝나며 성공으로 간주하지 않는다. mount mismatch, SHA mismatch, DBT project 누락, unhealthy service는 원인을 진단한 뒤 다시 실행한다.

## Failure diagnosis

검증 실패를 retry하기 전에는 secret을 출력하지 않는 증거만 수집한다. Secrets and `.env` values must never be output, copied into reports, written to LessonRun, or included in issue/PR bodies.

먼저 lock 파일과 Compose 상태를 확인한다.

```powershell
Get-Content -Raw .\.runtime\dev\deployment-lock.json | ConvertFrom-Json | ConvertTo-Json -Depth 8
docker compose -f .\docker-compose.yml -f .\docker-compose.traffic-weather-lineage.yml -f .\.runtime\dev\docker-compose.generated.yml ps
```

실제 mount source가 lock의 runtime worktree path와 일치하는지 다섯 Airflow service에서 확인한다.

```powershell
$services = 'airflow-init','airflow-apiserver','airflow-scheduler','airflow-dag-processor','airflow-triggerer'
foreach ($service in $services) {
  $containerId = docker compose -f .\docker-compose.yml -f .\docker-compose.traffic-weather-lineage.yml -f .\.runtime\dev\docker-compose.generated.yml ps -q $service
  docker inspect $containerId --format '{{json .Mounts}}'
}
```

scheduler와 apiserver 상태가 원인인지 확인할 때는 log를 로컬에서 먼저 확인한다. Logs must be inspected locally and redacted before terminal capture, recording, or sharing. 아래 예시는 secret 이름이 포함된 줄을 버리고, 남은 줄에서도 secret-like key/value를 `[REDACTED]`로 치환한 뒤에만 출력한다.

```powershell
$logSecretPattern = '(?i)(secret|token|password|serviceKey|api[_-]?key|access[_-]?key|r2)'
$logValuePattern = '(?i)([A-Z0-9_]*(SECRET|TOKEN|PASSWORD|SERVICEKEY|API_KEY|ACCESS_KEY|R2)[A-Z0-9_]*=)\S+'
foreach ($service in 'airflow-scheduler','airflow-apiserver') {
  docker compose -f .\docker-compose.yml -f .\docker-compose.traffic-weather-lineage.yml -f .\.runtime\dev\docker-compose.generated.yml logs --tail 200 $service 2>&1 |
    Where-Object { $_ -notmatch $logSecretPattern } |
    ForEach-Object { $_ -replace $logValuePattern, '$1[REDACTED]' }
}
```

Windows bind-mounted Git worktree는 container에서 host gitdir를 해석할 수 없으므로, SHA는 host runtime worktree에서 검증하고 container에서는 bind mount source와 필수 DBT project path를 검증한다.

```powershell
git -C .\.runtime\dev\dags rev-parse HEAD
git -C .\.runtime\dev\dbt rev-parse HEAD
docker compose -f .\docker-compose.yml -f .\docker-compose.traffic-weather-lineage.yml -f .\.runtime\dev\docker-compose.generated.yml exec airflow-scheduler test -f /opt/airflow/dbt/domains/traffic_weather/dbt_project.yml
```

## Trino concurrency canary와 rollback

기본 revision-locked Stage1은 ordered 3-file set과 `trino/resource-groups.json`의 `hardConcurrencyLimit=1`을 사용한다. `deploy-dev.ps1`와 `verify-dev-deploy.ps1`가 통과하기 전에는 concurrency를 올리지 않는다.

Stage2의 `hardConcurrencyLimit=2`는 `docker-compose.trino-hard2-canary.yml`을 네 번째로 명시한 canary에서만 허용한다. root/DAG/DBT static gate, exact refs, 기존 active Traffic DagRun 부재를 확인한 뒤 실행한다.

```powershell
$baseCompose = @(
  '-f', 'docker-compose.yml',
  '-f', 'docker-compose.traffic-weather-lineage.yml',
  '-f', '.runtime/dev/docker-compose.generated.yml'
)
$canaryCompose = $baseCompose + @('-f', 'docker-compose.trino-hard2-canary.yml')

docker compose @canaryCompose config --quiet
docker compose @canaryCompose up -d --no-deps --force-recreate trino
docker compose @canaryCompose exec -T trino sh -c "grep -F '\"hardConcurrencyLimit\": 2' /etc/trino/resource-groups.json"
```

canary guardrail은 query memory `1280MB` per-node, user memory `1280MB`, total memory `2560MB`, heap headroom `2GB`, task concurrency `2`다. 세 complete Traffic cycle 동안 Traffic duration, resolver, `dbt_test_gold`, Trino memory/restart/OOM, Iceberg write, exact Gold reconciliation, Weather 대기를 기록한다.

아래 stop 조건 중 하나라도 발생하면 Traffic을 pause하고 즉시 rollback한다.

- Trino `restart/OOM/memory error`
- `Iceberg conflict/duplicate` 또는 exact Gold reconciliation 실패
- runnable `Weather scheduled > 15m`
- 한 cycle의 `Traffic > 30m` 또는 DAG 실패

```powershell
docker compose @canaryCompose exec -T airflow-scheduler airflow dags pause traffic_incident_transform
docker compose @baseCompose up -d --no-deps --force-recreate trino
docker compose @baseCompose exec -T trino sh -c "grep -F '\"hardConcurrencyLimit\": 1' /etc/trino/resource-groups.json"
powershell.exe -NoProfile -File ./scripts/verify-dev-deploy.ps1
```

rollback은 canary overlay만 제거한다. `trino_traffic_heavy=1`, `trino_weather_heavy=1`과 Marquez always-on 서비스는 유지한다. canary 실행 중 Trino compose label은 네 번째 파일을 포함하므로 baseline verifier는 Stage1 시작 전과 rollback 뒤에 실행하고, canary는 위 runtime assertion과 세 cycle 증거로 판정한다.

## Safety gate

`deploy-dev.ps1`에서 source root `dags/` and `dbt/` paths are fetch sources only. The harness must not run checkout, reset, merge, clean, or worktree mutation commands in those source root paths. root submodule pointer도 이 로컬 dev 배포만으로 갱신하지 않는다.

runtime worktree가 이미 존재하고 dirty 상태면 revision을 바꾸기 전에 실패한다. dirty runtime worktree를 자동 정리하지 않는 이유는 이전 검증 흔적이나 사람이 만든 변경을 덮어쓰지 않기 위해서다.

`.env`는 로컬에 있어야 하지만 내용은 출력하지 않는다. secret, token, password, R2 key 값은 lock, 문서, LessonRun, issue/PR 본문에 기록하지 않는다.

## Merge-to-local routine

1. DAG, DBT, 관련 root harness 변경을 각각 해당 repository의 `dev`에 merge한다.
2. root repository에서 이 harness가 들어간 branch를 최신 상태로 맞춘다.
3. local `.env`가 있는지 확인하되 값을 출력하지 않는다.
4. root에서 `powershell.exe -NoProfile -File ./scripts/deploy-dev.ps1`를 실행한다.
5. 이어서 `powershell.exe -NoProfile -File ./scripts/verify-dev-deploy.ps1`를 실행한다.
6. `.runtime/dev/deployment-lock.json`을 열어 `dags.sha`, `dbt.sha`, runtime path, `lineage_overlay_sha256`, ordered `compose_files`를 확인한다.
7. Airflow DAG run id, 성공/실패 task, 최종 row count, 생성 raw object/table, lock SHA를 `LessonRun.md`에 기록한다.

이 feature worktree에서는 live Docker deployment를 수행하지 않는다. live 검증은 local `.env`가 준비된 root에서 위 절차를 따라 별도로 실행한다.
