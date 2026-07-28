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
async function handlePreview(env, table) {
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
  return json({ table, preview: true, row_count: results.length, rows: results });
}

// 공개 쇼케이스 — 랜딩이 데이터를 "설명"하는 대신 "보여주게" 하는 무인증·무과금 엔드포인트.
// 고정 소량 집계 + 엣지 캐시라 쿼터를 태우지 않는다. 실패한 조각은 null 로 빠지고 나머지는 살린다.
const SHOWCASE_EVENTS = 6;
const SHOWCASE_CHART = 5;

const tryQuery = async (fn) => { try { return await fn(); } catch { return null; } };

async function handleShowcase(env) {
  // 진행 중 행사. 없으면(로컬 픽스처처럼 과거분만 실린 경우) 최신순 폴백 — live 플래그로 UI 가 문구를 바꾼다
  const cols = "title, venue_name, gu, category, event_start_date, event_end_date";
  let live = true;
  let events = await tryQuery(async () => (await env.DB.prepare(
    `SELECT ${cols} FROM gold_culture_event_schedule WHERE event_end_date >= date('now') ` +
    "ORDER BY event_start_date LIMIT ?"
  ).bind(SHOWCASE_EVENTS).all()).results);
  if (events && !events.length) {
    live = false;
    events = await tryQuery(async () => (await env.DB.prepare(
      `SELECT ${cols} FROM gold_culture_event_schedule ORDER BY event_start_date DESC LIMIT ?`
    ).bind(SHOWCASE_EVENTS).all()).results);
  }

  const chart = await tryQuery(async () => {
    const snap = await env.DB.prepare(
      "SELECT MAX(snapshot_date) AS d FROM gold_culture_boxoffice_daily"
    ).first();
    if (!snap || !snap.d) return null;
    const { results } = await env.DB.prepare(
      "SELECT rank_no, performance_name, genre, venue_name, gu, rank_delta_3d, is_new_entry " +
      "FROM gold_culture_boxoffice_daily WHERE snapshot_date = ? ORDER BY rank_no LIMIT ?"
    ).bind(snap.d, SHOWCASE_CHART).all();
    return { snapshot_date: snap.d, rows: results };
  });

  const density = await tryQuery(async () => {
    const { results } = await env.DB.prepare(
      "SELECT event_date, SUM(total_events) AS events, COUNT(DISTINCT gu_code) AS gus " +
      "FROM gold_culture_calendar_density GROUP BY event_date ORDER BY event_date"
    ).all();
    return results;
  });

  return new Response(
    JSON.stringify({ events: { live, rows: events || [] }, chart, density }),
    {
      headers: {
        "content-type": "application/json; charset=utf-8",
        "access-control-allow-origin": "*",
        "cache-control": "public, max-age=300",
      },
    }
  );
}

async function handleData(env, table, params, keyRow) {
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

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname;

    if (request.method === "OPTIONS")
      return new Response(null, {
        status: 204,
        headers: {
          "access-control-allow-origin": "*",
          "access-control-allow-headers": "authorization, content-type",
          "access-control-allow-methods": "GET, POST, OPTIONS",
        },
      });

    if (path === "/api/keys" && request.method === "POST") return issueKey(env, request);
    if (request.method !== "GET") return problem(405, "method not allowed", "조회 전용 API");
    if (path === "/api/catalog") return handleCatalog(env);
    if (path === "/api/showcase") return handleShowcase(env);

    const previewMatch = path.match(/^\/api\/preview\/([^/]+)$/);
    if (previewMatch) return handlePreview(env, decodeURIComponent(previewMatch[1]));

    const dataMatch = path.match(/^\/api\/data\/([^/]+)$/);
    if (dataMatch || path === "/api/me") {
      const { keyRow, error } = await authenticate(env, request);
      if (error) return error;
      if (path === "/api/me") return handleMe(env, keyRow);
      return handleData(env, decodeURIComponent(dataMatch[1]), url.searchParams, keyRow);
    }

    return problem(404, "not found", "GET /api/catalog · /api/data/<table> · /api/me, POST /api/keys");
  },
};
