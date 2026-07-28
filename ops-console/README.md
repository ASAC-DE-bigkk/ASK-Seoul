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

## 실적재

```bash
python scripts/load_slo.py            # Trino 조회 → fixtures/slo_live.sql → 로컬 D1 적용
python scripts/load_slo.py --dry-run  # SQL 만 생성
TRINO_URL=http://127.0.0.1:30586 python scripts/load_slo.py   # 포트가 다르면
```

의존성 없이 Trino REST(`v1/statement`)를 직접 호출한다. 실측(2026-07-28):
`iceberg_dev.culture.gold_culture_slo_daily` **29행 · 2026-06-30 ~ 07-28**.

**이 스크립트는 임시다.** 정규 경로는 culture DAG 의 export task 여야 하고(팀 D1 쓰기 =
멘토 게이트), 그때까지 콘솔을 실측으로 채우는 수단이자 **export task 가 무엇을 하면 되는지의
실행 가능한 명세**다. `fixtures/slo_sample.sql` 은 Trino 가 없는 사람을 위한 폴백으로 남긴다
(`npm run seed`) — 모든 행에 `is_sample=1` 이 박혀 화면에 경고 배너가 뜬다.

### 초록 위장을 놓치지 않는다

`green_disguise_runs` = Airflow 는 success 인데 `expected=0` 인 run. **SLO 가 통과로
계산되는 날**이라 실패 목록에 안 잡힌다 — 그게 함정이다. 그래서 콘솔은 이걸
① KPI 로 세우고 ② 캘린더에서 초록이 아니라 **붉은 테두리**로 칠하고 ③ '살펴야 할 날'에
실패와 나란히 올린다. 실적재 결과 **6/30·7/7 두 건**이 잡혔다(7/7 은 설계 문서가 적어 둔 실사례).

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
