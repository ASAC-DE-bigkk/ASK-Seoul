"""dbt 계약(yml) → public/column-docs.json — 카탈로그 상세의 컬럼 설명 (ASK-Seoul#58).

**왜 별도 파일인가**: 컬럼 설명의 정본은 ASAC-DBT 계약이지만, 서빙까지 실려오지
않는다. `common/serving/publisher.py` 의 `_catalog.columns` 직렬화가
`{"name", "type"}` 만 담기 때문이다(그 파일은 공유 인프라라 도메인이 못 고친다).

그래서 **같은 정본에서 뽑아 프로토타입에 옮기는** 생성기를 둔다. 손으로 옮긴
사전이 아니라 생성물이므로 계약이 바뀌면 재실행만 하면 되고, 드리프트가 나면
`--check` 가 잡는다. 이 파일의 존재 자체가 "계약 v1.2 에 컬럼 설명을 넣자"는
제안(#476)의 근거다 — 채택되면 이 스크립트는 지운다.

실행:
    python fixtures/build_column_docs.py            # 생성
    python fixtures/build_column_docs.py --check    # 최신인지만 확인 (CI 용)
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import yaml

HERE = Path(__file__).resolve().parent
GATEWAY = HERE.parent
# sample/serving-gateway/fixtures → ask-seoul/
REPO = GATEWAY.parent.parent
CONTRACT = REPO / "ASAC-DBT/domains/culture/models/gold/_culture_gold__models.yml"
OUT = GATEWAY / "public/column-docs.json"


def build() -> dict:
    doc = yaml.safe_load(CONTRACT.read_text(encoding="utf-8"))
    out: dict[str, dict[str, str]] = {}
    for model in doc.get("models") or []:
        name = model.get("name")
        cols = {
            c["name"]: c["description"].strip()
            for c in (model.get("columns") or [])
            if c.get("name") and c.get("description")
        }
        if name and cols:
            out[name] = cols
    return out


def main() -> int:
    if not CONTRACT.exists():
        print(f"계약 파일 없음: {CONTRACT}", file=sys.stderr)
        return 2
    fresh = build()
    body = json.dumps(fresh, ensure_ascii=False, indent=1, sort_keys=True) + "\n"

    if "--check" in sys.argv:
        current = OUT.read_text(encoding="utf-8") if OUT.exists() else ""
        if current != body:
            print(f"column-docs.json 이 계약과 다릅니다 — `python {Path(__file__).name}` 재실행 필요",
                  file=sys.stderr)
            return 1
        print(f"최신 — 모델 {len(fresh)}종")
        return 0

    OUT.write_text(body, encoding="utf-8")
    total = sum(len(v) for v in fresh.values())
    print(f"{OUT.relative_to(GATEWAY)} — 모델 {len(fresh)}종 · 컬럼 설명 {total}개")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
