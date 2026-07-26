# LessonRun

## 2026-07-16 Task 3 - revision-locked dev deploy documentation

- 범위: `README.md`, `docs/agent/workflows/revision-locked-dev-deploy.md`, `scripts/tests/DevDeployHarness.Tests.ps1`의 documentation-contract test.
- 목적: `scripts/deploy.sh`는 `origin/main` 기반 경로이며 merged `dev` runtime validation에 쓰지 않는다는 점과, `scripts/deploy-dev.ps1`만 merged `origin/dev` 배포 entry point라는 점을 문서화했다.
- Lock 증거로 기록해야 할 항목: `.runtime/dev/deployment-lock.json`의 `dags.sha`, `dbt.sha`, detached runtime worktree path, generated compose override path.
- Runtime 검증으로 기록해야 할 항목: 다섯 Airflow service mount, scheduler DAG/DBT container HEAD, `/opt/airflow/dbt/domains/traffic_weather/dbt_project.yml`, apiserver/scheduler health.
- Safety gate: source root `dags/`와 `dbt/`는 fetch만 하고 checkout/reset/merge/clean하지 않는다. dirty runtime worktree와 failed verification은 retry 전에 원인 진단이 필요하다.
- 이번 feature worktree에서는 live Docker deployment를 수행하지 않았다. `.env` 값과 secret 값은 읽거나 기록하지 않았다.

## 2026-07-21 Task - Traffic D1 계약 승격 PR에서 manifest gate 테스트 누락 복구

- 범위: `dbt/domains/traffic_weather/models/traffic/transform/gold/gold_traffic_flow_link_latest.yml`, `dbt/domains/traffic_weather/models/traffic/transform/gold/gold_traffic_flow_congestion_hotspots_hourly.yml`
- 증상: PR `#324`에서 `validate-traffic-manifest`가 실패하며 `workflow premerge gate`(traffic gold gate) 카운팅 불일치가 발생.
- 원인: 두 금속(골드) 모델의 `product_row_id` 기본 키 테스트(`not_null`, `unique`)에 있던 `traffic_gold_gate` 태그가 누락되어 테스트 인벤토리 집계와 실행 대상이 엇갈림.
- 조치: 두 모델에서 `product_row_id` 테스트를 다음 형태로 복구.
  - `not_null: { config: { tags: [traffic_gold_gate] } }`
  - `unique: { config: { tags: [traffic_gold_gate] } }`
- 결과/리스크: PR은 동일 브랜치에 `fix(dbt): restore traffic_gold_gate tags for traffic gold key tests` 커밋(`073f499`)으로 반영되었고, 병목인 게이트 통과는 보류 중이었다가 확인 필요.
- 재발 방지:
  - 계약/테스트 분리 작업 후 `model contract split` 단계에서 태그 보존 체크리스트를 의무화.
  - pre-merge 전에 `dbt test --select tag:traffic_gold_gate` 기준의 기대치 집계 점검을 PR 리뷰 항목에 추가.
