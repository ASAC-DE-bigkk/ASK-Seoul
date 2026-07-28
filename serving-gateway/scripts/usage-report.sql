-- 사용 리포트 — "무엇이 실제로 쓰이나"를 묻는 질문 7개 (ASK-Seoul#58)
-- 실행: npm run usage        (로컬 D1)
--
-- 읽는 순서가 곧 제품 판단 순서다:
--   ①②로 규모를 보고 → ③④로 수요를 보고 → ⑤⑥이 로드맵을 준다 → ⑦이 진짜 사용자인지 답한다

-- ① 라우트별 호출 (최근 7일) — 퍼널의 각 칸에 사람이 얼마나 있나
SELECT '① 라우트별' AS report, route, COUNT(*) AS calls,
       SUM(status >= 400) AS errors, ROUND(AVG(ms), 1) AS avg_ms
FROM _request_log WHERE ts >= datetime('now', '-7 days')
GROUP BY route ORDER BY calls DESC;

-- ② 일자별 추이 — 늘고 있나 줄고 있나
SELECT '② 일자별' AS report, substr(ts, 1, 10) AS day, COUNT(*) AS calls,
       COUNT(DISTINCT key_hash) AS keys_used
FROM _request_log WHERE ts >= datetime('now', '-30 days')
GROUP BY day ORDER BY day DESC;

-- ③ 인기 제품 — 카탈로그 우선순위의 근거. preview 는 '구경', data 는 '실사용'이라 나눠 센다
SELECT '③ 제품별' AS report, table_name,
       SUM(route = 'preview') AS previews,
       SUM(route = 'data') AS calls,
       ROUND(AVG(row_count), 1) AS avg_rows
FROM _request_log WHERE table_name IS NOT NULL AND ts >= datetime('now', '-30 days')
GROUP BY table_name ORDER BY calls DESC, previews DESC;

-- ④ 필터 축 수요 — 어떤 컬럼으로 자르나. 계약에 인덱스·파티션을 어디 둘지의 근거
SELECT '④ 필터축' AS report, filters, COUNT(*) AS uses
FROM _request_log WHERE filters IS NOT NULL AND ts >= datetime('now', '-30 days')
GROUP BY filters ORDER BY uses DESC LIMIT 20;

-- ⑤ 없어서 못 판 것 — 404(없는 테이블)·400(없는 컬럼)은 그대로 로드맵이다
SELECT '⑤ 실패' AS report, status, route, table_name, COUNT(*) AS hits
FROM _request_log WHERE status >= 400 AND ts >= datetime('now', '-30 days')
GROUP BY status, route, table_name ORDER BY hits DESC LIMIT 20;

-- ⑥ 조용한 0행 — 200 인데 빈 응답. 커버리지 구멍이거나 사용자가 기대를 잘못 잡은 지점
SELECT '⑥ 0행응답' AS report, table_name, filters, COUNT(*) AS empty_responses
FROM _request_log WHERE status = 200 AND row_count = 0 AND ts >= datetime('now', '-30 days')
GROUP BY table_name, filters ORDER BY empty_responses DESC LIMIT 20;

-- ⑦ 진짜 쓰는 사람인가 — 발급만 받고 만 키 vs 여러 날 돌아온 키
SELECT '⑦ 키별' AS report, substr(key_hash, 1, 8) AS key_id,
       COUNT(*) AS calls, COUNT(DISTINCT substr(ts, 1, 10)) AS active_days,
       MIN(substr(ts, 1, 10)) AS first_day, MAX(substr(ts, 1, 10)) AS last_day
FROM _request_log WHERE key_hash IS NOT NULL
GROUP BY key_hash ORDER BY calls DESC LIMIT 20;
