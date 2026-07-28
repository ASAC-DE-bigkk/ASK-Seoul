-- 파이프라인 품질 스냅샷 — gold_*_slo_daily 를 D1 로 밀어 넣는 자리 (ASK-Seoul#58)
--
-- **왜 복사하나**: Trino 는 `http://trino:8080`, Docker 내부 주소라 Cloudflare Worker 가
-- 닿지 못한다. 그래서 운영 콘솔이 파이프라인 품질을 보려면 요약을 밀어 넣는 수밖에 없다.
-- 다행히 SLO 마트는 **날짜 1행**이라 도메인 6개 × 1년 = 2,200행 — 웨어하우스를 옮기는 게
-- 아니라 요약 한 줌을 옮기는 것이다.
--
-- **is_sample**: 로컬 프로토타입에는 팀 D1 쓰기 권한이 없어 합성 데이터를 시드한다.
-- 화면이 그걸 실측인 척하면 안 되므로 행마다 표시하고, UI 는 '샘플' 배지를 띄운다.
-- 실적재가 붙으면 is_sample=0 이 들어오고 배지는 저절로 사라진다.

-- 프로토타입이라 스키마 정본을 이 파일 하나로 유지한다 — 컬럼이 늘 때 ALTER 누적 대신
-- 통째로 다시 만든다. 내용물은 로더(scripts/load_slo.py)나 픽스처가 매번 다시 채우므로
-- 잃을 상태가 없다. 팀 D1 로 승격되면 그때부터 증분 마이그레이션으로 바꾼다.
DROP TABLE IF EXISTS _ops_slo;
DROP TABLE IF EXISTS _ops_domain;

CREATE TABLE IF NOT EXISTS _ops_slo (
  domain               TEXT    NOT NULL,
  event_date           TEXT    NOT NULL,  -- KST 집계일
  scheduled_slo_passed INTEGER,           -- 정기런이 제 몫을 했나 (bool)
  eod_slo_passed       INTEGER,           -- 그날이 끝날 때 데이터가 있었나 (bool)
  best_coverage_pct    REAL,
  failed_dataset_count INTEGER,
  violation_count      INTEGER,           -- 계약(min_rows 등) 위반
  total_rows           INTEGER,
  ingest_duration_min  REAL,
  transform_runs       INTEGER,
  transform_all_success INTEGER,          -- bool
  maintenance_ran      INTEGER,           -- bool
  -- 초록 위장: Airflow 는 success 인데 expected=0 (전멸을 통과로 착각). 7/7 실사례에서
  -- 나온 컬럼이라 반드시 실어야 한다 — SLO 가 통과로 보이는데 실제로는 빈 날이다.
  green_disguise_runs  INTEGER,
  is_sample            INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (domain, event_date)
);

CREATE INDEX IF NOT EXISTS idx_ops_slo_date ON _ops_slo (event_date);

-- 도메인 등록부 — "SLO 마트를 가진 도메인이 몇 개인가"를 화면이 세려면 분모가 필요하다.
-- 실측(2026-07-28): ASAC-DBT 전체에서 *_slo_daily 는 culture 하나뿐이다. 그 사실 자체가
-- 콘솔이 드러내야 할 관측이라, 없는 도메인도 행으로 남긴다.
CREATE TABLE IF NOT EXISTS _ops_domain (
  domain     TEXT PRIMARY KEY,
  label      TEXT NOT NULL,
  has_slo    INTEGER NOT NULL DEFAULT 0,
  note       TEXT
);
