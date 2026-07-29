# serving-gateway — V1 마켓플레이스 프로토타입 (ASK-Seoul#58)

팀 D1 에 적재된 6개 도메인 서빙 제품(등록 62종 중 **공개 59종** — 아래 '공개 게이트' 참고)을
**키 발급 + 일일 쿼터** 게이트 뒤에서 제공하는
Workers + Static Assets + D1 웹서비스. #476 게이트웨이 역할(키 검증·rate limit·통합
카탈로그)의 로컬 실물 검증이자, #55 "프로토타입 검증 → 팀 이관" 경로의 산출물.

## ⚠️ 로컬 전용

- 구동은 `wrangler dev`(로컬 Miniflare sqlite D1)뿐. **`wrangler deploy` 금지** —
  공개 URL 신설은 멘토 게이트(#476 결정 ①·ASAC-DAG#521-(B)).
- 팀 D1 에는 아무것도 쓰지 않는다. wrangler.toml 의 database_id 는 로컬 모드에서
  사용되지 않는다(시드는 전부 `.wrangler/` 로컬 상태).

## 실행

```bash
cd serving-gateway
npm install          # wrangler
npm run seed         # migrations + fixtures/seed.sql → 로컬 D1
npm run dev          # http://localhost:8787
npm run usage        # 사용 리포트 (아래 '사용 계측' 참고)
```

## API

| 엔드포인트 | 인증 | 설명 |
|---|---|---|
| `POST /api/keys` `{email}` | — | 키 발급(1회 표시). 이메일당 1키 — 재요청 = rotate(기존 키 즉시 무효, **오늘 사용량 승계** = rotate 로 쿼터 리셋 불가). IP당 시간당 5회 |
| `DELETE /api/keys` | Bearer | **폐기** — 키 즉시 무효(이후 403). `?purge=true` 면 이메일·사용량까지 삭제. 폐기된 키로도 호출 가능(아래 '키 폐기') |
| `GET /api/catalog` | — | **공개 제품** 목록(계약 v1.1 `_catalog` 15컬럼) + `attribution` 문구 |
| `GET /api/data/<table>` | Bearer | 조회. `<col>=<val>` 등가 필터 · `from`/`to`(time_axis) · `limit`(≤5000) · `cursor`(아래 '페이지네이션'). 유효 요청만 쿼터 소모(400/404/409 무과금), 초과 시 429 |
| `GET /api/me` | Bearer | 오늘 사용량/쿼터 (쿼터 무소모) |

## 사용 계측 — 무엇이 실제로 쓰이나

`_request_log` 에 API 요청을 한 줄씩 남긴다(`ctx.waitUntil` 로 응답을 붙잡지 않으며,
로그 쓰기가 실패해도 응답에 영향이 없다). `npm run usage` 로 질문 7개를 한 번에 조회:

| 리포트 | 답하는 질문 |
|---|---|
| ① 라우트별 · ② 일자별 | 규모와 추세 — 늘고 있나 |
| ③ 제품별 (preview vs data) | **구경만 하고 떠나나, 실제로 쓰나** — 퍼널 |
| ④ 필터축 | 어떤 컬럼으로 자르나 — 인덱스·계약 우선순위 |
| ⑤ 실패(404·400) | **없어서 못 판 것** — 그대로 로드맵 |
| ⑥ 조용한 0행 | 200인데 빈 응답 — 커버리지 구멍 |
| ⑦ 키별 | 발급만 받고 만 키 vs 여러 날 돌아온 키 |

### 운영 화면은 별도 프로젝트다

서빙 품질을 사람이 보는 화면은 **[ops-console](../ops-console/)** 에 있다 — 마켓플레이스와
다른 Worker · 다른 호스트다. 청중이 다르고(외부 고객 vs 운영자), 배포 단위가 갈려야 사고
반경도 갈리기 때문이다. 그쪽 콘솔은 이 게이트웨이의 `_request_log` 와 파이프라인 SLO 를
한 화면에서 본다.

여기(`npm run usage`)는 같은 질문을 SQL 로 보는 경로로 남겨 둔다.

수집 원칙 3가지 — 스키마 주석([migrations/0002_request_log.sql](migrations/0002_request_log.sql))에 근거를 남겼다:

- **값이 아니라 축만** — 필터는 컬럼명만 저장하고 값은 버린다. 알고 싶은 건
  "어떤 축으로 자르나"이지 "누가 뭘 찾았나"가 아니다.
- **식별자는 이미 해시인 것만** — `key_hash` 만. 이메일·IP 는 넣지 않는다.
  익명 미리보기는 `key_hash` 가 NULL 이라 사람 단위 집계가 불가능한데, 그게 의도다.
- **보존 30일** — D1 은 DB당 10GB 라 코드가 기한을 강제한다(크론 없이 Worker 가 확률적 정리).

## 제한 두 층 — 쿼터(공정성)와 버스트(가용성)

목적이 달라서 따로 센다. **쿼터**는 "한 사람이 하루에 얼마나"(키당 1,000건/일, KST 자정 리셋),
**버스트**는 "한 사람이 지금 이 순간 얼마나"(분당 60건)다. 하나만 두면 한쪽이 빈다 — 쿼터만
있으면 1,000건을 1초에 밀어넣을 수 있고, 버스트만 있으면 하루 종일 최고 속도로 퍼갈 수 있다.

- 인증 요청은 **키별**(`k:<hash>`), 익명 미리보기는 **IP별**(`ip:<addr>`) 버킷. 미리보기는
  키가 없어 셀 식별자가 IP 뿐이다 — NAT 뒤 여러 사용자가 예산을 나눠 쓰게 되는 건 한계다.
- 초과 시 `429 burst rate limited` + **`Retry-After` 헤더**. 언제 다시 오라고 안 알려주면
  클라이언트가 즉시 재시도해서 상황을 더 나쁘게 만든다.
- **버스트를 쿼터보다 먼저 본다** — 400·404 로 끝날 요청도 서버를 미는 건 같기 때문이다.
  그래서 버스트로 막힌 요청은 **쿼터를 소모하지 않는다**(실측: 66회 시도 → 통과 60·쿼터 60).
- 분 단위 **고정 창**이라 창 경계에서 최대 2배까지 통과할 수 있다. 슬라이딩 창은 요청마다
  타임스탬프 로그가 필요해 이 규모엔 과하다 — 가용성 보호가 목적이라 그 오차는 견딘다.
- 카운터는 [`migrations/0003_burst.sql`](migrations/0003_burst.sql). **버킷당 한 행**이라
  키는 아무리 오래 써도 행이 안 늘고, 익명 IP 행만 `_request_log` sweep 에 얹어 함께 지운다.

## 키 폐기 — 폐기와 삭제는 다르다

`DELETE /api/keys` 는 **폐기**(`status='revoked'`)다. 키는 즉시 403 이 되지만 이메일 행은 남아
같은 주소로 재발급(rotate)할 수 있다. `?purge=true` 는 거기서 더 나아가 **이메일·사용량·버스트
버킷까지 지운다** — 처리방침이 약속한 삭제 요청의 셀프 경로다.

두 가지 설계 결정:

- **폐기된 키로도 이 엔드포인트는 통과한다**(`authenticate(..., {allowRevoked:true})`).
  폐기가 삭제의 문을 닫으면 "지울 권리"가 폐기 순서에 걸려 사라진다.
- **요청 로그는 남는다**(30일 보존 그대로). 다만 purge 로 해시→이메일 대응이 사라지므로
  남은 `key_hash` 는 사람과 연결되지 않는다. 처리방침에 그대로 적었다.

남용 대응 폐기(약관의 "사전 통지 없이")는 공개 엔드포인트가 아니라 운영자의 D1 조작이다 —
`UPDATE _keys SET status='revoked' WHERE key_prefix = ?`.

## 페이지네이션 — offset 이 아니라 rowid 키셋 커서

`limit` 상한이 5,000 이라 큰 제품(weather `risk_window` 30만 행)은 한 번에 다 못 받는다.
`/api/data` 응답의 **`next_cursor`** 를 다음 요청의 `cursor` 로 그대로 넣으면 이어서 받는다.
`has_more` 가 `false` 면 `next_cursor` 는 `null` 이다.

```bash
curl -H "Authorization: Bearer $KEY" "$BASE/api/data/gold_weather_place_risk_window?limit=5000"
curl -H "Authorization: Bearer $KEY" "$BASE/api/data/gold_weather_place_risk_window?limit=5000&cursor=<next_cursor>"
```

**offset 을 안 쓴 이유는 성능이 아니라 정확성이다.** 제품은 매일 스냅샷으로 통째 재적재되고
append 제품은 계속 늘어난다. 그 사이 `offset` 은 같은 행을 두 번 주거나 건너뛴다. `rowid` 는
한 발행 안에서 유일·단조라 "여기서부터 이어서"가 정확하고, 정렬(`ORDER BY rowid`)이 붙으면서
페이지를 안 쓰는 소비자에게도 응답 순서가 결정적으로 바뀐다.

대신 `rowid` 는 재적재마다 새로 매겨지므로 **커서에 발행 시각(`exported_at`)을 함께 실었다.**
다른 발행의 커서로 이어받으려 하면 조용히 유실되는 대신 **409 `cursor expired`** 가 뜬다
(응답에 현재 `exported_at` 을 실어 준다). 커서·필터·기간은 함께 쓸 수 있고, `limit+1` 을 떠서
`has_more` 를 실측하므로 마지막 페이지가 꽉 차도 빈 페이지가 한 번 더 오지 않는다.
**페이지마다 쿼터 1건**을 쓴다.

## 공개 게이트 — 등록 ≠ 공개

세 조회 경로(`/api/catalog`·`/api/preview/*`·`/api/data/*`)가 전부 **`external = 1`** 로
필터한다. `_catalog` 등록은 "publisher 가 실었다"는 사실이고, 공개는 도메인 오너가
계약(`meta.serving`)에 `external` 을 켰다는 **의사표시**다. 이 구분이 없으면 어느 도메인이
내부용 마트를 등록하는 순간 그대로 공개된다.

- **NULL(미선언)은 공개하지 않는다** — 옵트인이 안전한 기본값.
- 비공개 제품 조회는 **403 이 아니라 404** — 403 은 "있긴 있다"를 알려주는 셈이다.
- 실측(2026-07-29): 라이브 등록 62종 중 **59종 공개**. 빠지는 3종은 transit
  `event_access`·`forecast_card`·`parking_profile` 로, 구 `d1_direct` 경로로 등록돼
  `product_id`·`external` 이 비어 있다. 오너가 계약에 선언하면 자동으로 합류한다.

## 법적 고지 — [public/legal.html](public/legal.html)

출처·이용약관·개인정보 처리방침 3종. **법률 검토 전 초안**이며 페이지 상단에 그렇게 명시한다.
배치 원칙 둘: 고지는 **수집 지점**(키 발급 폼)에 있어야 의미가 있고, 출처는 화면을 거치지 않는
API 소비자에게도 닿아야 해서 `/api/catalog` 응답에 `attribution` 을 함께 싣는다.

정식 공개 전 해소할 항목은 처방침의 '알려진 한계'에 적어 뒀다 — 발급 IP 무만료·이메일 평문
저장·이메일 소유 확인 부재.

## 보안 규약

- **키 원문 무저장** — D1 에는 SHA-256 해시 + 표시용 접두 8자만(`_keys`).
  발급 응답이 원문의 유일한 노출 지점.
- 쿼터 하루 경계 = KST (파이프라인 규약과 동일).

## fixtures

`fixtures/seed.sql` 은 커밋되어 있어 토큰 없이 시드 가능. 재생성(팀 D1 읽기,
`CLOUDFLARE_API_TOKEN` 필요): `python fixtures/build_fixtures.py`. `_catalog` 는
라이브(16컬럼)가 아닌 **계약 v1.1 15컬럼 목표 상태**의 픽스처다(ASAC-DAG#521 참조).

생성기가 알아야 할 것 세 가지:

- **계약값은 라이브 `_catalog` 가 정본**이다 — 타 도메인 제품의 설명·질문·시간축은
  그대로 옮긴다. 예외는 culture 7종으로, 라이브에 아직 행이 없어(계약 선언
  ASAC-DBT#346 리뷰 중) 생성기의 `CULTURE_PRODUCTS` 가 목표 상태를 대신 싣는다.
- **표본은 '오늘 근처'** — 과거쪽 최신 + 미래쪽 최근접을 섞어 테이블당 50행.
  미리보기가 표본 안에서 시간축 내림차순 5행을 보여주므로, 뜨는 방식이 그대로
  화면이 된다(앞쪽 rowid 를 뜨면 실시간 제품이 몇 달 전 값을 보여준다).
- **표시명은 생성물** — `public/product-display.json`. 계약에 display 필드가 없어
  서빙 응답에 안 실려오기 때문이고, 두 화면(`index.html`·`catalog.html`)이 같은 파일을
  읽는다. 계약 v1.2 에 들어가면 이 파일과 생성기의 `DISPLAY` 표는 지운다(#476).

## 승격 경로 (배포 게이트에 동승할 것)

- 키 발급 ① 즉시발급 → ④ GitHub OAuth (org OAuth 앱 등록 필요)
- rate limit: 분 단위 버스트 제한(현재는 일일 쿼터만)
- `_issuance_log` 주기 정리(현재 무만료)
