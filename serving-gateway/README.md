# serving-gateway — V1 마켓플레이스 프로토타입 (ASK-Seoul#58)

culture D1 데이터(외부 gold 7종)를 **키 발급 + 일일 쿼터** 게이트 뒤에서 제공하는
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
```

## API

| 엔드포인트 | 인증 | 설명 |
|---|---|---|
| `POST /api/keys` `{email}` | — | 키 발급(1회 표시). 이메일당 1키 — 재요청 = rotate(기존 키 즉시 무효, **오늘 사용량 승계** = rotate 로 쿼터 리셋 불가). IP당 시간당 5회 |
| `GET /api/catalog` | — | 서빙 제품 목록(계약 v1.1 `_catalog` 15컬럼) |
| `GET /api/data/<table>` | Bearer | 조회. `<col>=<val>` 등가 필터 · `from`/`to`(time_axis) · `limit`(≤5000). 유효 요청만 쿼터 소모(400/404 무과금), 초과 시 429 |
| `GET /api/me` | Bearer | 오늘 사용량/쿼터 (쿼터 무소모) |

## 보안 규약

- **키 원문 무저장** — D1 에는 SHA-256 해시 + 표시용 접두 8자만(`_keys`).
  발급 응답이 원문의 유일한 노출 지점.
- 쿼터 하루 경계 = KST (파이프라인 규약과 동일).

## fixtures

`fixtures/seed.sql` 은 커밋되어 있어 토큰 없이 시드 가능. 재생성(팀 D1 읽기,
`CLOUDFLARE_API_TOKEN` 필요): `python fixtures/build_fixtures.py`. `_catalog` 는
라이브(8컬럼)가 아닌 **계약 v1.1 15컬럼 목표 상태**의 픽스처다(ASAC-DAG#521 참조).

## 승격 경로 (배포 게이트에 동승할 것)

- 키 발급 ① 즉시발급 → ④ GitHub OAuth (org OAuth 앱 등록 필요)
- rate limit: 분 단위 버스트 제한(현재는 일일 쿼터만)
- `_issuance_log` 주기 정리(현재 무만료)
