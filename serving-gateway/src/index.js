// serving-gateway — 키 발급 + 쿼터 + culture 데이터 API (ASK-Seoul#58, 로컬 전용 프로토타입)
// 게이트 순서: 키 검증 → 쿼터 카운트 → _catalog 게이트 → 조회 (#476 게이트웨이 역할의 실물 검증)
// 키 원문 무저장 — SHA-256 해시만 (#58 스키마 확정안)

const ISSUE_HOURLY_CAP = 5;
const DEFAULT_LIMIT = 500;
const MAX_LIMIT = 5000;

const json = (obj, status = 200) =>
  new Response(JSON.stringify(obj), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "access-control-allow-origin": "*",
    },
  });

const problem = (status, title, detail, extras = {}) =>
  new Response(JSON.stringify({ type: "about:blank", title, status, detail, ...extras }), {
    status,
    headers: {
      "content-type": "application/problem+json; charset=utf-8",
      "access-control-allow-origin": "*",
    },
  });

const sha256hex = async (text) => {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
};

const newKey = () => {
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  return "ask_" + [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
};

// 쿼터의 하루 경계는 KST — 파이프라인 시간축과 동일 규약
const kstDay = () => new Date(Date.now() + 9 * 3600 * 1000).toISOString().slice(0, 10);

async function issueKey(env, request) {
  let body;
  try {
    body = await request.json();
  } catch {
    return problem(400, "invalid body", "JSON body { email } 이 필요하다");
  }
  const email = String(body.email || "").trim().toLowerCase();
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email))
    return problem(400, "invalid email", "올바른 이메일 형식이 아니다");

  const ip = request.headers.get("cf-connecting-ip") || "local";
  const hourAgo = new Date(Date.now() - 3600 * 1000).toISOString();
  const { results: recent } = await env.DB.prepare(
    "SELECT COUNT(*) AS n FROM _issuance_log WHERE ip = ? AND created_at > ?"
  ).bind(ip, hourAgo).all();
  if (recent[0].n >= ISSUE_HOURLY_CAP)
    return problem(429, "issuance rate limited", `발급은 IP당 시간당 ${ISSUE_HOURLY_CAP}회까지다`);

  const key = newKey();
  const hash = await sha256hex(key);
  const prefix = key.slice(0, 8);
  const now = new Date().toISOString();

  // 이메일당 1키: 기존 키가 있으면 rotate — 해시 교체 + 오늘 사용량 승계(rotate 로 쿼터 리셋 방지)
  const existing = await env.DB.prepare("SELECT key_hash, key_prefix FROM _keys WHERE email = ?")
    .bind(email).first();

  // rotate 는 기존 키를 즉시 무효화하는 파괴적 동작 — confirm_rotate 없이는 실행하지 않는다
  if (existing && body.confirm_rotate !== true)
    return problem(409, "rotate confirmation required",
      `'${email}' 에는 이미 키(${existing.key_prefix}…)가 있다 — 재발급하면 기존 키가 즉시 만료된다. ` +
      "계속하려면 body 에 confirm_rotate: true 를 추가할 것",
      { email, key_prefix: existing.key_prefix });

  const statements = [];
  let rotated = false;
  if (existing) {
    rotated = true;
    statements.push(
      env.DB.prepare("UPDATE _usage SET key_hash = ? WHERE key_hash = ?").bind(hash, existing.key_hash),
      env.DB.prepare(
        "UPDATE _keys SET key_hash = ?, key_prefix = ?, status = 'active', created_at = ? WHERE email = ?"
      ).bind(hash, prefix, now, email)
    );
  } else {
    statements.push(
      env.DB.prepare(
        "INSERT INTO _keys (key_hash, key_prefix, email, created_at) VALUES (?, ?, ?, ?)"
      ).bind(hash, prefix, email, now)
    );
  }
  statements.push(
    env.DB.prepare("INSERT INTO _issuance_log (ip, created_at) VALUES (?, ?)").bind(ip, now)
  );
  await env.DB.batch(statements);

  return json({ key, key_prefix: prefix, rotated, note: "이 키는 지금 한 번만 표시된다 — 저장해 둘 것" }, 201);
}

async function authenticate(env, request) {
  const auth = request.headers.get("authorization") || "";
  const m = auth.match(/^Bearer\s+(ask_[0-9a-f]{32})$/i);
  if (!m) return { error: problem(401, "missing api key", "Authorization: Bearer ask_… 헤더가 필요하다 — POST /api/keys 로 발급") };
  const hash = await sha256hex(m[1]);
  const row = await env.DB.prepare(
    "SELECT key_hash, key_prefix, email, status, daily_quota FROM _keys WHERE key_hash = ?"
  ).bind(hash).first();
  if (!row) return { error: problem(401, "unknown api key", "등록되지 않은 키다") };
  if (row.status !== "active") return { error: problem(403, "revoked api key", "폐기된 키다") };
  return { keyRow: row };
}

async function countUsage(env, keyRow) {
  const day = kstDay();
  await env.DB.prepare(
    "INSERT INTO _usage (key_hash, day, count) VALUES (?, ?, 1) " +
    "ON CONFLICT(key_hash, day) DO UPDATE SET count = count + 1"
  ).bind(keyRow.key_hash, day).run();
  const row = await env.DB.prepare(
    "SELECT count FROM _usage WHERE key_hash = ? AND day = ?"
  ).bind(keyRow.key_hash, day).first();
  return { used: row.count, quota: keyRow.daily_quota, exceeded: row.count > keyRow.daily_quota };
}

async function handleCatalog(env) {
  const { results } = await env.DB.prepare(
    "SELECT name, product_id, external, product_question, time_axis, columns, row_count, exported_at " +
    "FROM _catalog ORDER BY name"
  ).all();
  return json({
    products: results.map((r) => ({ ...r, columns: JSON.parse(r.columns) })),
  });
}

// 무인증 샘플 미리보기 — 고정 5행, 필터 없음, 쿼터 무과금 ("물건을 먼저 보여준다")
const PREVIEW_ROWS = 5;
async function handlePreview(env, table, trace = {}) {
  trace.table = table;
  if (!/^[a-z0-9_]+$/.test(table))
    return problem(400, "invalid table", "테이블 이름 형식이 아니다");
  const meta = await env.DB.prepare("SELECT name, time_axis FROM _catalog WHERE name = ?")
    .bind(table).first();
  if (!meta) return problem(404, "unknown table", `'${table}' 은 서빙 카탈로그에 없다 — GET /api/catalog 참조`);
  // 시간축이 있으면 최신 구간을 보여준다 — 미리보기의 존재 이유는 "실물이 쓸만한가"의 판단
  const order = meta.time_axis ? ` ORDER BY "${meta.time_axis}" DESC` : "";
  const { results } = await env.DB.prepare(
    `SELECT * FROM "${table}"${order} LIMIT ${PREVIEW_ROWS}`
  ).all();
  trace.rows = results.length;
  return json({ table, preview: true, row_count: results.length, rows: results });
}

async function handleData(env, table, params, keyRow, trace = {}) {
  trace.table = table;
  if (!/^[a-z0-9_]+$/.test(table))
    return problem(400, "invalid table", "테이블 이름 형식이 아니다");
  const meta = await env.DB.prepare("SELECT * FROM _catalog WHERE name = ?").bind(table).first();
  if (!meta) return problem(404, "unknown table", `'${table}' 은 서빙 카탈로그에 없다 — GET /api/catalog 참조`);

  const columns = JSON.parse(meta.columns);
  const colSet = new Set(columns.map((c) => c.name));
  const where = [];
  const binds = [];
  for (const [k, v] of params.entries()) {
    if (k === "limit" || k === "from" || k === "to") continue;
    if (!colSet.has(k))
      return problem(400, "unknown filter", `'${k}' 컬럼 없음 — 사용 가능: ${[...colSet].join(", ")}`);
    where.push(`"${k}" = ?`);
    binds.push(v);
    // 필터는 컬럼명만 기록한다 — 어떤 축으로 자르는지가 알고 싶은 것이고, 값은 남길 이유가 없다
    trace.filterCols = (trace.filterCols || []).concat(k);
  }
  if (params.get("from") || params.get("to")) {
    if (!meta.time_axis)
      return problem(400, "no time axis", `'${table}' 은 시간축이 없어 from/to 를 지원하지 않는다`);
    if (params.get("from")) { where.push(`"${meta.time_axis}" >= ?`); binds.push(params.get("from")); }
    if (params.get("to")) { where.push(`"${meta.time_axis}" <= ?`); binds.push(params.get("to")); }
  }
  const limit = Math.min(parseInt(params.get("limit") || String(DEFAULT_LIMIT), 10) || DEFAULT_LIMIT, MAX_LIMIT);

  // 쿼터는 유효한 요청(실제 서빙 직전)만 소모 — 400/404 는 무과금
  const usage = await countUsage(env, keyRow);
  if (usage.exceeded)
    return problem(429, "daily quota exceeded", `일일 쿼터 ${usage.quota}건 소진 — KST 자정에 리셋`);

  const sql = `SELECT * FROM "${table}"${where.length ? " WHERE " + where.join(" AND ") : ""} LIMIT ${limit}`;
  const { results } = await env.DB.prepare(sql).bind(...binds).all();
  trace.rows = results.length;
  return json({
    table,
    row_count: results.length,
    limit,
    time_axis: meta.time_axis,
    usage: { used: usage.used, daily_quota: usage.quota },
    rows: results,
  });
}

async function handleMe(env, keyRow) {
  const day = kstDay();
  const row = await env.DB.prepare(
    "SELECT count FROM _usage WHERE key_hash = ? AND day = ?"
  ).bind(keyRow.key_hash, day).first();
  return json({
    key_prefix: keyRow.key_prefix,
    email: keyRow.email,
    day,
    used_today: row ? row.count : 0,
    daily_quota: keyRow.daily_quota,
  });
}

// 요청 로그 — 무엇이 실제로 쓰이는지 재는 유일한 근거. 실패해도 서빙을 깨뜨리지 않는다.
const LOG_RETENTION_DAYS = 30;
const LOG_SWEEP_RATE = 0.02;  // 크론 없이, 로그 100건당 ~2회 낡은 행 청소

async function logRequest(env, trace) {
  try {
    await env.DB.prepare(
      "INSERT INTO _request_log (ts, route, table_name, status, key_hash, filters, row_count, ms) " +
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
    ).bind(
      new Date().toISOString(), trace.route, trace.table ?? null, trace.status,
      trace.keyHash ?? null, trace.filterCols ? trace.filterCols.join(",") : null,
      trace.rows ?? null, trace.ms
    ).run();
    if (Math.random() < LOG_SWEEP_RATE) {
      const cutoff = new Date(Date.now() - LOG_RETENTION_DAYS * 86400000).toISOString();
      await env.DB.prepare("DELETE FROM _request_log WHERE ts < ?").bind(cutoff).run();
    }
  } catch {
    // 관측 실패가 응답에 영향을 주면 안 된다 — 조용히 버린다
  }
}

async function route(request, env, url, trace) {
  const path = url.pathname;

  if (path === "/api/keys" && request.method === "POST") {
    trace.route = "keys";
    return issueKey(env, request);
  }
  if (request.method !== "GET") return problem(405, "method not allowed", "조회 전용 API");
  if (path === "/api/catalog") { trace.route = "catalog"; return handleCatalog(env); }

  const previewMatch = path.match(/^\/api\/preview\/([^/]+)$/);
  if (previewMatch) {
    trace.route = "preview";
    return handlePreview(env, decodeURIComponent(previewMatch[1]), trace);
  }

  const dataMatch = path.match(/^\/api\/data\/([^/]+)$/);
  if (dataMatch || path === "/api/me") {
    trace.route = dataMatch ? "data" : "me";
    const { keyRow, error } = await authenticate(env, request);
    if (error) return error;
    trace.keyHash = keyRow.key_hash;
    if (path === "/api/me") return handleMe(env, keyRow);
    return handleData(env, decodeURIComponent(dataMatch[1]), url.searchParams, keyRow, trace);
  }

  return problem(404, "not found", "GET /api/catalog · /api/data/<table> · /api/me, POST /api/keys");
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    if (request.method === "OPTIONS")
      return new Response(null, {
        status: 204,
        headers: {
          "access-control-allow-origin": "*",
          "access-control-allow-headers": "authorization, content-type",
          "access-control-allow-methods": "GET, POST, OPTIONS",
        },
      });

    const started = Date.now();
    const trace = { route: null };
    const res = await route(request, env, url, trace);

    // 라우트가 정해진 API 요청만 기록한다 (정적 자산·404 잡음 제외)
    if (trace.route) {
      trace.status = res.status;
      trace.ms = Date.now() - started;
      const write = logRequest(env, trace);
      if (ctx && ctx.waitUntil) ctx.waitUntil(write);  // 응답을 붙잡지 않는다
    }
    return res;
  },
};
