# serving/ — citydata 골드 D1 서빙 API (프로토타입)

Rapid API식 1차 목표(7/16 회의)의 실물: 골드를 Cloudflare D1로 export하고 Workers가
조회 전용 REST로 서빙한다. 설계 정본:
[specs/2026-07-17-citydata-gold-serving-api-design.md](../dbt/domains/citydata/docs/superpowers/specs/2026-07-17-citydata-gold-serving-api-design.md)

```
[Trino 골드] ──export_gold_to_d1.py──▶ [D1] ◀──src/index.js(Workers)── Agent/사용자
              (전량 교체 스냅샷·멱등)            GET /catalog · /data/{table}
```

## 구성

| 파일 | 역할 |
|---|---|
| `export_gold_to_d1.py` | 골드 12종 → D1 (DROP+CREATE+INSERT 통짜 SQL, 증분 upsert 금지). `_catalog` 는 dbt manifest(description·serving_tier·테스트 게이트)에서 파생 |
| `src/index.js` | Workers — `/catalog`(Agent 진입점) · `/data/{table}` (컬럼 화이트리스트 등호 필터 + `from`/`to` 시간축 + `limit`) · 요청 로그 D1 append |
| `wrangler.toml` | D1 바인딩. 원격 배포 전 `database_id` 교체 필요 |

## 로컬 실행 (인증 불필요 — Miniflare)

```bash
cd serving
python export_gold_to_d1.py        # Trino → 로컬 D1 (sample 스택 기동 전제)
npx wrangler dev --local --port 8787
curl "localhost:8787/catalog"
curl "localhost:8787/data/gold_citydata_place_scorecard?gu=강남구"
curl "localhost:8787/data/gold_citydata_ppltn_daily?from=2026-07-10&to=2026-07-12"
```

## 원격 배포 (CLOUDFLARE_API_TOKEN — Account: D1 Edit + Workers Scripts Edit)

```bash
npx wrangler d1 create ask-seoul-citydata   # 출력된 database_id 를 wrangler.toml 에 반영
python export_gold_to_d1.py --remote
npx wrangler deploy                          # → https://ask-seoul-citydata-api.<subdomain>.workers.dev
# 철거: npx wrangler delete && npx wrangler d1 delete ask-seoul-citydata
```

## 프로토타입 범위 / 다음 단계

- 포함: d1_direct 소형 스냅샷 7종 + charger + 일별 4종 = 12테이블 (검증 완료)
- 다음: hourly 3종·demographics(20만 행) 배치 분할 적재 → export 를 Airflow DAG로 승격
  (transform 후속 스텝) → 스키마 계약은 dbt contract(17종 부착됨)가 상류에서 보장
