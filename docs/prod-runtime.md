# Mac mini prod 런타임 격리

## 목적과 경계

ASK-Seoul #66의 합의대로 prod Airflow는 dev 런타임과 배포 단위를 분리한다. prod
프로세스에는 `R2_*`와 `iceberg`만 주입하고, `R2_DEV_*`와 `iceberg_dev`는 주입하거나
마운트하지 않는다. 이 구성은 특정 도메인 DAG를 제거하지 않으므로, Weather/Traffic
canary가 끝난 뒤 같은 Mac mini 런타임에서 팀 전체 DAG를 순차적으로 활성화할 수 있다.

`docker-compose.prod.yml`은 다음 경계를 강제한다.

- compose project: `elt-infra-prod`
- network: `elt-infra-prod-net`
- Airflow metadata/log volume: prod project 전용
- service env file: `.env.prod` 전용
- Trino catalog mount: `trino/catalog-prod/iceberg.properties` 한 개
- 신규 DAG: `AIRFLOW__CORE__DAGS_ARE_PAUSED_AT_CREATION=true`를 유지

dev와 prod 스택은 같은 호스트 포트를 사용하고 Trino 메모리 상한도 크므로 동시에
기동하지 않는다. 로컬 canary에서는 dev를 정상 종료한 뒤 prod를 기동하고, 검증 후
prod를 정상 종료한 뒤 dev를 복구한다. `down -v`는 사용하지 않아 metadata를 보존한다.

## prod env 준비

실제 값이 들어 있는 팀 병합본을 source로 사용한다. 명령은 값 자체를 출력하지 않고,
다른 도메인의 API 키와 설정은 보존하면서 dev R2/catalog 키만 제거한다.

```bash
python scripts/prod_env.py prepare --source .env --output .env.prod
python scripts/prod_env.py validate --env-file .env.prod
```

기존 `.env.prod`를 의도적으로 갱신할 때만 `--force`를 추가한다. 검증기는 다음 계약을
fail-fast로 확인한다.

- `ASK_SEOUL_TARGET=prod`, `DBT_TARGET=prod`
- `R2_BUCKET_NAME=seoul`, `TRINO_ICEBERG_CATALOG=iceberg`
- `R2_RAW_PREFIX=raw`, `SMOKE_SCHEMA=ops_smoke`
- prod R2 S3/Data Catalog tuple의 필수 키 존재
- `R2_DEV_*`, `TRINO_DEV_ICEBERG_CATALOG`, `DEV_SMOKE_SCHEMA`,
  `ASK_SEOUL_DEV_RAW_PREFIX` 부재

`.env`, `.env.prod`는 gitignore 대상이며 commit하지 않는다.

## 렌더링과 기동

`!override`를 지원하는 Docker Compose 2.24.4 이상이 필요하다. `prod_compose.py`는
버전을 확인하고 project name을 `elt-infra-prod`로 고정하므로, shell에
`COMPOSE_PROJECT_NAME`이 남아 있어도 dev metadata volume을 재사용하지 않는다.
실제 기동 전에 병합된 compose를 내부 렌더링해 env와 catalog 경계를 확인한다.
`check`는 project/network/volume/catalog mount 등 비밀이 없는 요약만 출력한다. raw
`config`는 env-file의 credential을 출력할 수 있어 wrapper가 거부한다. 로컬 canary용
`--compose-file`을 추가해도 최종 렌더 결과가 같은 prod 격리 계약을 통과해야 한다.
Compose 전역 옵션도 wrapper 뒤에 직접 전달하지 않는다. project, env file, 추가
compose file은 wrapper 옵션으로 지정하고 `up`, `down`, `ps`, `logs` 같은 허용된
운영 subcommand를 첫 인자로 전달한다.

```bash
docker compose version
python scripts/prod_compose.py --env-file .env.prod check
python scripts/prod_compose.py --env-file .env.prod up -d --build
```

fresh prod metadata에서는 모든 DAG가 paused 상태로 시작한다. canary 중에는 해당
도메인 DAG만 활성화하며, 팀 전체 활성화는 각 도메인 오너가 prod 적재 위치와
중복/idempotency를 확인한 뒤 진행한다.

## 최초 prod 활성화 전제

`airflow-init`은 Weather/Traffic DAG가 사용하는 Trino pool을 idempotent하게 생성한다.
다만 fresh catalog의 최초 relation 생성은 일상 DAG의 fail-closed 보호를 우회해서
처리하지 않는다.

- Weather canonical W2는 prod W1 기준 테이블이 없는 상태의 최초 write를 명시적으로
  거부한다. 도메인 오너가 승인한 별도 bootstrap/이관으로 W1 기준선을 만든 뒤
  canonical DAG를 활성화한다.
- Traffic Silver snapshot fence는 기존 relation의 snapshot을 write 전후로 비교한다.
  fresh prod에는 승인된 일회성 bootstrap으로 Silver 기준 relation을 만든 뒤 fenced
  DAG를 실행하며, relation이 없다는 이유로 fence를 생략하지 않는다.
- Traffic landing/materializer의 prod 주기는 코드 기본값에 암묵적으로 의존하지 않고
  Mac mini 운영 합의에서 명시한다. 두 Silver asset이 확인되기 전에는 Gold와 D1
  exporter를 활성화하지 않는다.
- 다른 도메인의 Gold relation을 소비하는 Weather 제품은 해당 도메인 오너가 prod
  선행 적재를 확인한 뒤에만 활성화한다. Weather/Traffic rollout에서 그 relation을
  대신 생성하지 않는다.

## R2 구조 검증

Weather/Traffic 신규 쓰기는 ASK-Seoul #60의 zone 경계를 따른다.

- 원천 payload와 manifest: `raw/...`
- checkpoint, receipt, ledger, reliability, errors, recovery: `ops/...`
- 공용 축 seed/reference: `reference/...`
- Iceberg/Data Catalog 내부 객체: `__r2_data_catalog/...`

canary 완료 조건은 DAG 성공만이 아니다. prod bucket과 `iceberg` catalog에서 실제
객체/테이블을 확인하고, Weather/Traffic이 버킷 루트에 도메인 전용 임의 prefix를
추가하지 않았는지 확인해야 한다.
