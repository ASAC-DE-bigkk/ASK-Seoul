"""Trino gold_*_slo_daily → _ops_slo 실적재 (ASK-Seoul#58).

**왜 이 경로인가**: Cloudflare Worker 는 Trino(`http://trino:8080`, Docker 내부 주소)에
닿지 못한다. 그래서 콘솔이 파이프라인 품질을 보려면 요약을 D1 로 밀어 넣어야 한다.
SLO 마트는 날짜 1행이라 도메인 6개 × 1년 = 2,200행 — 옮기는 비용이 사실상 없다.

**지금 단계**: 로컬 D1(Miniflare)에만 쓴다. 팀 D1 쓰기는 금지돼 있고, 정규 경로는
culture DAG 의 export task 여야 한다(멘토 게이트). 이 스크립트는 그 경로가 붙기 전까지
콘솔을 실측으로 채우는 수단이자, export task 가 무엇을 하면 되는지의 실행 가능한 명세다.

의존성 없음 — Trino REST(v1/statement)를 urllib 으로 직접 호출한다.

실행:
    python scripts/load_slo.py                 # 조회 → fixtures/slo_live.sql 생성 → 적용
    python scripts/load_slo.py --dry-run       # SQL 만 만들고 적용하지 않는다
    TRINO_URL=http://127.0.0.1:30586 python scripts/load_slo.py
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
CONSOLE = HERE.parent
OUT = CONSOLE / "fixtures" / "slo_live.sql"
PERSIST = "../serving-gateway/.wrangler/state"   # 게이트웨이와 공유하는 로컬 D1 상태

TRINO_URL = os.environ.get("TRINO_URL", "http://127.0.0.1:30586")
TRINO_USER = os.environ.get("TRINO_USER", "ops-console")
CATALOG = os.environ.get("TRINO_CATALOG", "iceberg_dev")

# 도메인별 SLO 마트. 실측(2026-07-28): *_slo_daily 는 culture 하나뿐이라 목록이 1줄이다.
# 다른 도메인이 마트를 만들면 여기 추가하면 되고, 없는 동안은 _ops_domain 이 그 사실을 남긴다.
SLO_TABLES = {"culture": f"{CATALOG}.culture.gold_culture_slo_daily"}

DOMAINS = [
    ("culture",  "문화·행사", True,  None),
    ("citydata", "인구·도시", False, "SLO 마트 미보유"),
    ("transit",  "대중교통",  False, "SLO 마트 미보유"),
    ("commerce", "상권",      False, "SLO 마트 미보유"),
    ("weather",  "날씨",      False, "SLO 마트 미보유"),
    ("traffic",  "교통",      False, "SLO 마트 미보유"),
]

COLUMNS = [
    "domain", "event_date", "scheduled_slo_passed", "eod_slo_passed", "best_coverage_pct",
    "failed_dataset_count", "violation_count", "total_rows", "ingest_duration_min",
    "transform_runs", "transform_all_success", "maintenance_ran", "green_disguise_runs",
]


def trino_query(sql: str) -> list[dict]:
    """Trino REST 로 질의. nextUri 를 끝까지 따라가며 행을 모은다."""
    req = urllib.request.Request(
        f"{TRINO_URL}/v1/statement", data=sql.encode("utf-8"),
        headers={"X-Trino-User": TRINO_USER, "Content-Type": "text/plain"}, method="POST")
    rows: list[dict] = []
    cols: list[str] = []
    with urllib.request.urlopen(req, timeout=60) as res:
        payload = json.loads(res.read())
    while True:
        if payload.get("error"):
            raise RuntimeError(payload["error"].get("message", "trino error"))
        if payload.get("columns") and not cols:
            cols = [c["name"] for c in payload["columns"]]
        for row in payload.get("data") or []:
            rows.append(dict(zip(cols, row)))
        nxt = payload.get("nextUri")
        if not nxt:
            return rows
        with urllib.request.urlopen(
                urllib.request.Request(nxt, headers={"X-Trino-User": TRINO_USER}), timeout=60) as res:
            payload = json.loads(res.read())


def sql_literal(v) -> str:
    if v is None:
        return "NULL"
    if isinstance(v, bool):
        return "1" if v else "0"
    if isinstance(v, (int, float)):
        return repr(v)
    return "'" + str(v).replace("'", "''") + "'"


def build_sql(rows_by_domain: dict[str, list[dict]]) -> str:
    out = [
        "-- 실적재 SLO — scripts/load_slo.py 가 Trino 에서 생성한다. 손으로 고치지 말 것.",
        f"-- 출처: {', '.join(SLO_TABLES.values())}",
        "-- is_sample=0 — 화면의 '합성 샘플' 배너는 이 데이터가 들어오면 사라진다.",
        "",
        "DELETE FROM _ops_slo;",
        "DELETE FROM _ops_domain;",
        "",
    ]
    for d, label, has_slo, note in DOMAINS:
        out.append("INSERT INTO _ops_domain (domain,label,has_slo,note) VALUES ({},{},{},{});".format(
            sql_literal(d), sql_literal(label), 1 if has_slo else 0, sql_literal(note)))
    out.append("")
    total = 0
    for domain, rows in rows_by_domain.items():
        for r in rows:
            vals = ",".join(sql_literal(r.get(c)) for c in COLUMNS)
            out.append(f"INSERT INTO _ops_slo ({','.join(COLUMNS)},is_sample) VALUES ({vals},0);")
            total += 1
    out.append("")
    out.append(f"-- 총 {total} 행")
    return "\n".join(out) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true", help="SQL 만 생성하고 D1 에 적용하지 않는다")
    args = ap.parse_args()

    rows_by_domain = {}
    for domain, table in SLO_TABLES.items():
        cols = ", ".join(
            f"CAST({c} AS varchar) AS {c}" if c in ("event_date",) else c for c in COLUMNS[1:])
        sql = f"SELECT domain, {cols} FROM {table} ORDER BY event_date"
        try:
            rows = trino_query(sql)
        except Exception as exc:  # noqa: BLE001 — 원인을 그대로 보여주는 게 낫다
            print(f"Trino 조회 실패({table}): {exc}", file=sys.stderr)
            print(f"  TRINO_URL={TRINO_URL} 확인 — 컨테이너 포트 매핑이 바뀌었을 수 있다", file=sys.stderr)
            return 2
        # Trino 는 decimal/boolean 을 문자열로 돌려주기도 한다 — D1 이 읽을 형태로 정규화
        for r in rows:
            for k, v in list(r.items()):
                if isinstance(v, str) and k.endswith(("_pct", "_min")):
                    r[k] = round(float(v), 2)
        rows_by_domain[domain] = rows
        print(f"{domain}: {len(rows)}행"
              + (f" ({rows[0]['event_date']} ~ {rows[-1]['event_date']})" if rows else ""))

    OUT.write_text(build_sql(rows_by_domain), encoding="utf-8")
    print(f"→ {OUT.relative_to(CONSOLE)}")
    if args.dry_run:
        print("--dry-run — 적용하지 않았다")
        return 0

    cmd = ["npx", "wrangler", "d1", "execute", "ask-seoul-dev-d1", "--local",
           "--persist-to", PERSIST, f"--file={OUT.relative_to(CONSOLE)}"]
    proc = subprocess.run(cmd, cwd=CONSOLE, shell=(os.name == "nt"))
    if proc.returncode != 0:
        print("D1 적용 실패", file=sys.stderr)
        return proc.returncode
    print("D1 적재 완료 — 콘솔 새로고침 시 합성 배너가 사라진다")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
