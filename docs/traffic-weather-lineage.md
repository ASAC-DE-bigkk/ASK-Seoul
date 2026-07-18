# Traffic/Weather 선택적 lineage 실행

이 문서는 기존 commerce lineage를 바꾸지 않으면서 Traffic과 Weather DAG만 개발용 Marquez에 opt-in하는 실행 계약을 설명한다. 기본 `docker-compose.yml`은 `commerce-elt` namespace와 기존 fail-open 동작을 유지하면서 Marquez DB/API/Web을 항상 기동한다. Traffic/Weather 선택적 lineage 환경은 별도 `docker-compose.traffic-weather-lineage.yml` overlay를 명시했을 때만 활성화된다.

Airflow image는 이 계약을 검증한 `apache-airflow-providers-openlineage==2.19.0`을 사용하고, 격리된 dbt venv는 `openlineage-dbt==1.51.0`을 사용한다. 두 package는 image rebuild 때 동작이 임의로 바뀌지 않도록 exact pin한다.

## 실행 모드와 Marquez 수명 주기

`Marquez always-on`은 base Compose의 서비스 수명 주기 계약이다. `marquez-db`, `marquez-api`, `marquez-web`은 profile 없이 기동하며, lineage overlay는 Airflow 서비스의 OpenLineage 환경만 덮어쓴다. 따라서 Traffic/Weather 선택적 lineage 모드는 base 다음에 overlay를 병합한다.

```powershell
docker compose `
  -f docker-compose.yml `
  -f docker-compose.traffic-weather-lineage.yml `
  up -d
```

한 줄 명령은 다음과 같다.

```text
docker compose -f docker-compose.yml -f docker-compose.traffic-weather-lineage.yml up -d
```

overlay는 Trino, Marquez, volume, network 정의를 추가하거나 변경하지 않는다. Marquez API와 UI의 host port는 base의 `127.0.0.1` binding을 그대로 사용하며 외부 인터페이스에 공개되지 않는다.

기존 commerce 모드로 돌아갈 때는 overlay 없이 base만 실행한다.

```text
docker compose -f docker-compose.yml up -d
```

이 명령의 namespace는 계속 `commerce-elt`이다. overlay를 생략해도 Marquez 서비스는 계속 실행되지만 Traffic/Weather 전용 namespace와 dbt transport는 주입되지 않는다.

Marquez runtime guardrail은 다음과 같다.

- `marquez-db`, `marquez-api`, `marquez-web`은 각각 `512MB`, `1536MB`, `256MB` memory cap과 `restart: unless-stopped`를 사용한다.
- optional search는 사용하지 않으며 `SEARCH_ENABLED=false`를 명시한다.
- `marquez-api`의 admin endpoint `http://127.0.0.1:5001/healthcheck`가 HTTP `200`이어야 한다.
- `marquez-web`은 healthy `marquez-api` 뒤에 기동한다.
- Airflow scheduler에서 `marquez-api` DNS가 해석되고 metadata API `http://127.0.0.1:5000/api/v1/namespaces`가 HTTP `200`이어야 한다.

## 환경 계약

overlay는 모든 Airflow 런타임 서비스에 아래 값을 동일하게 적용한다.

| 환경 변수 | 값 | 목적 |
| --- | --- | --- |
| `AIRFLOW__OPENLINEAGE__TRANSPORT` | local `marquez-api:5000` HTTP transport | 기존 Marquez 수집 endpoint 재사용 |
| `AIRFLOW__OPENLINEAGE__NAMESPACE` | `ask-seoul-dev-airflow` | dev Traffic/Weather Airflow run 분리 |
| `AIRFLOW__OPENLINEAGE__SELECTIVE_ENABLE` | `true` | 명시적으로 opt-in한 DAG/task만 이벤트 발행 |
| `AIRFLOW__OPENLINEAGE__DISABLE_SOURCE_CODE` | `true` | Python/Bash source code facet 전송 차단 |
| `AIRFLOW__OPENLINEAGE__INCLUDE_FULL_TASK_INFO` | `false` | 전체 task 정보를 custom facet으로 전송하지 않음 |
| `AIRFLOW__OPENLINEAGE__DEBUG_MODE` | `false` | debug payload 출력 비활성화 |
| `ASK_SEOUL_DBT_OPENLINEAGE_ENABLED` | `true` | 도메인 dbt 실행 Module이 실제 phase만 `dbt-ol`로 실행 |
| `ASK_SEOUL_DBT_OPENLINEAGE_URL` / `..._ENDPOINT` | local `marquez-api:5000/api/v1/lineage` | Traffic/Weather helper 전용 dbt model endpoint |
| `ASK_SEOUL_DBT_OPENLINEAGE_NAMESPACE` | `ask-seoul-dev-dbt` | Airflow task와 구분되는 dbt model namespace |

## Traffic/Weather opt-in 경계

`AIRFLOW__OPENLINEAGE__SELECTIVE_ENABLE=true`인 동안에는 lineage 대상 DAG 또는 task에 `enable_lineage()`를 명시해야 한다. Traffic과 Weather DAG만 아래 API를 사용하고 다른 도메인은 opt-in하지 않는다.

```python
from airflow.providers.openlineage.utils.selective_enable import enable_lineage

# DAG 구성 완료 뒤 해당 Traffic 또는 Weather DAG만 opt-in한다.
enable_lineage(dag)
```

overlay 자체는 DAG 코드를 변경하지 않는다. 따라서 Traffic/Weather DAG에 `enable_lineage()`가 없으면 해당 이벤트도 발행되지 않는다. 반대로 다른 도메인이 이 함수를 호출하면 환경 경계를 우회하므로 코드 리뷰에서 차단해야 한다.

Trino OpenLineage event listener는 구성하지 않는다. listener를 Trino 전역에 켜면 Airflow의 selective enable 여부와 관계없이 commerce를 포함한 모든 Trino query가 발행되어 도메인 경계를 깨기 때문이다.

dbt model lineage는 `ASK_SEOUL_DBT_OPENLINEAGE_ENABLED=true`일 때 Traffic/Weather 실행 Module이 실제 `seed`, `run`, `test` phase에 한해 `dbt-ol`을 사용해 수집한다. `parse`, `ls`, `deps`, `source freshness`는 raw `dbt`를 사용하므로 의미 없는 lineage event를 만들지 않는다. `dbt-ol`은 해당 task가 소유한 `manifest.json`과 `run_results.json`을 읽으며, transport가 없을 때 console로 빠지는 동작을 막기 위해 helper가 `ASK_SEOUL_DBT_OPENLINEAGE_*` 값을 표준 client 환경으로 명시적으로 변환한다.

표준 `OPENLINEAGE_URL`, `OPENLINEAGE_ENDPOINT`, `OPENLINEAGE_NAMESPACE`는 Airflow 서비스의 전역 환경에 두지 않는다. 따라서 같은 Airflow runtime에서 다른 도메인이 OpenLineage client나 `dbt-ol`을 사용해도 이 overlay만으로 자동 전송되지 않는다. dbt subprocess에는 source-code location facet 비활성화도 helper가 강제한다.

## 보안 계약

- API key, token, password, `.env` 값은 namespace, job name, dataset URI, request parameter, custom facet에 넣지 않는다.
- Airflow source code/full task info와 dbt source-code location facet 전송은 overlay에서 비활성화한다.
- Marquez host port는 base Compose의 localhost-only binding을 유지한다. 원격 접근이 필요해도 port binding을 넓히지 않고 승인된 tunnel을 사용한다.
- OpenLineage transport에는 내부 service 주소만 사용하며 source API credential을 포함하지 않는다.

이 설정은 일반적인 source code 노출 경로를 차단하지만, DAG가 secret을 task ID나 dataset 이름처럼 안전하지 않은 metadata에 직접 넣는 경우까지 자동으로 정제하지는 않는다.

## Revision-locked local dev 배포

병합된 dev runtime은 `scripts/deploy-dev.ps1`와 `scripts/verify-dev-deploy.ps1`만 사용한다. `deploy-dev.ps1`는 literal `origin/dev`의 DAG/DBT SHA를 detached runtime worktree에 고정하고, base + lineage + generated 순서의 exact 3-file Compose set을 사용한다.

`deploy-dev.ps1`는 stale `project.config_files` label을 남기지 않도록 전체 dev stack을 `--force-recreate`한다. named volume은 보존하지만 실행 중 query/task는 중단될 수 있으므로 Traffic pause와 active Traffic/Weather/Bronze drain을 먼저 확인한다. volume을 삭제하는 `down -v`는 금지한다.

```powershell
powershell.exe -NoProfile -File ./scripts/deploy-dev.ps1
powershell.exe -NoProfile -File ./scripts/verify-dev-deploy.ps1
```

`.runtime/dev/deployment-lock.json`의 `schema_version=2`는 `lineage_overlay_sha256`과 아래 ordered `compose_files`를 기록한다.

1. `docker-compose.yml`
2. `docker-compose.traffic-weather-lineage.yml`
3. `.runtime/dev/docker-compose.generated.yml`

정적 병합 확인도 같은 순서를 사용한다.

```text
docker compose -f docker-compose.yml -f docker-compose.traffic-weather-lineage.yml -f .runtime/dev/docker-compose.generated.yml config --quiet
```

verifier는 secret 원문을 남기지 않고 다음 증거를 모두 검사한다.

- 현재 lineage overlay SHA-256이 lock의 `lineage_overlay_sha256`과 일치한다.
- Airflow, Trino, Marquez 서비스의 Docker `compose labels`가 lock의 ordered exact 3-file set과 일치한다.
- scheduler의 lineage 환경이 Traffic/Weather overlay 계약과 일치하고 `marquez-api` DNS가 해석된다.
- Marquez DB/API/Web의 running·health·memory cap·restart policy·restart count·OOM 상태와 admin/metadata HTTP 응답이 정상이다.
- Airflow pool은 `trino_traffic_heavy=1`, `trino_weather_heavy=1`이고 inventory 전까지 legacy `trino_heavy=1`도 유지한다. 도메인 lane을 분리해 Traffic이 Weather의 slot을 점유하지 못하게 하되, 각 도메인 내부의 Trino write는 직렬화한다.

## Trino Stage1과 explicit Stage2 canary

기본 3-file Stage1은 `trino/resource-groups.json`의 `hardConcurrencyLimit=1`을 유지한다. 이 값은 안전한 rollback 기준이며 `deploy-dev.ps1` 기본 경로에서 임의로 올리지 않는다.

`hardConcurrencyLimit=2`는 static gate, exact-ref mount, 기본 verifier가 모두 통과하고 기존 Traffic DagRun이 없는 경우에만 `docker-compose.trino-hard2-canary.yml`을 네 번째 overlay로 명시해 적용한다.

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

canary는 query memory를 `1280MB` per-node / `1280MB` total user memory, `2560MB` total memory로 제한하고 heap `headroom 2GB`, task concurrency `2`를 적용한다. host의 일반 `TRINO_*` override와 섞지 않고 `TRINO_CANARY_*` 변수만 사용한다. 세 번의 complete Traffic cycle 동안 run id, 전체·resolver·`dbt_test_gold` 시간, Trino memory/restart/OOM, Gold reconciliation, Iceberg write, Weather 대기 시간을 기록한다.

다음 중 하나라도 발생하면 Traffic을 즉시 pause하고 canary를 중단한다.

- Trino `restart/OOM/memory error`
- `Iceberg conflict/duplicate` 또는 exact Gold reconciliation 실패
- runnable `Weather scheduled > 15m`
- 한 cycle의 `Traffic > 30m` 또는 DAG 실패

rollback은 canary overlay만 제거한다. Traffic/Weather pool과 Marquez always-on 서비스는 유지한다.

```powershell
docker compose @canaryCompose exec -T airflow-scheduler airflow dags pause traffic_incident_transform
docker compose @baseCompose up -d --no-deps --force-recreate trino
docker compose @baseCompose exec -T trino sh -c "grep -F '\"hardConcurrencyLimit\": 1' /etc/trino/resource-groups.json"
powershell.exe -NoProfile -File ./scripts/verify-dev-deploy.ps1
```

canary가 실행 중일 때 Trino container의 compose label에는 네 번째 파일이 포함되므로 baseline 3-file verifier를 통과시키려 하지 않는다. canary 자체는 위의 explicit config/runtime assertion과 세 cycle 증거로 판정하고, rollback 뒤 baseline verifier를 다시 통과시킨다.

## Marquez 장애 fail-open probe

다음 probe는 Marquez unavailable 상태가 dbt primary command의 exit status를 바꾸지 않는지 실제 `dbt-ol`로 확인한다.

probe는 Dockerfile의 선언이 아니라 **실행할 image 내부의 실제 설치 버전**을 검사한다. 따라서 `Dockerfile.airflow`의 pin을 바꾼 뒤에는 현재 source로 image를 반드시 다시 빌드해야 한다.

```text
docker compose build airflow-init
```

재빌드하지 않은 stale image는 provider 또는 dbt wrapper 버전 gate에서 실패하며 raw `dbt`와 wrapped `dbt-ol` command를 실행하지 않는다. preflight는 network가 차단된 일회성 container에서 Airflow Python과 격리된 dbt Python을 각각 실행해 `apache-airflow-providers-openlineage==2.19.0`, `openlineage-dbt==1.51.0`과 정확히 일치하는지 확인한다.

```text
python scripts/lineage/probe_dbt_openlineage_fail_open.py --image elt-infra-airflow:local
```

probe는 실행 중인 Compose service를 중단하거나 재시작하지 않는다. 대신 동일한 최소 dbt project를 read-only mount한 일회성 container 두 개를 `docker run --rm --network none`으로 실행한다. 첫 container는 raw `dbt compile`, 두 번째는 wrapped `dbt-ol compile`을 실행하며 두 command의 dbt argument는 같다. `--no-introspect --no-populate-cache`로 adapter의 relation cache와 database introspection을 끄므로 Trino query나 data write가 발생하지 않는다.

wrapped container의 OpenLineage endpoint는 의도적으로 닫힌 `127.0.0.1:1`이다. probe 성공은 다음 조건을 모두 요구한다.

- raw command가 성공한다.
- raw와 wrapped exit code가 같다.
- `dbt-ol` emission warning이 관측된다.
- 동일한 structured log record 또는 최대 8줄의 bounded exception block 안에 emission warning, 닫힌 `127.0.0.1:1` endpoint, `Connection refused`·`HTTPConnectionPool`·`Max retries` 같은 실제 connection failure marker가 함께 있다. 설정 URL만 출력되거나 서로 다른 log record에 흩어진 문자열은 접촉 증거가 아니다.

성공 출력은 subprocess 원문 대신 아래와 같은 고정 요약만 포함한다.

```text
provider_openlineage_version_expected=2.19.0
provider_openlineage_version_match=true
openlineage_dbt_version_expected=1.51.0
openlineage_dbt_version_match=true
image_version_gate_passed=true
raw_exit_code=0
wrapped_exit_code=0
primary_command_succeeded=true
exit_codes_match=true
lineage_warning_observed=true
endpoint_contact_observed=true
probe_status=pass
```

exit code `1`은 위 검증 조건 실패이고, exit code `2`와 `probe_status=blocked`는 Docker CLI, local image, fixture 또는 실행 timeout 때문에 actual probe를 수행하지 못했다는 뜻이다. 어느 경우에도 원문 subprocess output이나 환경 값은 출력하지 않는다.

버전 불일치 때 출력하는 version 값은 source가 기대하는 안전한 exact pin뿐이다. image에서 관측한 임의의 값이나 package command 원문은 요약에 포함하지 않는다.

## 검증과 종료

root 정적 계약 테스트 전체는 다음과 같이 실행한다.

```text
python -m unittest discover -s scripts/tests -v
```

실제 병합 결과는 `.env`의 값을 출력하지 않는 조건에서 다음 명령으로 확인한다.

```text
docker compose -f docker-compose.yml -f docker-compose.traffic-weather-lineage.yml config --no-env-resolution --quiet
```

최종 ready 판정에는 root 파일만으로 충분하지 않다. Traffic/Weather `DAG/DBT commit`이 먼저 생성되고 dev에 병합되어야 하며, revision-locked harness가 그 `origin/dev` exact SHA를 runtime worktree에 mount해야 한다. 로컬 검증은 root submodule `gitlink`가 최신이라고 가정하지 않으며, 팀 공유·CI·handoff 때만 검증된 merge commit으로 pointer를 일괄 갱신한다. 현재 Dockerfile로 image를 재빌드하고 deployment verifier, version gate, actual fail-open probe를 다시 통과해야 한다. 이 조건 중 하나라도 남아 있으면 문서·정적 테스트가 통과해도 배포 준비 완료로 판정하지 않는다.

Marquez UI는 같은 host에서만 `http://localhost:3000`으로 확인한다. 실행 후에는 동일한 파일 조합으로 내린다.

```text
docker compose -f docker-compose.yml -f docker-compose.traffic-weather-lineage.yml down
```
