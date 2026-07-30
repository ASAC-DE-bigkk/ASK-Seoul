# Weather/Traffic prod release contract

prod 승격 단위는 root와 세 submodule, Airflow 이미지 digest를 함께 고정한 JSON release artifact다. artifact는 root commit을 만든 뒤 생성한다. artifact가 자기 자신을 포함한 root commit을 참조하는 순환을 피하면서도, deploy는 artifact가 지정한 clean checkout에서만 시작할 수 있다.

## 생성

clean checkout에서 네 component SHA와 registry에 push한 Airflow image digest를 확정한 뒤 다음을 실행한다.

```powershell
python scripts/release_contract.py create `
  --release-name weather-traffic-prod-YYYYMMDD `
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
