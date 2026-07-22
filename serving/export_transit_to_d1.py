"""transit 골드 → D1 export 1차 6종 (프로토타입 — DAG 승격 예정).

citydata `export_gold_to_d1.py` 승계 + DAG(#445 계열)의 3-tier 주기를 --mode 로 반영.
설계 확정치는 닫힌 이슈 ASAC-DAG#475 본문 참조 (ASK-Seoul 단일 브랜치 통합 결정).

  FAST   (매 15분, :10/:25/:55): dong_now · parking_full_risk — 전량 교체
  APPEND (매시, :40 hourly 모드): dong_hourly — 최근 2시간 삭제→재삽입, D1 비면 전체 백필
  DAILY  (일 1회, 08:40 full 모드): forecast_card · event_access · parking_profile — 전량 교체

실행:  python export_transit_to_d1.py [--mode fast|hourly|full] [--remote]
  기본 = fast + 로컬 D1(Miniflare). --remote 는 CLOUDFLARE_API_TOKEN 필요.
  최초 적재는 --mode full 로 전체 백필.
전제:  sample 스택(Trino) 기동, dbt/domains/transit/target/manifest.json 존재.

주의: D1(ask-seoul-dev-d1)·`_catalog` 는 citydata 와 **공유** — _catalog 는 DROP 금지,
INSERT OR REPLACE upsert 만 한다 (citydata 프로토타입의 DROP 방식을 따라가면 안 됨).

신뢰성 게이트(DAG #450·#464 승계): 실시간 스냅샷(dong_now·parking_full_risk)은
  - 0행이면 D1 미갱신(직전 스냅샷 유지)
  - 최신 시각이 30분 이상 지연이면 경보 출력 (transit 은 수집 3~10분·발표지연 없음
    — citydata 90분과 다름. 배포 후 실측 분포로 보정)
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

HERE = Path(__file__).parent
SAMPLE = HERE.parent
MANIFEST = SAMPLE / "dbt" / "domains" / "transit" / "target" / "manifest.json"
BUILD = HERE / "build"
DB_NAME = "ask-seoul-dev-d1"
SCHEMA = "iceberg_dev.transit"

FAST_TABLES = ["gold_transit_dong_now", "gold_transit_parking_full_risk"]
APPEND_TABLES = ["gold_transit_dong_hourly"]
DAILY_TABLES = ["gold_transit_forecast_card", "gold_transit_event_access",
                "gold_transit_parking_profile"]
MODE_TABLES = {
    "fast": FAST_TABLES,
    "hourly": FAST_TABLES + APPEND_TABLES,
    "full": FAST_TABLES + APPEND_TABLES + DAILY_TABLES,
}

APPEND_LOOKBACK_H = 2   # timestamp 축: 재적재할 최근 시간 수 (late-arrival 여유)
APPEND_LOOKBACK_D = 2   # date 축: 재적재할 최근 일 수
# 신선도 임계: dong_now 는 15분 버킷 아카이브의 '마지막 관측 버킷' 기반이라
# (gold_transit_dong_now.sql — 아카이브 프런티어 설계) 버킷 완결 대기 + 변환 15분이
# 겹치면 건강한 상태에서도 ~50분 지연이 실측됨(2026-07-21, silver 는 신선).
# 30분은 이 내재 지연을 오탐 — 실측 + 여유로 75분.
STALE_THRESHOLD_MIN = 75
FRESHNESS_CHECK = set(FAST_TABLES)

SQLITE_TYPE = {  # trino → sqlite
    "integer": "INTEGER", "bigint": "INTEGER", "smallint": "INTEGER", "tinyint": "INTEGER",
    "boolean": "INTEGER", "double": "REAL", "real": "REAL",
}
INSERT_BATCH = 200


def trino(sql: str) -> list[dict]:
    proc = subprocess.run(
        ["docker", "compose", "exec", "-T", "trino", "trino", "--output-format", "JSON", "--execute", sql],
        cwd=SAMPLE, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=600,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"trino failed: {proc.stderr.strip()[:300]}")
    return [json.loads(l) for l in proc.stdout.splitlines() if l.strip()]


def sqlite_type(trino_type: str) -> str:
    base = trino_type.split("(")[0]
    if base == "decimal":
        return "REAL"
    return SQLITE_TYPE.get(base, "TEXT")


def sql_literal(v) -> str:
    if v is None:
        return "NULL"
    if isinstance(v, bool):
        return "1" if v else "0"
    if isinstance(v, (int, float)):
        return str(v)
    return "'" + str(v).replace("'", "''") + "'"


def load_meta() -> dict[str, dict]:
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    gates: dict[str, list[str]] = {}
    for node in manifest["nodes"].values():
        if node.get("resource_type") != "test" or not node.get("attached_node"):
            continue
        tm = node.get("test_metadata") or {}
        label = tm.get("name") or node.get("name", "test")
        col = (tm.get("kwargs") or {}).get("column_name")
        gates.setdefault(node["attached_node"], []).append(f"{label}({col})" if col else label)
    meta = {}
    for uid, node in manifest["nodes"].items():
        if node.get("resource_type") == "model":
            meta[node["name"]] = {
                "description": node.get("description", ""),
                "serving_tier": (node.get("config", {}).get("meta") or {}).get("serving_tier"),
                "tests": sorted(set(gates.get(uid, []))),
            }
    return meta


def wrangler(args: list[str], remote: bool) -> str:
    cmd = ["npx", "-y", "wrangler", "d1", "execute", DB_NAME,
           "--remote" if remote else "--local", "-y"] + args
    proc = subprocess.run(cmd, cwd=HERE, capture_output=True, text=True,
                          encoding="utf-8", errors="replace", timeout=600, shell=(sys.platform == "win32"))
    if proc.returncode != 0:
        raise RuntimeError(f"wrangler failed({args[-1][:60]}): {(proc.stderr or proc.stdout).strip()[-400:]}")
    return proc.stdout


def d1_execute(file: Path, remote: bool) -> None:
    wrangler([f"--file={file}"], remote)


def d1_query(sql: str, remote: bool) -> list[dict]:
    out = wrangler(["--json", f"--command={sql}"], remote)
    # 출력에서 JSON 배열만 취한다 (앞쪽 wrangler 배너 무시)
    payload = json.loads(out[out.index("["):])
    return (payload[0].get("results") or []) if payload else []


def kst_now_naive() -> datetime:
    return datetime.now(timezone.utc).replace(tzinfo=None) + timedelta(hours=9)


def export_full(name: str, col_defs: list, rows: list[dict], remote: bool) -> None:
    """전량 교체 스냅샷 — DROP+CREATE+INSERT (멱등)."""
    colnames = [c for c, _ in col_defs]
    lines = [f'DROP TABLE IF EXISTS "{name}";',
             f'CREATE TABLE "{name}" (' +
             ", ".join(f'"{c}" {sqlite_type(t)}' for c, t in col_defs) + ");"]
    for i in range(0, len(rows), INSERT_BATCH):
        batch = rows[i:i + INSERT_BATCH]
        values = ",\n".join("(" + ", ".join(sql_literal(r.get(c)) for c in colnames) + ")" for r in batch)
        lines.append(f'INSERT INTO "{name}" ("' + '", "'.join(colnames) + f'") VALUES\n{values};')
    f = BUILD / f"{name}.sql"
    f.write_text("\n".join(lines), encoding="utf-8")
    d1_execute(f, remote)


def export_append(name: str, col_defs: list, time_axis: str, remote: bool) -> tuple[int, int]:
    """이력·누적 — 최근 lookback 만 삭제→재삽입 + 신규. D1 비면 전체 백필.
    반환: (upsert 행수, D1 총 행수). DAG _export_append 와 동일 로직."""
    colnames = [c for c, _ in col_defs]
    is_date = dict(col_defs).get(time_axis, "").startswith("date")

    ddl = BUILD / f"{name}_ddl.sql"
    ddl.write_text(f'CREATE TABLE IF NOT EXISTS "{name}" ('
                   + ", ".join(f'"{c}" {sqlite_type(t)}' for c, t in col_defs) + ");",
                   encoding="utf-8")
    d1_execute(ddl, remote)

    info = d1_query(f'SELECT count(*) c, max("{time_axis}") m FROM "{name}";', remote)
    d1_count = (info[0].get("c") if info else 0) or 0
    d1_max = info[0].get("m") if info else None

    where = ""
    cutoff = None
    if d1_count and d1_max:
        base = datetime.fromisoformat(str(d1_max).replace(" ", "T"))
        if is_date:
            cutoff = (base - timedelta(days=APPEND_LOOKBACK_D)).strftime("%Y-%m-%d")
            trino_lit = f"date '{cutoff}'"
        else:
            cutoff = (base - timedelta(hours=APPEND_LOOKBACK_H)).strftime("%Y-%m-%d %H:00:00")
            trino_lit = f"timestamp '{cutoff}'"
        where = f' WHERE "{time_axis}" >= {trino_lit}'
        dele = BUILD / f"{name}_delete.sql"
        dele.write_text(f'DELETE FROM "{name}" WHERE "{time_axis}" >= \'{cutoff}\';', encoding="utf-8")
        d1_execute(dele, remote)

    rows = trino(f"SELECT * FROM {SCHEMA}.{name}{where}")
    lines = []
    for i in range(0, len(rows), INSERT_BATCH):
        batch = rows[i:i + INSERT_BATCH]
        values = ",\n".join("(" + ", ".join(sql_literal(r.get(c)) for c in colnames) + ")" for r in batch)
        lines.append(f'INSERT INTO "{name}" ("' + '", "'.join(colnames) + f'") VALUES\n{values};')
    if lines:
        f = BUILD / f"{name}.sql"
        f.write_text("\n".join(lines), encoding="utf-8")
        d1_execute(f, remote)

    total = (d1_query(f'SELECT count(*) c FROM "{name}";', remote)[0].get("c")) or 0
    print(f"→ {name}: append({'백필' if cutoff is None else 'from ' + cutoff}) "
          f"· {len(rows)}행 upsert · D1 총 {total}")
    return len(rows), total


def main() -> None:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--mode", choices=list(MODE_TABLES), default="fast")
    ap.add_argument("--remote", action="store_true")
    args = ap.parse_args()

    BUILD.mkdir(exist_ok=True)
    meta = load_meta()
    now = datetime.now(timezone.utc).isoformat()
    tables = MODE_TABLES[args.mode]
    print(f"[transit export] mode={args.mode} · {len(tables)} tables")

    issues = []
    catalog_rows = []
    for name in tables:
        cols = trino(f"SHOW COLUMNS FROM {SCHEMA}.{name}")
        col_defs = [(c["Column"], c["Type"]) for c in cols]
        time_axis = next((c for c, t in col_defs if t.startswith(("timestamp", "date"))), None)

        if name in APPEND_TABLES:
            _, cat_count = export_append(name, col_defs, time_axis, args.remote)
        else:
            rows = trino(f"SELECT * FROM {SCHEMA}.{name}")
            print(f"→ {name}: {len(rows)} rows")

            # 빈-데이터 보호: 실시간 스냅샷이 비면 상류 이상 — 직전 스냅샷 유지
            if not rows and name in FRESHNESS_CHECK:
                issues.append(f"{name}: 0행 (상류 골드 비어있음) — D1 미갱신, 직전 스냅샷 유지")
                continue

            # 신선도: 시간 컬럼 전체의 최신값(max)으로 판정 (KST naive 비교).
            # dong_now 는 소스별 *_last_event_at 3개 — 버스는 수집 창 기반(#369)이라
            # 창 사이 60분+ 지연이 정상. 게이트 목적은 '파이프라인 좀비 감지'이므로
            # 한 소스라도 신선하면 살아있다고 본다 (소스별 정체 경보는 별도 과제).
            ts_cols = [c for c, t in col_defs if t.startswith(("timestamp", "date"))]
            if name in FRESHNESS_CHECK and ts_cols and rows:
                latest = max((r.get(c) for r in rows for c in ts_cols if r.get(c)), default=None)
                if latest:
                    latest_dt = datetime.fromisoformat(str(latest).replace(" ", "T"))
                    lag = (kst_now_naive() - latest_dt).total_seconds() / 60
                    if lag > STALE_THRESHOLD_MIN:
                        issues.append(f"{name}: 최신 {latest} = {lag:.0f}분 지연 (임계 {STALE_THRESHOLD_MIN})")

            export_full(name, col_defs, rows, args.remote)
            cat_count = len(rows)

        m = meta.get(name, {})
        catalog_rows.append({
            "name": name, "description": m.get("description", ""),
            "serving_tier": m.get("serving_tier"), "tests": json.dumps(m.get("tests", []), ensure_ascii=False),
            "time_axis": time_axis,
            "columns": json.dumps([{"name": c, "type": t} for c, t in col_defs], ensure_ascii=False),
            "row_count": cat_count, "exported_at": now,
        })

    # _catalog 는 citydata 와 공유 — DROP 금지, upsert 만 (미포함 모드의 행도 보존)
    cat = ['CREATE TABLE IF NOT EXISTS _catalog (name TEXT PRIMARY KEY, description TEXT, '
           'serving_tier TEXT, tests TEXT, time_axis TEXT, columns TEXT, '
           'row_count INTEGER, exported_at TEXT);',
           'CREATE TABLE IF NOT EXISTS _request_log (ts TEXT, path TEXT, query TEXT);']
    for r in catalog_rows:
        cat.append("INSERT OR REPLACE INTO _catalog VALUES (" + ", ".join(sql_literal(r[k]) for k in
                   ("name", "description", "serving_tier", "tests", "time_axis", "columns", "row_count", "exported_at")) + ");")
    f = BUILD / "_catalog_transit.sql"
    f.write_text("\n".join(cat), encoding="utf-8")
    d1_execute(f, args.remote)
    print(f"✓ exported {len(catalog_rows)} tables → D1[{'remote' if args.remote else 'local'}] '{DB_NAME}'")

    if issues:
        print("⚠️ transit 서빙 신선도/검증 경보\n" + "\n".join(f" • {i}" for i in issues)
              + "\n(export 자체는 성공 — 상류 골드 갱신 정체 또는 빈 데이터 의심)")
    else:
        print("[transit export] 신뢰성 게이트 통과 — 신선·비어있지 않음")


if __name__ == "__main__":
    main()
