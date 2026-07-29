"""로컬 D1 시드 생성기 — 팀 D1(읽기 전용)에서 서빙 제품 전종 샘플을 추출해 seed.sql 을 쓴다.

사용법 (레포 루트 sample/ 에서, .env 의 CLOUDFLARE_API_TOKEN 필요):
    python serving-gateway/fixtures/build_fixtures.py

산출물 seed.sql·public/product-display.json 은 커밋한다 — 팀원은 토큰 없이
`npm run seed` 만으로 로컬 D1 이 선다.

**두 갈래로 수집한다.**
- 라이브 `_catalog` 에 등록된 제품(타 도메인): 계약값(description·product_question·
  tests·time_axis·serving_status·freshness)을 **그대로 옮긴다**. 여기선 라이브가 정본이다.
- culture: 라이브 `_catalog` 에 아직 행이 없다(계약 선언 ASAC-DBT#346 리뷰 중).
  아래 CULTURE_PRODUCTS 의 계약값으로 **목표 상태를 로컬에서 먼저 산다**.

`_catalog` 는 계약 v1.1(15컬럼) 기준 픽스처 — 라이브 16컬럼 스키마와 다르며 그게 의도다
(라이브의 serving_tier 는 계약 v1.1 에 없어 싣지 않는다).
"""
from __future__ import annotations

import json
import os
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

ACCOUNT = "0d39ddce1c07c97df66843ede19f56c4"
DATABASE = "9db0e851-558e-489f-9e76-f131d25aa267"
API = f"https://api.cloudflare.com/client/v4/accounts/{ACCOUNT}/d1/database/{DATABASE}/query"
SAMPLE_ROWS = 50

# (table, product_id, product_question, time_axis) — ASAC-DBT#346 meta.serving 계약값
CULTURE_PRODUCTS = [
    ("gold_culture_activity_by_dong", "culture_activity_by_dong", "어느 행정동에서 언제 문화 활동이 얼마나 열리나?", "event_date"),
    ("gold_culture_calendar_density", "culture_calendar_density", "구별로 어느 날짜에 행사가 몰리나(밀집도)?", "event_date"),
    ("gold_culture_event_schedule", "culture_event_schedule", "이번 주말·특정 기간 서울에서 무슨 문화행사가 열리나?", "event_start_date"),
    ("gold_culture_event_crowd", "culture_event_crowd", "무슨 요일 몇 시에 행사 주변이 붐비나?", None),
    ("gold_culture_boxoffice_daily", "culture_boxoffice_daily", "지금 서울에서 예매 상위 공연은 무엇인가?", "snapshot_date"),
    ("gold_culture_dine_around", "culture_dine_around", "행사 많은 동네 주변 외식 상권은 어디인가?", None),
    ("gold_culture_booking_curve", "culture_booking_curve", "공연 예매 인기가 개막까지 어떤 궤적으로 차오르나?", None),
]

# 표시명·그레인 — 계약에 display 필드가 없어서 서빙까지 실려오지 않는다(#476 제안).
# 타 도메인 값은 각 도메인이 라이브 _catalog.description 에 쓴 헤드라인을 그대로 옮긴 것이고,
# 지어낸 이름이 아니다. 계약 v1.2 에 display 가 들어가면 이 표와 product-display.json 은 지운다.
DISPLAY = {
    # culture
    "culture_activity_by_dong": ("행정동별 문화 활동", "행정동 × 날짜"),
    "culture_calendar_density": ("구별 행사 캘린더 밀집도", "자치구 × 날짜"),
    "culture_event_schedule": ("문화행사 일정", "행사 = 1행"),
    "culture_event_crowd": ("요일·시간대 혼잡 패턴", "구 × 요일 × 시간"),
    "culture_boxoffice_daily": ("공연 예매 박스오피스", "일 × 순위"),
    "culture_dine_around": ("행사 동네 외식 상권", "행정동 = 1행"),
    "culture_booking_curve": ("공연 예매 오픈 궤적", "공연 = 1행"),
    # commerce
    "commerce_address_succession": ("이 자리엔 다음에 뭐가?", "폐업업종 × 개업업종"),
    "commerce_age_band": ("신상 상권 vs 노포 상권", "업력밴드 × 업종 × 구"),
    "commerce_area_profile": ("이 업종 가게 크기", "업종 × 자치구"),
    "commerce_change_activity": ("간판·자리 자주 바꾸는 업종", "업종 = 1행"),
    "commerce_churn_yearly": ("상권 역동성(연도별)", "연 × 업종 × 구"),
    "commerce_cohort_survival": ("창업 생존율 곡선", "개업코호트 × 경과연차"),
    "commerce_data_quality": ("데이터 신뢰도 진단", "데이터셋 = 1행"),
    "commerce_dong_category_matrix": ("우리 동네엔 뭐가 많나", "행정동 × 중분류"),
    "commerce_dong_summary": ("우리 동네 상권 요약", "행정동 = 1행"),
    "commerce_env_facility_operation": ("우리 구 배출시설 가동", "자치구 × 연도"),
    "commerce_flow_monthly": ("개·폐업 흐름(월)", "월 × 업종 × 지역"),
    "commerce_flow_yearly": ("개·폐업 흐름(연)", "연 × 업종 × 지역"),
    "commerce_geo_grid_detail": ("상권 밀집 히트맵(상세)", "500m 격자 × 업종"),
    "commerce_geo_grid_overview": ("상권 밀집 히트맵(개요)", "500m 격자"),
    "commerce_gu_specialization": ("우리 구 특화 업종", "자치구 × 업종"),
    "commerce_lifespan": ("이 업종 얼마나 버티나", "업종 × 자치구"),
    "commerce_multi_site": ("체인·다점포 비율", "업종 = 1행"),
    "commerce_phone_succession": ("폐업 사장님의 재도전", "업종 전환 조합"),
    "commerce_seasonality": ("개·폐업 계절성", "월 × 업종"),
    "commerce_status_duration": ("휴업하면 얼마나 쉬나", "업종 × 상태군"),
    "commerce_status_transition": ("휴업 다음은 재개? 폐업?", "상태전이 × 업종"),
    "commerce_uptae_rollup": ("업종 속 세부 업태", "업태 × 업종"),
    # citydata
    "citydata_air_anomaly": ("대기질 이상 탐지", "장소 = 1행"),
    "citydata_air_trend": ("대기질 추세(실시간)", "장소 = 1행"),
    "citydata_charger_availability": ("EV 충전소 가용 현황", "장소 × 충전소"),
    "citydata_cmrcl_daily": ("장소별 일 소비 활력", "장소 × 날짜"),
    "citydata_hot_commerce": ("뜨는 상권 지수", "장소 = 1행"),
    "citydata_place_latest": ("장소 최신 크로스 신호", "장소 = 1행"),
    "citydata_place_scorecard": ("장소 종합 스코어카드", "장소 = 1행"),
    "citydata_ppltn_anomaly": ("혼잡 이상 탐지", "장소 = 1행"),
    "citydata_ppltn_daily": ("장소별 하루 혼잡", "장소 × 날짜"),
    "citydata_ppltn_dow_hour": ("요일×시간 혼잡 롤업", "장소 × 요일 × 시간"),
    "citydata_ppltn_forecast": ("주말 혼잡 예보", "장소 × 주말 × 시간"),
    "citydata_ppltn_hourly": ("장소별 시간 혼잡", "장소 × 시간"),
    "citydata_ppltn_trend": ("붐빔 추세(실시간)", "장소 = 1행"),
    "citydata_ppltn_x_commerce_dong": ("유동 대비 상가 공급", "행정동 = 1행"),
    "citydata_ppltn_x_culture_daily": ("유동인구 × 문화행사", "행정동 × 날짜"),
    "citydata_purchasing_power_daily": ("구매력·붐빔대비구매", "장소 × 날짜"),
    "citydata_sbike_availability": ("따릉이 가용 현황", "장소 × 대여소"),
    # traffic
    "traffic_flow_anomaly_current": ("링크 속도 이상 탐지", "도로링크 = 1행"),
    "traffic_flow_change_latest": ("직전 관측 대비 속도 변화", "도로링크 = 1행"),
    "traffic_flow_congestion_hotspots_hourly": ("시간대 정체 핫스팟", "시간 × 링크순위"),
    "traffic_flow_link_latest": ("링크별 최신 속도", "도로링크 = 1행"),
    "traffic_flow_link_time_profile": ("링크 요일·시간 속도 기준선", "링크 × 요일 × 시간"),
    "traffic_incident_x_weather_current_hourly": ("돌발 × 기상 맥락", "행정동 × 시간"),
    # transit
    "transit_dong_hourly": ("동×시간대 교통 상태판", "행정동 × 시간"),
    "transit_dong_now": ("지금 우리 동네 교통", "행정동 = 1행"),
    "transit_event_access": ("행사장 가는 길 안내판", "행사 = 1행"),
    "transit_forecast_card": ("내일 이 시간 교통", "지역 × 미래시각"),
    "transit_parking_full_risk": ("주차장 만차 리스크", "주차장 = 1행"),
    "transit_parking_profile": ("주차장 요일×시간 점유", "주차장 × 요일 × 시간"),
    # weather
    "weather_place_current_outlook": ("지금 이 장소 예보", "장소 = 1행"),
    "weather_place_forecast_change_daily": ("예보 수정 내역(일별)", "장소 × 예보일"),
    "weather_place_precipitation_window": ("연속 강수 예보 구간", "장소 × 구간"),
    "weather_place_risk_window": ("기상 주의 구간(후보)", "장소 × 구간"),
}

CATALOG_DDL = (
    "CREATE TABLE _catalog (name TEXT PRIMARY KEY, product_id TEXT, "
    "external INTEGER, description TEXT, product_question TEXT, tests TEXT, time_axis TEXT, "
    "columns TEXT, row_count INTEGER, serving_status TEXT, publication_id TEXT, "
    "source_run_id TEXT, published_bytes INTEGER, freshness TEXT, exported_at TEXT);"
)
CATALOG_COLS = (
    "name, product_id, external, description, product_question, tests, time_axis, columns, "
    "row_count, serving_status, publication_id, source_run_id, published_bytes, freshness, exported_at"
)


def d1(sql: str, attempts: int = 4) -> list[dict]:
    token = os.environ.get("CLOUDFLARE_API_TOKEN", "")
    if not token:
        raise SystemExit("CLOUDFLARE_API_TOKEN 미설정 — sample/.env 값을 환경변수로 넘겨 실행")
    req = urllib.request.Request(
        API,
        data=json.dumps({"sql": sql}).encode(),
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
    )
    # 전종 생성은 요청이 200건 가까이 된다 — 일시적 네트워크 오류 하나로 처음부터
    # 다시 돌리지 않도록 재시도한다. 조회 전용이라 재시도가 안전하다.
    for i in range(attempts):
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                body = json.load(resp)
            break
        except (urllib.error.URLError, TimeoutError) as e:
            if i == attempts - 1:
                raise SystemExit(f"D1 연결 실패({attempts}회 시도): {e}")
            time.sleep(2 ** i)
    if not body.get("success"):
        raise SystemExit(f"D1 오류: {body.get('errors')}")
    return body["result"][0]["results"]


def lit(value) -> str:
    if value is None:
        return "NULL"
    if isinstance(value, (int, float)):
        return str(value)
    return "'" + str(value).replace("'", "''") + "'"


def sample_rows(table: str, axis: str | None) -> list[dict]:
    """표본을 '오늘 근처'로 잡는다 — 과거쪽 최신 + 미래쪽 최근접을 섞어 최대 SAMPLE_ROWS 행.

    미리보기 API 가 표본 안에서 시간축 내림차순 5행을 보여주기 때문에, 뜨는 방식이
    그대로 화면이 된다. 앞쪽 rowid 를 뜨면 실시간 제품이 몇 달 전 값을 보여주고,
    그렇다고 내림차순만 쓰면 이벤트형 제품이 1년 뒤 장기 전시를 대표로 내건다.
    (SQLite 는 INTEGER 를 TEXT 보다 항상 작게 보므로 연도·요일 같은 숫자 축은
    전부 과거 버킷으로 떨어진다 — 내림차순 정렬이라 최신부터 담긴다.)
    """
    if not axis:
        return d1(f'SELECT * FROM "{table}" LIMIT {SAMPLE_ROWS}')
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    past = d1(f'SELECT * FROM "{table}" WHERE "{axis}" <= \'{now}\' '
              f'ORDER BY "{axis}" DESC LIMIT {SAMPLE_ROWS}')
    future = d1(f'SELECT * FROM "{table}" WHERE "{axis}" > \'{now}\' '
                f'ORDER BY "{axis}" ASC LIMIT {SAMPLE_ROWS}')
    half = SAMPLE_ROWS // 2
    take_past = min(len(past), max(half, SAMPLE_ROWS - len(future)))
    return past[:take_past] + future[:SAMPLE_ROWS - take_past]


def collect() -> list[dict]:
    """라이브 _catalog 등록분 + culture 계약분 → 제품 목록(테이블명 순)."""
    products = []
    for row in d1("SELECT * FROM _catalog"):
        table = row["name"]
        # 라이브에 계약 필드가 빈 행이 있다(transit 3종 — 구 d1_direct 경로).
        # product_id 는 표시·도메인 분류에 쓰이므로 테이블명에서 유도하되,
        # external·serving_status 는 라이브 값을 그대로 둔다(선언되지 않은 걸 선언된 척하지 않는다).
        products.append({
            "table": table,
            "product_id": row.get("product_id") or table.removeprefix("gold_"),
            "external": row.get("external"),
            "description": row.get("description"),
            "product_question": row.get("product_question"),
            "tests": row.get("tests") or "[]",
            "time_axis": row.get("time_axis"),
            "serving_status": row.get("serving_status"),
            "freshness": row.get("freshness"),
        })

    known = {p["table"] for p in products}
    for table, product_id, question, time_axis in CULTURE_PRODUCTS:
        if table in known:  # 계약이 머지되어 라이브에 실리면 그쪽이 정본
            continue
        products.append({
            "table": table,
            "product_id": product_id,
            "external": 1,
            "description": f"culture 외부 gold — {product_id}",
            "product_question": question,
            "tests": "[]",
            "time_axis": time_axis,
            "serving_status": "published",
            "freshness": None,
        })
    return sorted(products, key=lambda p: p["table"])


def main() -> None:
    products = collect()
    out: list[str] = [
        "-- generated by build_fixtures.py — 팀 D1 샘플 (제품 %d종 · 테이블당 최대 %d행)"
        % (len(products), SAMPLE_ROWS),
        "DROP TABLE IF EXISTS _catalog;",
        CATALOG_DDL,
    ]
    now = datetime.now(timezone.utc).isoformat()
    display_out: dict[str, dict[str, str]] = {}
    missing_display: list[str] = []

    for p in products:
        table, product_id = p["table"], p["product_id"]
        info = d1(f"PRAGMA table_info({table})")
        cols = [(c["name"], c["type"] or "TEXT") for c in info]
        col_defs = ", ".join(f'"{n}" {t}' for n, t in cols)
        out.append(f'DROP TABLE IF EXISTS "{table}";')
        out.append(f'CREATE TABLE "{table}" ({col_defs});')

        total = d1(f'SELECT COUNT(*) AS n FROM "{table}"')[0]["n"]
        axis = p["time_axis"]
        rows = sample_rows(table, axis if axis and axis in dict(cols) else None)
        names = ", ".join(f'"{n}"' for n, _ in cols)
        for r in rows:
            values = ", ".join(lit(r.get(n)) for n, _ in cols)
            out.append(f'INSERT INTO "{table}" ({names}) VALUES ({values});')

        columns_json = json.dumps([{"name": n, "type": t} for n, t in cols], ensure_ascii=False)
        out.append(
            f"INSERT OR REPLACE INTO _catalog ({CATALOG_COLS}) VALUES ("
            + ", ".join([
                lit(table), lit(product_id), lit(p["external"]), lit(p["description"]),
                lit(p["product_question"]), lit(p["tests"]), lit(axis), lit(columns_json),
                str(total), lit(p["serving_status"]), "'local-fixture'", "'local-fixture'",
                "0", lit(p["freshness"]), lit(now),
            ])
            + ");"
        )

        if product_id in DISPLAY:
            title, unit = DISPLAY[product_id]
            display_out[product_id] = {"title": title, "unit": unit}
        else:
            missing_display.append(product_id)
        print(f"{table}: sample={len(rows)} full={total}")

    seed = Path(__file__).with_name("seed.sql")
    seed.write_text("\n".join(out) + "\n", encoding="utf-8")
    disp = Path(__file__).parent.parent / "public" / "product-display.json"
    disp.write_text(json.dumps(display_out, ensure_ascii=False, indent=1, sort_keys=True) + "\n",
                    encoding="utf-8")

    print(f"\nwrote {seed} ({seed.stat().st_size:,} bytes) — 제품 {len(products)}종")
    print(f"wrote {disp} — 표시명 {len(display_out)}종")
    if missing_display:
        print(f"⚠️ 표시명 없음 {len(missing_display)}종 (product_id 로 표시됨): {', '.join(missing_display)}")


if __name__ == "__main__":
    main()
