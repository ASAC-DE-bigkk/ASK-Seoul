-- 버스트 제한 카운터 (ASK-Seoul#58 · 일일 쿼터와 다른 층위)
--
-- 쿼터는 **공정성**을 지킨다(한 사람이 하루에 얼마나 쓰나). 버스트는 **가용성**을 지킨다
-- (한 사람이 지금 이 순간 서비스를 얼마나 밀어붙이나). 둘은 목적이 달라 따로 센다.
--
-- 창(window)당 한 행이 아니라 **버킷당 한 행**이다. 창이 바뀌면 같은 행의 count 를 1 로
-- 되돌리므로, 키 하나가 아무리 오래 써도 행이 늘지 않는다. 다만 익명 IP 버킷은 서로 다른
-- 주소만큼 생기므로, 오래된 행은 _request_log 청소와 같은 확률적 sweep 에서 함께 지운다.
CREATE TABLE IF NOT EXISTS _burst (
  bucket       TEXT PRIMARY KEY,   -- 'k:<key_hash>' (인증) | 'ip:<addr>' (익명 미리보기)
  window_start TEXT NOT NULL,      -- UTC 분 'YYYY-MM-DDTHH:MM'
  count        INTEGER NOT NULL DEFAULT 0
);
