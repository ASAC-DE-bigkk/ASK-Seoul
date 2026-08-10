from __future__ import annotations

import csv
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
DAG_GRID_PATH = ROOT / "dags" / "domains" / "weather" / "config" / "seoul_kma_grids.csv"
DBT_GRID_PATH = ROOT / "dbt" / "domains" / "traffic_weather" / "seeds" / "weather" / "weather_coverage_grid.csv"
EXPECTED_GRID_COORDINATES = {
    (nx, ny) for nx in range(56, 66) for ny in range(123, 131)
}


def _coordinates(path: Path) -> list[tuple[int, int]]:
    with path.open(newline="", encoding="utf-8") as handle:
        return [(int(row["nx"]), int(row["ny"])) for row in csv.DictReader(handle)]


def test_weather_collector_and_dbt_coverage_seed_share_the_exact_80_grid_contract():
    dag_coordinates = _coordinates(DAG_GRID_PATH)
    dbt_coordinates = _coordinates(DBT_GRID_PATH)

    assert len(dag_coordinates) == 80
    assert len(dbt_coordinates) == 80
    assert len(set(dag_coordinates)) == 80
    assert len(set(dbt_coordinates)) == 80
    assert set(dag_coordinates) == EXPECTED_GRID_COORDINATES
    assert set(dbt_coordinates) == EXPECTED_GRID_COORDINATES
