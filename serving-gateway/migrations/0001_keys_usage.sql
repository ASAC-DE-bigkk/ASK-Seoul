-- serving-gateway 키·쿼터 스키마 (ASK-Seoul#58 확정안)
-- 키 원문은 어디에도 저장하지 않는다 — SHA-256 해시 + 표시용 접두 8자만.

CREATE TABLE IF NOT EXISTS _keys (
  key_hash    TEXT PRIMARY KEY,
  key_prefix  TEXT NOT NULL,
  email       TEXT NOT NULL UNIQUE,
  status      TEXT NOT NULL DEFAULT 'active',
  daily_quota INTEGER NOT NULL DEFAULT 1000,
  created_at  TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS _usage (
  key_hash TEXT NOT NULL,
  day      TEXT NOT NULL,
  count    INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (key_hash, day)
);

CREATE TABLE IF NOT EXISTS _issuance_log (
  ip         TEXT NOT NULL,
  created_at TEXT NOT NULL
);
