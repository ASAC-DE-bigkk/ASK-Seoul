// ops-console — 운영자용 통합 품질 콘솔 (ASK-Seoul#58, 로컬 전용)
//
// 한 화면에서 두 가지를 본다:
//   · 파이프라인 품질 — 수집·변환이 제 몫을 했나 (_ops_slo, gold_*_slo_daily 스냅샷)
//   · 서빙 품질       — 외부에 잘 나가고 있나 (_request_log, 게이트웨이가 쌓는다)
// 둘 다 같은 D1 을 읽는다. 마켓플레이스와는 **다른 Worker · 다른 호스트**다 — 청중이 다르고,
// 배포 단위가 갈려야 사고 반경도 갈린다.
//
// 인증: 공유 토큰(OPS_TOKEN). "누가 봤나"가 남지 않는 약한 인증이라 공개 배포 시
// Cloudflare Access / org OAuth 로 교체해야 한다(멘토 게이트). 토큰 미설정이면 503 으로
// 기능을 끈다 — 인증 없는 운영 화면이 실수로 열리는 것보다 낫다.

const DEFAULT_DAYS = 14;
const MAX_DAYS = 90;

const json = (obj, status = 200) =>
  new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
  });

const problem = (status, title, detail) =>
  new Response(JSON.stringify({ type: "about:blank", title, status, detail }), {
    status,
    headers: { "content-type": "application/problem+json; charset=utf-8", "cache-control": "no-store" },
  });

function timingSafeEqual(a, b) {
  const enc = new TextEncoder();
  const x = enc.encode(a), y = enc.encode(b);
  // 길이가 달라도 조기 반환하지 않는다 — 비교 시간으로 길이를 알려주지 않기 위해
  let diff = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}

function gate(env, request) {
  const token = String(env.OPS_TOKEN || "").trim();
  if (!token) return problem(503, "ops disabled", "OPS_TOKEN 미설정 — .dev.vars 에 설정하면 켜진다");
  const got = (request.headers.get("authorization") || "").replace(/^Bearer\s+/i, "").trim();
  if (!got || !timingSafeEqual(got, token)) return problem(401, "unauthorized", "운영자 토큰이 필요하다");
  return null;
}

// 테이블이 아직 없을 수 있다(게이트웨이만 시드한 상태 등) — 콘솔 전체가 죽는 대신
// 그 섹션만 비운다. 어느 쪽이 없는지는 meta.missing 으로 화면에 알린다.
async function safeRows(env, sql, ...bind) {
  try {
    return { rows: (await env.DB.prepare(sql).bind(...bind).all()).results, ok: true };
  } catch {
    return { rows: [], ok: false };
  }
}

async function summary(env, params) {
  const days = Math.min(MAX_DAYS, Math.max(1, parseInt(params.get("days"), 10) || DEFAULT_DAYS));
  const since = `-${days} days`;
  const missing = [];

  // ── 파이프라인
  const domains = await safeRows(env, "SELECT domain, label, has_slo, note FROM _ops_domain ORDER BY has_slo DESC, domain");
  const slo = await safeRows(env,
    "SELECT * FROM _ops_slo WHERE event_date >= date('now', ?) ORDER BY event_date", since);
  if (!domains.ok || !slo.ok) missing.push("pipeline");

  // ── 서빙 (게이트웨이가 쌓는 _request_log)
  const routes = await safeRows(env,
    "SELECT route, COUNT(*) AS calls, SUM(status >= 400) AS errors, ROUND(AVG(ms),1) AS avg_ms " +
    "FROM _request_log WHERE ts >= datetime('now', ?) GROUP BY route ORDER BY calls DESC", since);
  if (!routes.ok) missing.push("serving");
  const [daily, products, failures, empty, keys] = await Promise.all([
    safeRows(env, "SELECT substr(ts,1,10) AS day, COUNT(*) AS calls, COUNT(DISTINCT key_hash) AS keys_used " +
      "FROM _request_log WHERE ts >= datetime('now', ?) GROUP BY day ORDER BY day", since),
    safeRows(env, "SELECT table_name, SUM(route='preview') AS previews, SUM(route='data') AS calls, " +
      "ROUND(AVG(row_count),1) AS avg_rows FROM _request_log " +
      "WHERE table_name IS NOT NULL AND ts >= datetime('now', ?) " +
      "GROUP BY table_name ORDER BY calls DESC, previews DESC LIMIT 12", since),
    safeRows(env, "SELECT status, route, table_name, COUNT(*) AS hits FROM _request_log " +
      "WHERE status >= 400 AND ts >= datetime('now', ?) GROUP BY status, route, table_name " +
      "ORDER BY hits DESC LIMIT 10", since),
    safeRows(env, "SELECT table_name, filters, COUNT(*) AS empty_responses FROM _request_log " +
      "WHERE status = 200 AND row_count = 0 AND ts >= datetime('now', ?) " +
      "GROUP BY table_name, filters ORDER BY empty_responses DESC LIMIT 10", since),
    safeRows(env, "SELECT substr(key_hash,1,8) AS key_id, COUNT(*) AS calls, " +
      "COUNT(DISTINCT substr(ts,1,10)) AS active_days FROM _request_log " +
      "WHERE key_hash IS NOT NULL AND ts >= datetime('now', ?) GROUP BY key_hash " +
      "ORDER BY calls DESC LIMIT 10", since),
  ]);

  return json({
    window_days: days,
    generated_at: new Date().toISOString(),
    meta: {
      missing,
      // 샘플이 한 행이라도 섞여 있으면 화면 전체에 배지를 띄운다 — 조용히 섞이는 게 제일 나쁘다
      pipeline_is_sample: slo.rows.some((r) => r.is_sample === 1),
    },
    pipeline: { domains: domains.rows, slo: slo.rows },
    serving: { routes: routes.rows, daily: daily.rows, products: products.rows,
               failures: failures.rows, empty: empty.rows, keys: keys.rows },
  });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/api/summary") {
      if (request.method !== "GET") return problem(405, "method not allowed", "조회 전용");
      return gate(env, request) || summary(env, url.searchParams);
    }
    if (url.pathname.startsWith("/api/")) return problem(404, "not found", "GET /api/summary");
    return env.ASSETS ? env.ASSETS.fetch(request) : problem(404, "not found", "정적 자산 없음");
  },
};
