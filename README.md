# ELT Infra: Airflow + Trino + dbt + Cloudflare R2 Iceberg

This repository runs a local Docker-based control plane for a shared prod Cloudflare R2 Data Catalog/Iceberg environment.

The first version proves the execution path:

1. Airflow runs a smoke DAG.
2. The DAG uploads the source fixture to an R2 raw object path.
3. The DAG loads the same rows into an Iceberg bronze table through Trino.
4. dbt reads the bronze table as a source.
5. dbt builds and tests silver and gold Iceberg tables.

## Current Status

As of 2026-06-27, the first end-to-end smoke run has passed.

Verified:

- Airflow `3.2.2` API server, scheduler, DAG processor, and triggerer are running.
- dbt runs from an isolated virtualenv in the Airflow image.
- Airflow has Python clients for R2 object upload and Trino SQL ingestion.
- Trino loads the `iceberg` catalog.
- R2 Data Catalog auth check returns HTTP `200`.
- The Airflow DAG `dbt_trino_iceberg_smoke` completed successfully.
- `iceberg.ops_smoke` remains as the reserved smoke schema. Raw and bronze data are allowed to accumulate; silver/gold deduplicate by `event_id`.

## Fixed Names

| Item | Value |
| --- | --- |
| R2 bucket | `seoul` |
| Dev R2 bucket | `seoul-dev` |
| Trino catalog | `iceberg` |
| Dev Trino catalog | `iceberg_dev` |
| Smoke schema | `ops_smoke` |
| dbt target | `prod` |
| Airflow web port | `30585` |
| Airflow DAG | `dbt_trino_iceberg_smoke` |
| dbt project/profile | `elt_smoke` |
| Bronze table | `bronze_sample_events` |
| Silver model | `silver_sample_events` |
| Gold model | `gold_event_type_metrics` |
| Airflow version | `3.2.2` |
| dbt version | `1.10.22` |
| dbt-trino version | `1.10.2` |

## Files

| Path | Purpose |
| --- | --- |
| `docker-compose.yml` | Postgres, Trino, Airflow init/API server/scheduler/DAG processor/triggerer |
| `Dockerfile.airflow` | Airflow 3.2.2 image with R2/Trino Python clients plus `dbt-core` and `dbt-trino` in an isolated venv |
| `trino/catalog/iceberg.properties` | Trino Iceberg REST catalog config |
| `dbt/elt_smoke` | dbt medallion smoke project |
| `dbt/elt_smoke/seeds/sample_events.csv` | Source fixture used by Airflow to simulate external API data |
| `dags/dbt_trino_iceberg_smoke.py` | Airflow DAG for R2 raw upload, bronze load, and dbt validation |
| `scripts/update-nested-git.sh` | Pulls the nested DAG and dbt repositories before deployment |
| `scripts/deploy.sh` | nested repo를 `origin/main` 기준으로 갱신한 뒤 Docker Compose를 rebuild 기동 |
| `scripts/deploy-dev.ps1` | 병합된 `origin/dev` DAG/dbt revision만 locked runtime worktree로 배포 |
| `scripts/verify-dev-deploy.ps1` | 실행 중인 locked dev deployment를 deployment lock 기준으로 검증 |
| `docs/agent/workflows/revision-locked-dev-deploy.md` | merged dev revision 배포와 증거 기록 절차 |
| `scripts/bootstrap-cloudflare.sh` | R2 bucket/Data Catalog bootstrap helper |
| `scripts/check-r2-catalog-auth.sh` | Verifies the R2 Data Catalog token can access the configured warehouse |
| `.env.example` | Required local values without secrets |

## Prepare `.env`

Create `.env` from `.env.example` and fill the real values. Do not commit `.env`.

Required Cloudflare runtime values:

- `CLOUDFLARE_ACCOUNT_ID`
- `R2_ENDPOINT`
- `R2_ACCESS_KEY_ID`
- `R2_SECRET_ACCESS_KEY`
- `R2_DATA_CATALOG_TOKEN`
- `R2_DATA_CATALOG_URI`
- `R2_DATA_CATALOG_WAREHOUSE`

`R2_ACCESS_KEY_ID` and `R2_SECRET_ACCESS_KEY` are for R2 object storage access. `R2_DATA_CATALOG_TOKEN` is for the Iceberg REST catalog. The runtime token must have both R2 object access and R2 Data Catalog warehouse access for `seoul`. Object Read & Write alone is not enough for the Iceberg REST catalog and returns `403` with `Insufficient permission for R2 Data Catalog Warehouse`.

Required Airflow/Postgres local values:

- `AIRFLOW_UID`
- `AIRFLOW_ADMIN_USERNAME`
- `AIRFLOW_ADMIN_PASSWORD`
- `AIRFLOW_ADMIN_EMAIL`
- `AIRFLOW_FERNET_KEY`
- `AIRFLOW_SECRET_KEY`
- `POSTGRES_USER`
- `POSTGRES_PASSWORD`
- `POSTGRES_DB`

`CLOUDFLARE_API_TOKEN` can stay empty when you use `npx wrangler login` locally. `WRANGLER_R2_SQL_AUTH_TOKEN` is only needed for optional Wrangler R2 SQL checks.

Optional dev Cloudflare/R2 values:

- `R2_DEV_BUCKET_NAME`
- `TRINO_DEV_ICEBERG_CATALOG`
- `DEV_SMOKE_SCHEMA`
- `DBT_TARGET`
- `R2_DEV_RAW_PREFIX`
- `R2_DEV_ENDPOINT`
- `R2_DEV_ACCESS_KEY_ID`
- `R2_DEV_SECRET_ACCESS_KEY`
- `R2_DEV_DATA_CATALOG_TOKEN`
- `R2_DEV_DATA_CATALOG_URI`
- `R2_DEV_DATA_CATALOG_WAREHOUSE`

The Trino dev catalog is `iceberg_dev`. dbt can target it with:

```bash
docker compose exec --workdir /opt/airflow/dbt/elt_smoke airflow-scheduler /home/airflow/dbt-venv/bin/dbt debug --target dev
docker compose exec --workdir /opt/airflow/dbt/elt_smoke airflow-scheduler /home/airflow/dbt-venv/bin/dbt build --target dev
```

Use `DEV_SMOKE_SCHEMA=dev_<github_id>` so dev tables do not collide. If it is omitted, dev falls back to `dev_local`, not the prod smoke schema. Do not reuse prod credentials for dev testing.

To run the Airflow DAG against dev, set these values in `.env` and recreate the Airflow services:

```env
DBT_TARGET=dev
TRINO_DEV_ICEBERG_CATALOG=iceberg_dev
DEV_SMOKE_SCHEMA=dev_<github_id>
R2_DEV_RAW_PREFIX=dev/<github_id>/raw/sample_events
```

With `DBT_TARGET=dev`, the DAG uses `R2_DEV_*`, writes to `iceberg_dev.<DEV_SMOKE_SCHEMA>.bronze_sample_events`, and runs dbt with `--target dev`.

## Bootstrap Cloudflare

If the `seoul` bucket or Data Catalog does not exist yet:

```bash
./scripts/bootstrap-cloudflare.sh
```

The script creates or verifies the bucket and enables or verifies the Data Catalog. It does not create runtime R2 API tokens, because Cloudflare shows secret values only at token creation time.

After creating or rotating runtime credentials, run:

```bash
./scripts/check-r2-catalog-auth.sh
docker compose up -d --force-recreate trino
```

## Start Local Services

`scripts/deploy.sh`는 main 기반 배포 경로다. 이 스크립트는 `scripts/update-nested-git.sh`를 실행하고, 두 nested repository 내부에서 `main`을 checkout한 뒤 `origin/main`을 fast-forward하고 Docker Compose를 rebuild 기동한다. `origin/dev`를 lock하거나 검증하지 않으므로 merged `dev` runtime validation에는 사용하지 않는다.

```bash
./scripts/deploy.sh
```

Merged `dev` runtime validation의 문서화된 entry point는 하나뿐이다.

```powershell
powershell.exe -NoProfile -File ./scripts/deploy-dev.ps1
powershell.exe -NoProfile -File ./scripts/verify-dev-deploy.ps1
```

`deploy-dev.ps1` accepts only literal `origin/dev`. It has no feature-ref, branch-name, arbitrary-ref, or SHA input mode. 이 스크립트는 `origin/dev`를 fetch하고, `.runtime/dev/` 아래 detached runtime worktree를 준비하고, `.runtime/dev/deployment-lock.json`을 쓰고, `.runtime/dev/docker-compose.generated.yml`을 생성한 뒤 해당 override로 Docker Compose를 기동한다. `verify-dev-deploy.ps1`가 통과해야 배포를 유효한 상태로 본다.

Locked dev deployment는 다음 항목을 검증한다.

- `dags`와 `dbt`의 detached runtime worktree path
- `origin/dev`에서 resolve한 두 SHA 값
- generated compose override path
- `airflow-init`, `airflow-apiserver`, `airflow-scheduler`, `airflow-dag-processor`, `airflow-triggerer`의 실제 Docker mount
- host runtime DAG/DBT worktree Git head와 Docker bind mount source
- 필수 DBT project file `/opt/airflow/dbt/domains/traffic_weather/dbt_project.yml`
- `airflow-apiserver`와 `airflow-scheduler` health

Safety gate: source root `dags/` and `dbt/` paths are fetch sources only. The harness must not run checkout, reset, merge, clean, or worktree mutation commands in those source root paths. 기존 runtime worktree가 dirty 상태면 revision 변경 전에 실패한다. 실패한 deploy 또는 verify command는 non-zero로 끝나며 retry 전에 원인을 진단해야 한다. Secrets and `.env` values must never be output, copied into reports, written to LessonRun, or included in issue/PR bodies.

실패 진단은 secret을 출력하지 않는 증거만 사용한다. Logs must be inspected locally and redacted before terminal capture, recording, or sharing. `.env`, `.env.*`, API key, token, password, R2 key 값은 절대 출력하지 않는다.

```powershell
Get-Content -Raw .\.runtime\dev\deployment-lock.json | ConvertFrom-Json | ConvertTo-Json -Depth 8
docker compose -f .\docker-compose.yml -f .\.runtime\dev\docker-compose.generated.yml ps

$services = 'airflow-init','airflow-apiserver','airflow-scheduler','airflow-dag-processor','airflow-triggerer'
foreach ($service in $services) {
  $containerId = docker compose -f .\docker-compose.yml -f .\.runtime\dev\docker-compose.generated.yml ps -q $service
  docker inspect $containerId --format '{{json .Mounts}}'
}

$logSecretPattern = '(?i)(secret|token|password|serviceKey|api[_-]?key|access[_-]?key|r2)'
$logValuePattern = '(?i)([A-Z0-9_]*(SECRET|TOKEN|PASSWORD|SERVICEKEY|API_KEY|ACCESS_KEY|R2)[A-Z0-9_]*=)\S+'
foreach ($service in 'airflow-scheduler','airflow-apiserver') {
  docker compose -f .\docker-compose.yml -f .\.runtime\dev\docker-compose.generated.yml logs --tail 200 $service 2>&1 |
    Where-Object { $_ -notmatch $logSecretPattern } |
    ForEach-Object { $_ -replace $logValuePattern, '$1[REDACTED]' }
}
git -C .\.runtime\dev\dags rev-parse HEAD
git -C .\.runtime\dev\dbt rev-parse HEAD
docker compose -f .\docker-compose.yml -f .\.runtime\dev\docker-compose.generated.yml exec airflow-scheduler test -f /opt/airflow/dbt/domains/traffic_weather/dbt_project.yml
```

The nested repositories are configured as:

| Path | Remote |
| --- | --- |
| `dags` | `https://github.com/ASAC-DE-bigkk/ASAC-DAG` |
| `dbt` | `https://github.com/ASAC-DE-bigkk/ASAC-DBT` |

To update only DAG/dbt without restarting services:

```bash
./scripts/update-nested-git.sh
```

Merged dev local validation routine:

1. DAG, DBT, 관련 root harness 변경을 각 repository의 `dev` branch에 merge한다.
2. 이 harness가 들어간 root repository branch를 최신 상태로 맞춘다.
3. local `.env` 존재 여부만 확인하고 내용을 출력하지 않는다.
4. root에서 `deploy-dev.ps1`를 실행한 뒤 `verify-dev-deploy.ps1`를 실행한다.
5. `.runtime/dev/deployment-lock.json`을 확인하고 정확한 DAG SHA, DBT SHA, run id, 성공/실패 task 상태, final row count, 생성 object/table 증거를 `LessonRun.md`에 기록한다.

이 feature worktree에서는 절차와 test contract만 문서화한다. 여기서 live Docker deployment를 수행했다고 주장하지 않는다.

Initialize Airflow metadata and admin user:

```bash
docker compose up airflow-init
```

Start Airflow and Trino:

```bash
docker compose up -d
```

Open Airflow:

```text
http://localhost:30585
```

Use the credentials from `.env`.

## Run Smoke DAG

Trigger `dbt_trino_iceberg_smoke` from the Airflow UI, or run:

```bash
docker compose exec airflow-scheduler airflow dags trigger dbt_trino_iceberg_smoke
```

The DAG runs:

1. Uploads `dbt/elt_smoke/seeds/sample_events.csv` to an R2 raw object path:
   `raw/sample_events/load_date=<utc-date>/sample_events_<utc-timestamp>.csv`
2. Creates/appends `iceberg.ops_smoke.bronze_sample_events` through Trino.
3. Runs `dbt run --select silver_sample_events gold_event_type_metrics`.
4. Runs `dbt test`.

There is no cleanup step. Raw R2 objects and bronze rows may accumulate across repeated runs. `silver_sample_events` keeps the latest row per `event_id`, so `gold_event_type_metrics` remains stable for the same fixture data.

## Direct Checks

Trino is only exposed on the Docker network. Use `docker compose exec` for direct checks:

```bash
docker compose exec trino trino --execute "SHOW CATALOGS"
docker compose exec trino trino --execute "SHOW SCHEMAS FROM iceberg"
docker compose exec trino trino --execute "SHOW SCHEMAS FROM iceberg_dev"
docker compose exec trino trino --execute "SHOW TABLES FROM iceberg.ops_smoke"
docker compose exec trino trino --execute "SELECT * FROM iceberg.ops_smoke.gold_event_type_metrics ORDER BY event_type"
```

Check that the R2 Data Catalog token can access the configured warehouse:

```bash
./scripts/check-r2-catalog-auth.sh
```

If this returns `403` with `Insufficient permission for R2 Data Catalog Warehouse`, recreate the Cloudflare R2 API token with R2 storage read/write and R2 Data Catalog warehouse access for the `seoul` catalog/warehouse, then update `.env`.

When `.env` changes, recreate Trino so it receives the new environment values:

```bash
docker compose up -d --force-recreate trino
```

Run dbt directly from the Airflow image:

```bash
docker compose run --rm --no-deps --workdir /opt/airflow/dbt/elt_smoke --entrypoint /home/airflow/dbt-venv/bin/dbt airflow-scheduler debug
```

Check the most recent smoke run:

```bash
docker compose exec airflow-scheduler airflow dags list-runs dbt_trino_iceberg_smoke -o json
docker compose exec airflow-scheduler airflow tasks states-for-dag-run dbt_trino_iceberg_smoke <run-id>
```

## Mentee Workflow

The shared Cloudflare/R2/Data Catalog environment is prod. Mentees should not receive the mentor's prod Cloudflare credential.

Allowed with peer review:

- Changes inside a mentee-owned domain schema, such as `iceberg.weather`
- Domain-specific DAG/dbt model/test/source changes
- Small public/non-sensitive source fixture CSV files
- Low-frequency schedule changes with small cost impact

Requires mentor approval:

- Shared infrastructure changes
- Runtime secret changes
- R2 direct upload or landing path design
- Reserved schema changes such as `iceberg.ops_smoke`
- Backfills, high-frequency schedules, or expensive workloads
- Writes or drops outside the mentee-owned domain schema

For local development, mentees should use Docker Compose and either stay at local/dbt validation level or use their own Cloudflare account.

## References

- Cloudflare R2 Data Catalog Trino config: https://developers.cloudflare.com/r2/data-catalog/config-examples/trino/
- Cloudflare R2 Data Catalog get started: https://developers.cloudflare.com/r2/data-catalog/get-started/
- Apache Airflow Docker Compose guide: https://airflow.apache.org/docs/apache-airflow/stable/howto/docker-compose/index.html
- dbt Trino setup: https://docs.getdbt.com/docs/core/connect-data-platform/trino-setup
- Trino Iceberg REST catalog docs: https://trino.io/docs/current/object-storage/metastores.html
