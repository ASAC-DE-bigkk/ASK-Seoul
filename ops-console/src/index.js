// ops-console — 운영자용 통합 품질 콘솔 (ASK-Seoul#58, 로컬 전용)
//
// 한 화면에서 두 가지를 본다:
//   · 파이프라인 품질 — 수집·변환이 제 몫을 했나 (_ops_slo, gold_*_slo_daily 스냅샷)
//   · 서빙 품질       — 외부에 잘 나가고 있나 (_request_log, 게이트웨이가 쌓는다)
// 둘 다 같은 D1 을 읽는다. 마켓플레이스와는 **다른 Worker · 다른 호스트**다 — 청중이 다르고,
// 배포 단위가 갈려야 사고 반경도 갈린다.
//
// 인증: 읽기는 열려 있고 **조치만** 공유 토큰(OPS_TOKEN)으로 잠근다 — canWrite/requireWrite 참고.
// 공유 토큰은 "누가 했나"가 남지 않는 약한 인증이라, 공개 배포 시 Cloudflare Access /
// org OAuth 로 교체해야 한다(멘토 게이트). 조치 쪽은 토큰 미설정이면 503 으로 닫힌다.

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

// 읽기와 쓰기를 **다른 문**으로 나눈다.
//   읽기(요약·키 목록) — 토큰 없이 연다. 팀에 화면을 보여주는 게 이 콘솔의 쓸모이고,
//     이메일은 이미 응답 단계에서 마스킹되기 때문이다.
//   쓰기(폐기·복구·쿼터·삭제) — 언제나 토큰이 필요하다. 되돌릴 수 없는 조치를
//     주소 아는 사람 전부에게 열어둘 수는 없다.
//
// 원래는 토큰이 없으면 503 으로 화면 전체를 껐다. 그 취지("인증 없는 운영 화면이 실수로
// 열리는 것보다 낫다")는 버린 게 아니라 **쓰기 쪽으로 옮긴** 것이다.
function canWrite(env, request) {
  const token = String(env.OPS_TOKEN || "").trim();
  if (!token) return false;
  const got = (request.headers.get("authorization") || "").replace(/^Bearer\s+/i, "").trim();
  return Boolean(got) && timingSafeEqual(got, token);
}

function requireWrite(env, request) {
  const token = String(env.OPS_TOKEN || "").trim();
  if (!token) return problem(503, "ops write disabled", "OPS_TOKEN 미설정 — 조치하려면 .dev.vars 에 설정할 것");
  if (!canWrite(env, request)) return problem(401, "unauthorized", "조치에는 운영자 토큰이 필요하다");
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

async function summary(env, params, writable = false) {
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
      can_write: writable,
      // 샘플이 한 행이라도 섞여 있으면 화면 전체에 배지를 띄운다 — 조용히 섞이는 게 제일 나쁘다
      pipeline_is_sample: slo.rows.some((r) => r.is_sample === 1),
    },
    pipeline: { domains: domains.rows, slo: slo.rows },
    serving: { routes: routes.rows, daily: daily.rows, products: products.rows,
               failures: failures.rows, empty: empty.rows, keys: keys.rows },
  });
}

// ── 키 관리 ───────────────────────────────────────────────────────────────────────
// 게이트웨이가 발급한 키를 운영자가 보고 손대는 자리. 게이트웨이의 셀프 폐기(DELETE /api/keys)와
// 다른 점은 **키 원문 없이** 처리한다는 것 — 이용자는 키를 잃어버려도 우리는 조치할 수 있어야 한다.
//
// 식별자는 key_prefix 가 아니라 key_hash 다. prefix 는 8자(ask_+4hex)라 충돌할 수 있고,
// 엉뚱한 사람의 키를 폐기하는 사고는 되돌리기 어렵다. hash 는 자격증명이 아니다 —
// 인증에는 원문이 필요하므로 해시를 알아도 호출할 수 없다.
const HASH_RE = /^[0-9a-f]{64}$/;
const MIN_QUOTA = 0, MAX_QUOTA = 1000000;

// 이메일은 **응답에서** 가린다. 화면에서만 가리면 API 응답·개발자도구·curl 에 원문이 그대로
// 남아서 가린 게 아니다. 운영자가 실제로 필요한 건 "어느 행이 누구 것인지 구분"이지 주소 자체가
// 아니고, 조치는 전부 key_hash 로 돈다 — 그래서 원문을 내보낼 이유가 없다.
// 정말로 전체 주소가 필요한 드문 경우는 D1 을 직접 조회한다(운영자는 DB 접근 권한이 있다).
function maskEmail(email) {
  const s = String(email || "");
  const at = s.lastIndexOf("@");
  if (at < 1) return "***";                       // 이메일 형태가 아니면 통째로 가린다
  const local = s.slice(0, at);
  return local.slice(0, Math.min(2, local.length)) + "***@" + s.slice(at + 1);
}

async function listKeys(env) {
  // 쿼터의 하루 경계는 KST — 게이트웨이 kstDay() 와 같은 규약이어야 숫자가 맞는다
  const res = await safeRows(env,
    "SELECT k.key_hash, k.key_prefix, k.email, k.status, k.daily_quota, k.created_at, " +
    "COALESCE(u.count, 0) AS used_today, " +
    "(SELECT COUNT(*) FROM _request_log r WHERE r.key_hash = k.key_hash) AS calls_logged, " +
    "(SELECT MAX(r.ts) FROM _request_log r WHERE r.key_hash = k.key_hash) AS last_call " +
    "FROM _keys k LEFT JOIN _usage u ON u.key_hash = k.key_hash AND u.day = date('now', '+9 hours') " +
    "ORDER BY k.created_at DESC");
  // email 은 여기서 사라진다 — 응답 객체에 원문이 담기는 경로를 남기지 않는다.
  // 키 이름도 email_masked 로 바꿔, 나중에 이 값을 실제 주소로 착각하지 않게 한다.
  return {
    ok: res.ok,
    rows: res.rows.map(({ email, ...rest }) => ({ ...rest, email_masked: maskEmail(email) })),
  };
}

async function keyAction(env, request) {
  let body;
  try { body = await request.json(); } catch { return problem(400, "invalid body", "JSON 본문이 필요하다"); }
  const { action, key_hash: hash } = body || {};
  if (!HASH_RE.test(String(hash || ""))) return problem(400, "invalid key", "key_hash 형식이 아니다");

  const row = await env.DB.prepare("SELECT key_hash, key_prefix, status FROM _keys WHERE key_hash = ?")
    .bind(hash).first();
  if (!row) return problem(404, "unknown key", "그런 키가 없다");

  if (action === "revoke" || action === "restore") {
    const status = action === "revoke" ? "revoked" : "active";
    await env.DB.prepare("UPDATE _keys SET status = ? WHERE key_hash = ?").bind(status, hash).run();
    return json({ key_prefix: row.key_prefix, status });
  }
  if (action === "quota") {
    const q = parseInt(body.daily_quota, 10);
    if (!Number.isInteger(q) || q < MIN_QUOTA || q > MAX_QUOTA)
      return problem(400, "invalid quota", `daily_quota 는 ${MIN_QUOTA}~${MAX_QUOTA} 정수여야 한다`);
    await env.DB.prepare("UPDATE _keys SET daily_quota = ? WHERE key_hash = ?").bind(q, hash).run();
    return json({ key_prefix: row.key_prefix, daily_quota: q });
  }
  if (action === "delete") {
    // 이용자의 삭제 요청을 운영자가 대신 처리하는 경로. 요청 로그의 key_hash 는 남지만
    // 해시→이메일 대응이 사라져 사람과 연결되지 않는다(처리방침에 적은 그대로).
    await env.DB.batch([
      env.DB.prepare("DELETE FROM _usage WHERE key_hash = ?").bind(hash),
      env.DB.prepare("DELETE FROM _burst WHERE bucket = ?").bind("k:" + hash),
      env.DB.prepare("DELETE FROM _keys WHERE key_hash = ?").bind(hash),
    ]);
    return json({ key_prefix: row.key_prefix, deleted: true });
  }
  return problem(400, "unknown action", "action 은 revoke·restore·quota·delete 중 하나여야 한다");
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/api/summary") {
      if (request.method !== "GET") return problem(405, "method not allowed", "조회 전용");
      return summary(env, url.searchParams, canWrite(env, request));
    }
    if (url.pathname === "/api/keys") {
      if (request.method === "GET") {
        const res = await listKeys(env);
        // can_write 는 화면이 조치 버튼을 낼지 정하는 근거다. 이걸 못 믿어도 상관없다 —
        // 실제 차단은 POST 쪽 requireWrite 가 한다(화면 조작으로 뚫리지 않는다).
        return json({ ok: res.ok, keys: res.rows, can_write: canWrite(env, request),
                      generated_at: new Date().toISOString() });
      }
      if (request.method === "POST") return requireWrite(env, request) || keyAction(env, request);
      return problem(405, "method not allowed", "GET(목록) · POST(조치)");
    }
    if (url.pathname.startsWith("/api/")) return problem(404, "not found", "GET /api/summary · /api/keys");
    return env.ASSETS ? env.ASSETS.fetch(request) : problem(404, "not found", "정적 자산 없음");
  },
};
