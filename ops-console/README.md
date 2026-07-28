# ops-console — 운영자용 통합 품질 콘솔 (ASK-Seoul#58)

파이프라인 품질과 서빙 품질을 **한 화면**에서 본다. 마켓플레이스([serving-gateway](../serving-gateway/))와
**다른 Worker · 다른 호스트**다 — 청중이 다르고(외부 고객 vs 운영자), 배포 단위가 갈려야
사고 반경도 갈린다.

| 탭 | 묻는 질문 | 출처 |
|---|---|---|
| 파이프라인 품질 (`#pipeline`) | 수집·변환이 제 몫을 했나 | `_ops_slo` (gold_*_slo_daily 스냅샷) |
| 서빙 품질 (`#serving`) | 외부에 잘 나가고 있나 | `_request_log` (게이트웨이가 쌓는다) |

탭은 URL 해시에 실린다 — 새로고침·링크 공유에도 보던 자리가 유지된다.
**탭 라벨의 점**은 그 탭이 아픈지를 전환 없이 알려준다(빨강 = 정기런 실패·계약 위반 /
에러율 5% 이상·0행 발생). 탭으로 나누면 안 보는 쪽 문제를 놓치기 쉬운데, 그 대가를
점이 상쇄한다.

## ⚠️ 로컬 전용

`wrangler dev` 로만 구동. **`wrangler deploy` 금지** — 공개 URL 신설은 멘토 게이트(#476 ①).

## 실행

D1 은 게이트웨이와 **같은 로컬 상태를 공유**한다(`--persist-to`). 서빙 품질 원본인
`_request_log` 가 저쪽에 쌓이기 때문이다.

```bash
cd ops-console
npm install
npm run seed         # _ops_slo/_ops_domain + 합성 SLO 14일 → 공유 D1
echo "OPS_TOKEN=$(openssl rand -hex 16)" > .dev.vars    # .gitignore 대상
npm run dev          # http://localhost:8788
```

## 왜 SLO 를 복사하나

Trino 는 `http://trino:8080` — **Docker 내부 주소라 Cloudflare Worker 가 닿지 못한다.**
그래서 콘솔이 파이프라인 품질을 보려면 요약을 밀어 넣는 수밖에 없다. 다행히 SLO 마트는
**날짜 1행**이라 도메인 6개 × 1년 = 2,200행 — 웨어하우스를 옮기는 게 아니라 요약 한 줌이다.

**아직 실적재는 없다.** 팀 D1 쓰기가 금지돼 있어 `fixtures/slo_sample.sql` 의 **합성 14일치**를
시드한다. 모든 행에 `is_sample=1` 이 박혀 있고 화면 상단에 경고 배너가 뜬다 —
이 값으로 운영 판단을 하면 안 된다. 실적재 경로(멘토 게이트)가 붙으면 픽스처는 지운다.

## 콘솔이 드러내는 실측 하나

**SLO 마트를 가진 도메인은 culture 하나뿐이다** (ASAC-DBT 전체에서 `*_slo_daily` 검색, 2026-07-28).
`_ops_domain` 은 없는 도메인도 행으로 남겨 `1 / 6` 으로 보여준다 — 나머지 5개는 품질을 잴
수단 자체가 없다는 뜻이고, 그게 이 콘솔이 팀에 던지는 첫 질문이다.

## 인증 한계

공유 토큰(`OPS_TOKEN`)이라 **"누가 봤나"가 남지 않는다.** 공개 배포 시 Cloudflare Access 나
org OAuth 로 **교체 필수**(멘토 게이트). 토큰 미설정이면 503 으로 기능이 꺼진다 —
인증 없는 운영 화면이 실수로 열리는 것보다 낫다. 토큰은 sessionStorage 에만 두고
URL 에 싣지 않으며, 페이지는 `noindex` 다.

## 승격 경로

- `_ops_slo` 실적재 — culture SLO export task(내 도메인) → 나머지 도메인은 각자 (팀 합의)
- 인증 — 공유 토큰 → Cloudflare Access / org OAuth
- 알림 — 지금은 조회 전용. 정기런 실패 시 푸시는 Airflow 콜백(DeadlineAlert) 쪽이 맞다
