-- 요청 로그 — "무엇이 실제로 쓰이나"를 재기 위한 최소 스키마 (ASK-Seoul#58)
--
-- 설계 원칙 3가지:
--  1. 값이 아니라 축만 남긴다 — 필터는 **컬럼명만** 저장하고 값은 버린다.
--     우리가 알고 싶은 건 "어떤 축으로 자르나"이지 "누가 뭘 찾았나"가 아니다.
--  2. 식별자는 이미 해시인 것만 — key_hash 만 남기고 이메일·IP 는 넣지 않는다.
--     익명 미리보기는 key_hash 가 NULL 이라 사람 단위 집계가 불가능한데, 그게 의도다.
--  3. 무한 증식 금지 — D1 은 DB당 10GB 라 보존 기간을 코드가 강제한다(30일, Worker 가 정리).

CREATE TABLE IF NOT EXISTS _request_log (
  ts         TEXT    NOT NULL,  -- ISO8601 UTC
  route      TEXT    NOT NULL,  -- catalog | preview | data | me | keys | showcase
  table_name TEXT,              -- 조회 대상 (해당 없으면 NULL)
  status     INTEGER NOT NULL,
  key_hash   TEXT,              -- 인증 요청만. 익명은 NULL
  filters    TEXT,              -- 사용한 필터 컬럼명 CSV — 값은 저장하지 않는다
  row_count  INTEGER,           -- 응답 행수 (0행이 반복되면 그 자체가 신호)
  ms         INTEGER            -- 처리 시간
);

-- 리포트가 "최근 N일"과 "테이블별"로만 조회하므로 인덱스는 이 둘이면 충분하다
CREATE INDEX IF NOT EXISTS idx_request_log_ts ON _request_log (ts);
CREATE INDEX IF NOT EXISTS idx_request_log_table ON _request_log (table_name, ts);
