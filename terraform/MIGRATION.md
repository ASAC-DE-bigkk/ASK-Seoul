# AWS 이전 작업 순서 — 테스트 레인 신설 + Airflow/Trino 분리

로컬 도커 스택(prod 카탈로그 직결)을 **격리된 테스트 레인 + EC2 2대**로 옮기는 절차.

- 인프라 정의: [terraform/](.) — `terraform apply` 하나로 EC2 2대까지 올라간다
- 사이징 근거: `resource-reports/` — 6개 도메인 실측
- **이 문서는 절차서다.** 아직 결정되지 않은 항목은 §7에 따로 모았고, docs/ 로 옮기지 않는다.

---

## 1. 확정된 규약 — 환경 전환은 "키가 아니라 값"

먼저 이걸 알고 시작해야 한다. 커밋 `77ea32f`(#75)·`662cb98`에서 확정된 내용이다.

> 자격증명 키 이름은 배포 환경을 담지 않는다. canonical `R2_*` 한 세트뿐이고,
> **어느 버킷을 가리키는지는 그 키의 '값'이 정한다.**

[.env.example](../.env.example)에 경고가 박혀 있다.

> ⚠️ `R2_DEV_*` 를 되살리지 말 것 — 채우는 순간 같은 날짜의 운영 기록이 두 버킷으로
> 갈린다 (ASK-Seoul#78 Z-7). 코드에서도 해당 분기를 제거했다(ASAC-DAG#647).

**따라서 새 키를 만들지 않는다.** `.env.<레인>` 파일을 한 벌 더 만들고 값만 채운다.
`.env.dev` / `.env.prod` 가 이미 동일한 키 세트를 쓰고 있으므로 세 번째 레인을 추가하는 형태다.

카탈로그 전환도 파일을 새로 만들지 않는다. [docker-compose.yml:170](../docker-compose.yml#L170)이
템플릿 하나(`trino/iceberg.properties`)를 `${TRINO_ICEBERG_CATALOG}.properties` 경로로
마운트하므로, **env 값 하나가 카탈로그 이름이 된다.**

---

## 2. 이름 — 확정

계정: `Dy950328@gmail.com's Account` (`CLOUDFLARE_ACCOUNT_ID` = `SERVING_CLOUDFLARE_ACCOUNT_ID`, 동일)

| 대상 | 이름 | 상태 |
|---|---|---|
| R2 버킷 | `ask-seoul-test` | ⏳ 미생성 — §3 참조 |
| Iceberg 카탈로그 | `iceberg_test` | ⏳ 버킷 생성 후 |
| **D1 데이터베이스** | **`ask-seoul-test-d1`** | ✅ **생성 완료 (2026-08-07)** |
| env 파일 | `.env.test` | ⏳ |
| SSM 경로 | `/ask-seoul/test/*` | Terraform IAM 정책이 `/ask-seoul/*` 커버 |

**생성된 D1**

```
name : ask-seoul-test-d1
uuid : 06607fa1-1b9f-4cdf-bd17-0d4648c35c64     ← SERVING_D1_DATABASE_ID 에 넣는다
```

기존 D1 대조 (같은 계정):

| 이름 | uuid | 비고 |
|---|---|---|
| `ask-seoul-prod-d1` | `59a8409e-…` | 테이블 90개 / 182 MB / **현재 `.env` 가 이걸 봄** |
| `ask-seoul-dev-d1` | `9db0e851-…` | |
| `ask-seoul-test-d1` | `06607fa1-…` | 신규 |

---

## 3. Cloudflare 사전 준비 (4가지)

### ✅ 4. D1 데이터베이스 — 완료

`.env` 의 `CLOUDFLARE_API_TOKEN` 으로 API 생성했다. §2 에 uuid 기록.

### 🔴 1·2·3. R2 — 막혔다: 토큰에 R2 권한이 없다

```
GET /accounts/{id}/r2/buckets
→ {"success":false,"errors":[{"code":10000,"message":"Authentication error"}]}
```

같은 토큰으로 **계정 조회와 D1 은 성공**하므로 토큰 자체는 유효하다(`status: active`).
**R2 스코프만 빠져 있다.** `.env` 의 `CLOUDFLARE_API_TOKEN` 은 D1/Workers 용으로 발급된 것이다.

#### 뚫는 방법 두 가지

**(a) 대시보드에서 수동 — 권장**

어차피 3번(R2 자격증명)은 대시보드에서만 만들 수 있으므로 한 번에 처리하는 게 빠르다.

1. **버킷 생성** — R2 → Create bucket → 이름 `ask-seoul-test`
   - Location: `APAC` (서울 워크로드)
2. **Data Catalog 활성화** — 만든 버킷 → Settings → R2 Data Catalog → Enable
   - 활성화 후 표시되는 **Catalog URI** 와 **Warehouse** 를 적어둔다
     → `R2_DATA_CATALOG_URI`, `R2_DATA_CATALOG_WAREHOUSE`
3. **R2 API 토큰** — R2 → Manage API Tokens → Create API Token
   - 권한: **Object Read & Write**
   - 대상: **Specify bucket → `ask-seoul-test` 만** (prod 버킷 포함 금지)
   - 산출물 3개:
     - `R2_ACCESS_KEY_ID` — Access Key ID
     - `R2_SECRET_ACCESS_KEY` — Secret Access Key
     - `R2_DATA_CATALOG_TOKEN` — 화면 상단의 **Token value** (액세스키와 다른 값)
   - `R2_ENDPOINT` 도 이 화면에 표시된다 (`https://<account_id>.r2.cloudflarestorage.com`)

**(b) R2 권한 토큰을 새로 발급해 스크립트 사용**

My Profile → API Tokens → Create Token → 권한에 **`Workers R2 Storage: Edit`** 추가.
그 토큰을 환경변수로 넘기면 기존 스크립트가 1·2 번을 처리한다.

```bash
CLOUDFLARE_API_TOKEN=<r2-edit-token> R2_BUCKET_NAME=ask-seoul-test \
  bash scripts/bootstrap-cloudflare.sh
```

> ⚠️ 이 스크립트는 `npx wrangler` 를 쓴다 — wrangler 가 없으면 npm 이 받아온다.
> 3번(R2 자격증명)은 어차피 대시보드에서만 만들 수 있으므로 (a) 가 대체로 빠르다.

#### 완료 후 검증

```bash
bash scripts/check-r2-catalog-auth.sh
```

---

## 4. `.env.test` 작성

**이 파일은 실키를 담으므로 직접 채운다.** `.env.prod` 를 복사해 값만 비우고 시작하면 된다.

| 키 | 채울 값 |
|---|---|
| `R2_BUCKET_NAME` | `ask-seoul-test` |
| `R2_ENDPOINT` | `https://<account_id>.r2.cloudflarestorage.com` |
| `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` | 3번 산출물 |
| `R2_DATA_CATALOG_URI` / `_WAREHOUSE` | 1·2번 스크립트 출력 |
| `R2_DATA_CATALOG_TOKEN` | 3번 산출물 |
| **`TRINO_ICEBERG_CATALOG`** | **`iceberg_test`** ← 카탈로그 전환의 전부 |
| `SERVING_D1_DATABASE_ID` | 4번 산출물 |
| `WRANGLER_R2_SQL_AUTH_TOKEN` | 3번 산출물 |
| `R2_RAW_PREFIX` | `raw` (그대로 — 존 루트만, #60) |
| `COMMERCE_R2_REGION` | 그대로 |
| `TRINO_HOST` | 로컬 검증 중엔 `trino`, EC2 분리 후엔 Trino 사설 IP |

**절대 하지 말 것**: `R2_DEV_*` 같은 접두사 키 추가 (§1 참조).

---

## 5. 로컬에서 먼저 검증

EC2 로 가기 전에 새 레인이 도는지 로컬에서 확인한다. 인프라 변수를 섞지 않기 위해서다.

```bash
cp .env.test .env          # 백업 먼저: cp .env .env.bak.$(date +%Y%m%d)
docker compose up -d
docker compose exec trino trino --execute "SHOW CATALOGS"   # iceberg_test 가 보여야 함
```

DAG 하나만 켜서 bronze 적재까지 확인한 뒤 다음 단계로 간다.

---

## 6. AWS 인프라

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # admin_cidr 를 본인 IP 로
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

생성물 16개와 비용은 [README.md](README.md) 참조. **온디맨드 월 약 $286.**

시크릿 등록 (값은 직접 입력):

```bash
aws ssm put-parameter --name "/ask-seoul/test/R2_ACCESS_KEY_ID" \
  --type SecureString --value "..." --region ap-northeast-2
# 나머지 키도 동일하게
```

---

## 7. compose 를 2벌로 분리 — 손봐야 할 5가지

코드는 이미 원격 Trino 를 상정하고 있다. **이미 준비된 것**:

| 항목 | 상태 |
|---|---|
| `TRINO_HOST` / `TRINO_PORT` env | ✅ 존재 (기본 `trino` / `8080`) |
| dbt profiles 6개 | ✅ 전부 `env_var('TRINO_HOST', 'trino')` |
| `dags/common/serving/runtime.py:174` | ✅ `os.environ.get("TRINO_HOST", "trino")` |
| Airflow → Trino `depends_on` | ✅ **없음** — 분리에 걸림돌 없음 |

**손봐야 할 것**:

1. **`TRINO_HOST` 하드코딩 해제** — [docker-compose.yml:25](../docker-compose.yml#L25)에
   `TRINO_HOST: trino` 로 박혀 있다. env 참조로 바꿔야 사설 IP 를 넣을 수 있다.
2. **compose 2벌 분리**
   - Airflow 노드: `postgres` + `airflow-init/apiserver/scheduler/dag-processor/triggerer`
   - Trino 노드: `trino` 단독
   - `elt_net` 은 각 노드의 로컬 브리지가 된다
3. **노드별 파일 배치**
   - Trino 노드: `trino/` (iceberg·jvm·config·resource-groups) + `.env`
   - Airflow 노드: `dags/` `dbt/` `plugins/` `Dockerfile.airflow` + `.env`
4. **spill 경로 바인드** — EC2 의 NVMe 마운트(`/mnt/trino-spill`)를 컨테이너
   `/tmp/trino-spill` 에 바인드. Terraform 이 마운트까지는 해뒀다
   (`trino-spill.service`, 매 부팅 재생성)
5. **Trino 포트 바인드** — ⚠️ **미결. 아래 §8 참조**

---

## 8. ✅ 결정됨 — Trino 포트 바인드는 B안 (2026-08-07)

**임시 테스트 레인이므로 B안(사설 IP 바인드 + 보안그룹)으로 간다.**
업계 표준 구성이기도 하다 — [Trino 공식 블로그](https://trino.io/blog/2022/07/13/how-to-use-airflow-to-schedule-trino-jobs.html)가
Airflow Connection 의 Host 에 사설 IP 를 직접 넣는 예시를 든다.

다만 [Trino Security overview](https://trino.io/docs/current/security/overview.html) 는
**"내부망이니 TLS·인증을 생략해도 된다"는 예외를 인정하지 않는다.** 권고 순서가
TLS → shared secret → 인증 → 접근제어이므로, **B 는 표준의 1단계만 한 상태다.**
이걸 그대로 운영으로 승격하려면 A(TLS + password 인증)까지 가야 한다.

### 적용된 보완책 3가지

의도(무인증 Trino 미노출)가 완전히 사라지지 않도록 아래를 함께 넣었다.

1. **Trino 는 `admin` SG 를 달지 않는다** — [compute.tf](compute.tf) `trino_security_group_ids`.
   관리자 IP 에도 8080 을 열지 않는다. Airflow 노드만 `admin` SG 를 단다.
2. **바인드 IP 와 발행 포트를 변수화, 기본값은 기존 그대로**
   — [docker-compose.yml](../docker-compose.yml) `${TRINO_BIND_IP:-127.0.0.1}:${TRINO_PUBLISH_PORT:-30586}:8080`.
   **로컬 동작은 1비트도 바뀌지 않는다.** 분리 배포에서만 값을 넣는다. `0.0.0.0` 금지.
3. **Trino UI 는 SSM 포트 포워딩으로** — 포트를 열지 않고도 붙는다.
   ```bash
   aws ssm start-session --target <trino-instance-id> \
     --document-name AWS-StartPortForwardingSession \
     --parameters '{"portNumber":["8080"],"localPortNumber":["30586"]}'
   ```

### 남은 리스크 (수용함)

방어가 "호스트 경계"에서 "SG 규칙"으로 옮겨갔다. **VPC 에 인스턴스가 추가되고 그것이
`internal` SG 를 달면 무인증 Trino 에 접근할 수 있다.** `internal` SG 는 자기참조 전포트
허용이므로, 이 SG 를 다는 리소스를 늘릴 때 반드시 검토한다.

<details>
<summary>기각된 대안 (기록용)</summary>

- **A) Trino 에 인증 추가** — 원 의도를 지키고 Trino 공식 권고를 충족하지만 작업량이 하루 이상.
  운영 승격 시 재검토 대상.
- **D) Docker Swarm 오버레이로 `elt_net` 을 두 노드에 확장** — 포트를 아예 publish 하지 않아
  의도를 그대로 지키고 코드 변경도 최소지만, EC2 분리 배포의 일반적 패턴이 아니다.
  Swarm 이 유지보수 모드이고 `docker compose` + overlay 혼용은 팀이 디버깅하기 어렵다.

</details>

### (원문 보존) 왜 결정이 필요했나

**깨지는 의도**: Trino HTTP 포트를 호스트 루프백에만 바인드해 LAN 에 노출하지 않는다.

**출처**: 커밋 `6baad32`, [docker-compose.yml:175-177](../docker-compose.yml#L175-L177)
— "Trino 기본 인증 없음 → 127.0.0.1 전용 바인드(LAN 미노출)"

**원래 회피하려던 시나리오**: Trino 는 인증이 없다. 접근 가능한 네트워크에 있는 누구든
전 도메인 Iceberg 테이블을 읽고 쓸 수 있다. 루프백 바인드는 "이 호스트에서만"으로
물리적으로 막는 장치다.

**왜 걸리나**: Airflow 를 별도 노드로 빼면 다른 호스트에서 Trino 에 붙어야 하므로
루프백 바인드로는 **동작 자체가 불가능하다.** 어떤 형태로든 바인드를 넓혀야 하고,
그 순간 "호스트 경계로 막는다"는 불변식이 "보안그룹으로 막는다"로 바뀐다.

→ **결론은 위 §8 상단 참조 (B안 채택, 보완책 3가지 적용).**

---

## 9. 실제 배포 결과 — 2026-08-07 ✅

테스트 레인을 AWS에 올려 **적재까지 확인 완료**. 인스턴스는 정지해 뒀다.

### 만들어진 것

| 리소스 | 값 |
|---|---|
| AWS 계정 | `068381293928` (리전 `ap-northeast-2`, AZ `2a`) |
| Airflow 노드 | `i-0ad862fce5ded6d53` · m7g.xlarge · 사설 `10.20.1.76` |
| Trino 노드 | `i-01cdc86a00f60c019` · r7gd.large · 사설 **`10.20.1.12`** |
| 스테이징 버킷 | `ask-seoul-test-staging-068381293928` |
| SSM 시크릿 | `/ask-seoul/test/env` (SecureString, Advanced, 85키) |
| Terraform | 21개 리소스 |

### 적재 검증 — 통과

시작 시 완전히 빈 레인이었다.

```
R2 버킷 ask-seoul-test
  시작:  0 객체
  1시간 뒤: 4,683 객체 / 225,415,987 bytes (215 MB)
  프리픽스: __r2_data_catalog/ · ops/ · raw/ · reference/

Iceberg 카탈로그 iceberg_test
  시작:  {"namespaces":[]}
  1시간 뒤: transit · citydata · culture · common · commerce · weather_traffic_bronze
```

동작 확인:
- Airflow → Trino 크로스 노드: `TRINO_HOST=10.20.1.12` → `status 200`, `state: ACTIVE`, v482
- NVMe spill: `/dev/nvme1n1 110G` → `/tmp/trino-spill`
- Trino 외부 접근: 차단됨 (SG)
- DAG import 에러: **0건**

### 🔴 분리 배포에서 나온 "단일 호스트 전제" 하드코딩 4건

전부 **기본값을 보존하는 방식**으로 고쳤다 — 로컬 동작은 바뀌지 않는다.

| # | 위치 | 증상 | 조치 |
|---|---|---|---|
| 1 | `docker-compose.yml` `TRINO_HOST: trino` | Airflow가 Trino를 못 찾음 | `${TRINO_HOST:-trino}` |
| 2 | `terraform` SG가 8080 개방 | **UI는 30585**라 접근 불가 | `airflow_ui_port` 변수(기본 30585) |
| 3 | `airflow-scheduler` `depends_on: trino` | Airflow 노드에 **mem_limit 9g Trino 중복 기동** | `docker-compose.cloud-airflow.yml` 오버레이 |
| 4 | `AIRFLOW__API__BASE_URL: http://localhost:30585` | **UI 접속 시 localhost로 리다이렉트** | `${AIRFLOW_API_BASE_URL:-...}` + IMDS로 공인 IP 주입 |

추가로 `spiller-spill-path` 가 컨테이너 `/tmp`(=EBS)에 얹히는 문제를
`docker-compose.cloud-trino.yml` 오버레이로 NVMe에 바인드했다.

> 3번이 특히 값비쌌다. `docker compose up -d <서비스>` 가 `depends_on` 을 따라가므로
> **서비스만 골라 올리는 것으로는 노드 분리가 되지 않는다.**

### 🔴 테스트 레인이 커버하지 못하는 것 — traffic · weather

`dags/common/runtime_guard.py` 가 **타깃(dev|prod)과 카탈로그·버킷 값을 고정 쌍으로** 요구한다.

```python
_EXPECTED_CATALOG   = {"dev": "iceberg_dev", "prod": "iceberg"}
_R2_EXPECTED_BUCKET = {"dev": "seoul-dev",   "prod": "seoul"}
TARGET_CHOICES      = ("dev", "prod")
```

테스트 레인은 **세 번째 환경**이라 통과할 수 없다 (`RuntimeTargetError: prod catalog must be iceberg`).
가드 대상은 `_DOMAIN_SCHEMA_DEFAULTS` 의 **traffic · weather 두 도메인뿐**이라
transit·citydata·culture·common 은 영향이 없었다.

**가드를 건드리지 않고 두 도메인을 제외**하는 쪽을 택했다. 이 가드는
커밋 `0739845`(#647) · `533cf1e`(#586) · `90ed7eb` 로 이어지는 의도적 안전장치이고,
막으려는 사고가 명확하다.

> 분기를 남겨 두면 누가 `R2_DEV_*` 를 채우는 순간 **같은 날짜 기록이 두 버킷으로 갈린다**
> (ASK-Seoul#78 Z-7). 타깃이 가르는 것은 키 이름이 아니라 **버킷 값**이다.

**운영 승격 시 반드시 풀어야 하는 제약이다.** 후보는 `TARGET_CHOICES` 에 `test` 를 추가하고
`_EXPECTED_CATALOG` / `_R2_EXPECTED_BUCKET` 에 대응 값을 넣는 것(dbt profiles 6개도 함께).
가드의 성질은 유지되고 레인만 하나 는다.
**이건 `#647` 이 세운 2-레인 전제가 3-레인 요구와 부딪힌 첫 사례이므로 이슈로 남길 것.**

### commerce 제외

주어진 활성 목록에 **`commerce_load_bronze` 가 빠져** 체인이 끊겨 있었다
(`collect_raw` → ✗ → `load_silver` → `load_gold`). 결과는 `load_gold` fail=22/upfail=23,
`load_silver` fail=3/upfail=14. 도메인 전체를 정지했다.

### 최종 활성 DAG 29개

```
transit 12 · citydata 8 · culture 6 · common 3
(제외: traffic 7 + weather 4 = 가드 / commerce 7 = 체인 끊김)
```

남은 실패는 전부 `TABLE_NOT_FOUND` — 빈 카탈로그라 gold 가 아직 없어서이며
bronze → silver → gold 가 채워지면 해소된다. 인증·연결·메모리 에러는 0건.

### 운영 스크립트 (S3 스테이징 버킷)

```
deploy.tar.gz        작업트리 아티팩트 (커밋 없이 배포 — 저장소 3개가 전부 private)
deploy-trino.sh      Trino 노드 배포
deploy-airflow.sh    Airflow 노드 배포 (IMDS로 공인 IP 주입)
status.sh            컨테이너·태스크·리소스·에러 8개 섹션
dagcheck.sh          import 에러·DAG별 성패·에러 패턴 집계
```

실행:

```bash
aws ssm send-command --region ap-northeast-2 --instance-ids <id> \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["aws s3 cp s3://ask-seoul-test-staging-068381293928/status.sh /tmp/s.sh --region ap-northeast-2 --quiet && bash /tmp/s.sh 2>&1"]'
```

### 재기동 절차

```bash
aws ec2 start-instances --region ap-northeast-2 \
  --instance-ids i-0ad862fce5ded6d53 i-01cdc86a00f60c019
```

⚠️ **공인 IP가 바뀐다.** 재기동 후 반드시:
1. `terraform apply` — SG의 `admin_cidr` 는 그대로지만 output 갱신
2. `deploy-airflow.sh` 재실행 — IMDS에서 새 IP를 읽어 `AIRFLOW_API_BASE_URL` 갱신 (안 하면 UI가 localhost로 튕김)
3. NVMe spill 은 `trino-spill.service` 가 부팅 시 자동 재생성 (데이터는 휘발)

### 알아둘 함정

- **`.env` 를 SSM에 넣을 때 한글 주석이 있으면 AWS CLI가 실패한다** (Windows 기본 인코딩으로 읽음).
  키=값 라인만 남기면 통과한다 — 주석은 런타임에 영향 없다.
- **`while read < file` 안에서 `docker compose exec -T` 를 쓰면 stdin 을 먹어 첫 줄만 처리된다.**
  파일을 컨테이너 stdin 으로 한 번에 넘기고 안에서 루프를 돌 것.
- `.env.test` 는 `.env.prod` 복사본이라 `DBT_TARGET=prod` 다. 이 값이 런타임 가드 판정을 좌우한다.

## 10. 롤백

| 대상 | 방법 |
|---|---|
| 로컬 env | `cp .env.bak.<날짜> .env && docker compose up -d` |
| AWS 인프라 | `terraform destroy` — EBS 도 함께 삭제되므로 **Airflow 메타DB 백업 후** |
| R2 테스트 버킷 | 대시보드에서 삭제. ⚠️ 카탈로그 soft-delete 함정 주의 (dev 재구축 8/6 사례) |
| D1 테스트 DB | 대시보드에서 삭제 |

**prod 데이터는 어느 단계에서도 건드리지 않는다.** 테스트 레인은 버킷·카탈로그·D1 이
전부 별개이므로 격리된다.
