"""citydata 골드 → D1 export (전량 교체 스냅샷, 프로토타입).

설계(specs/2026-07-17 §2·§5): 증분 upsert 금지 — 테이블마다 DROP+CREATE+INSERT 를
하나의 SQL 파일로 만들어 `wrangler d1 execute` 로 통째 적재한다(멱등).
카탈로그(_catalog)는 dbt manifest 의 description·meta.serving_tier·테스트 게이트에서 파생
— 별도 손 관리 없음 (specs §4).

실행:  python export_gold_to_d1.py [--remote]
  기본 = 로컬 D1(Miniflare). --remote 는 CLOUDFLARE_API_TOKEN 필요.
전제:  sample 스택(Trino) 기동, dbt/domains/citydata/target/manifest.json 존재.

프로토타입 범위: d1_direct 중 소형(스냅샷 7종 + charger)·일별 4종 = 12테이블.
hourly 3종·demographics(20만 행)는 배치 분할 적재 붙일 때 확장.
"""
from __future__ import annotations

import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).parent
SAMPLE = HERE.parent
MANIFEST = SAMPLE / "dbt" / "domains" / "citydata" / "target" / "manifest.json"
BUILD = HERE / "build"
DB_NAME = "ask-seoul-citydata"
SCHEMA = "iceberg_dev.seoul_citydata"

EXPORT_TABLES = [
    "gold_citydata_place_latest", "gold_citydata_place_scorecard", "gold_citydata_hot_commerce",
    "gold_citydata_ppltn_trend", "gold_citydata_ppltn_anomaly", "gold_citydata_ppltn_forecast",
    "gold_citydata_ppltn_x_commerce_dong", "gold_citydata_charger_availability",
    "gold_citydata_ppltn_daily", "gold_citydata_cmrcl_daily",
    "gold_citydata_purchasing_power_daily", "gold_citydata_ppltn_x_culture_daily",
]

SQLITE_TYPE = {  # trino → sqlite
    "integer": "INTEGER", "bigint": "INTEGER", "smallint": "INTEGER", "tinyint": "INTEGER",
    "boolean": "INTEGER", "double": "REAL", "real": "REAL",
}


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


def wrangler_execute(file: Path, remote: bool) -> None:
    cmd = ["npx", "-y", "wrangler", "d1", "execute", DB_NAME,
           "--remote" if remote else "--local", "-y", f"--file={file}"]
    proc = subprocess.run(cmd, cwd=HERE, capture_output=True, text=True,
                          encoding="utf-8", errors="replace", timeout=600, shell=(sys.platform == "win32"))
    if proc.returncode != 0:
        raise RuntimeError(f"wrangler failed({file.name}): {(proc.stderr or proc.stdout).strip()[-400:]}")


def main() -> None:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    remote = "--remote" in sys.argv
    BUILD.mkdir(exist_ok=True)
    meta = load_meta()
    now = datetime.now(timezone.utc).isoformat()

    catalog_rows = []
    for name in EXPORT_TABLES:
        cols = trino(f"SHOW COLUMNS FROM {SCHEMA}.{name}")
        col_defs = [(c["Column"], c["Type"]) for c in cols]
        time_axis = next((c for c, t in col_defs if t.startswith(("timestamp", "date"))), None)
        rows = trino(f"SELECT * FROM {SCHEMA}.{name}")
        print(f"→ {name}: {len(rows)} rows")

        lines = [f'DROP TABLE IF EXISTS "{name}";',
                 f'CREATE TABLE "{name}" (' +
                 ", ".join(f'"{c}" {sqlite_type(t)}' for c, t in col_defs) + ");"]
        colnames = [c for c, _ in col_defs]
        for i in range(0, len(rows), 200):
            batch = rows[i:i + 200]
            values = ",\n".join("(" + ", ".join(sql_literal(r.get(c)) for c in colnames) + ")" for r in batch)
            lines.append(f'INSERT INTO "{name}" ("' + '", "'.join(colnames) + f'") VALUES\n{values};')
        f = BUILD / f"{name}.sql"
        f.write_text("\n".join(lines), encoding="utf-8")
        wrangler_execute(f, remote)

        m = meta.get(name, {})
        catalog_rows.append({
            "name": name, "description": m.get("description", ""),
            "serving_tier": m.get("serving_tier"), "tests": json.dumps(m.get("tests", []), ensure_ascii=False),
            "time_axis": time_axis,
            "columns": json.dumps([{"name": c, "type": t} for c, t in col_defs], ensure_ascii=False),
            "row_count": len(rows), "exported_at": now,
        })

    cat = ['DROP TABLE IF EXISTS _catalog;',
           'CREATE TABLE _catalog (name TEXT PRIMARY KEY, description TEXT, serving_tier TEXT, '
           'tests TEXT, time_axis TEXT, columns TEXT, row_count INTEGER, exported_at TEXT);',
           'CREATE TABLE IF NOT EXISTS _request_log (ts TEXT, path TEXT, query TEXT);']
    for r in catalog_rows:
        cat.append("INSERT INTO _catalog VALUES (" + ", ".join(sql_literal(r[k]) for k in
                   ("name", "description", "serving_tier", "tests", "time_axis", "columns", "row_count", "exported_at")) + ");")
    f = BUILD / "_catalog.sql"
    f.write_text("\n".join(cat), encoding="utf-8")
    wrangler_execute(f, remote)
    print(f"✓ exported {len(catalog_rows)} tables → D1[{'remote' if remote else 'local'}] '{DB_NAME}'")


if __name__ == "__main__":
    main()
