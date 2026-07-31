# 전 도메인 prod release contract

이 계약은 Weather/Traffic에 한정되지 않는다. root Compose가 모든 Airflow service와 모든 domain DAG에 같은 `.env.prod`, Trino catalog, submodule 조합을 주입하므로, prod 승격 단위는 root와 세 submodule, Airflow 이미지 digest를 함께 고정한 JSON release artifact다. artifact는 root commit을 만든 뒤 생성한다. artifact가 자기 자신을 포함한 root commit을 참조하는 순환을 피하면서도, deploy는 artifact가 지정한 clean checkout에서만 시작할 수 있다.

따라서 이 gate를 사용하는 PR은 플랫폼 변경으로 분류하고 Weather·Traffic, commerce, citydata, culture, transit 등 영향을 받는 domain owner 확인을 받아야 한다. 이 문서는 특정 domain의 data contract 또는 canary 성공을 대신 승인하지 않는다.

## 생성

clean checkout에서 네 component SHA와 registry에 push한 Airflow image digest를 확정한 뒤 다음을 실행한다.

```powershell
python scripts/release_contract.py create `
  --release-name ask-seoul-prod-YYYYMMDD `
  --root-sha <40-char-root-sha> `
  --dags-sha <40-char-dags-sha> `
  --dbt-sha <40-char-dbt-sha> `
  --dashboard-sha <40-char-dashboard-sha> `
  --airflow-image ghcr.io/<org>/ask-seoul-airflow@sha256:<64-hex> `
  --output .runtime/weather-traffic-prod-release.json
```

artifact는 release run의 보존 대상이다. `.runtime/`는 git에 올리지 않으며, GitHub Release 또는 CI build artifact로 보관한다.

## prod preflight

```powershell
python scripts/release_contract.py compose `
  --env-file .env.prod `
  --artifact .runtime/weather-traffic-prod-release.json -- up -d
```

preflight는 다음을 모두 거부한다.

- `DBT_TARGET` 이외의 target alias, 중복 env key, `R2_DEV_*`와 dev catalog/schema key
- R2 bucket/endpoint/access key, Data Catalog URI/warehouse/token, Trino catalog, schema, D1 account/database 중 누락
- immutable digest가 아닌 Airflow image
- clean checkout의 root/dags/dbt/dashboard SHA 또는 image가 artifact와 다른 경우

`docker-compose.prod.yml`은 prod env만 읽고 Trino에 `trino/catalog-prod` 하나만 mount한다. 이 catalog는 prod R2와 Data Catalog tuple만 참조한다.

## prod lineage control-plane

release wrapper는 prod Compose 실행마다 `lineage` profile을 포함한다. 따라서 Marquez DB/API/UI가 prod stack과 함께 기동되고 Airflow와 dbt OpenLineage event를 수신한다.

- Airflow namespace는 `ask-seoul-prod-airflow`로 고정한다.
- dbt namespace의 root는 `ask-seoul-prod-dbt`이며, 각 domain 실행 helper가 `<domain>` suffix를 붙여 job 충돌을 방지한다.
- Airflow selective enable을 유지하고 source code facet과 full task payload는 보내지 않는다.
- Trino OpenLineage listener는 사용하지 않는다. Airflow/dbt가 소유한 실행 경계만 수집한다.
- Marquez API/UI host port는 loopback에만 노출한다.
- Marquez DB credential은 Airflow metadata DB와 분리하고 prod preflight의 필수 tuple로 검사한다.
- `marquez.prod.yml`을 명시적으로 mount한다. image 기본 `marquez.dev.yml`과 기본 credential은 prod에서 사용하지 않는다.
- lineage transport 장애는 data task를 실패시키지 않는 fail-open 계약을 유지한다.

Marquez는 lineage control-plane이다. 품질 pass/fail, SLA, row count, dbt test 결과의 authoritative source는 기존 run metadata, R2 metrics/errors, dbt artifact와 contract다.
