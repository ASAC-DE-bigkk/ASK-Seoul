# LessonRun

## 2026-07-16 Task 3 - revision-locked dev deploy documentation

- 범위: `README.md`, `docs/agent/workflows/revision-locked-dev-deploy.md`, `scripts/tests/DevDeployHarness.Tests.ps1`의 documentation-contract test.
- 목적: `scripts/deploy.sh`는 `origin/main` 기반 경로이며 merged `dev` runtime validation에 쓰지 않는다는 점과, `scripts/deploy-dev.ps1`만 merged `origin/dev` 배포 entry point라는 점을 문서화했다.
- Lock 증거로 기록해야 할 항목: `.runtime/dev/deployment-lock.json`의 `dags.sha`, `dbt.sha`, detached runtime worktree path, generated compose override path.
- Runtime 검증으로 기록해야 할 항목: 다섯 Airflow service mount, scheduler DAG/DBT container HEAD, `/opt/airflow/dbt/domains/traffic_weather/dbt_project.yml`, apiserver/scheduler health.
- Safety gate: source root `dags/`와 `dbt/`는 fetch만 하고 checkout/reset/merge/clean하지 않는다. dirty runtime worktree와 failed verification은 retry 전에 원인 진단이 필요하다.
- 이번 feature worktree에서는 live Docker deployment를 수행하지 않았다. `.env` 값과 secret 값은 읽거나 기록하지 않았다.
