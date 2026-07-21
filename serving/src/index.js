/**
 * citydata 골드 서빙 API — Workers + D1 (프로토타입).
 *
 * GET /            엔드포인트 안내
 * GET /catalog     서빙 카탈로그 — Agent 진입점 (설명·tier·테스트게이트·컬럼)
 * GET /data/:table 조회. 쿼리 파라미터:
 *   - <컬럼명>=<값>   등호 필터 (카탈로그의 컬럼만 허용 — 화이트리스트)
 *   - from / to      시간축(time_axis) 범위 필터
 *   - limit          기본 500, 최대 5000
 *
 * 원칙: 스냅샷 조회 전용(쓰기 없음), 요청 로그는 D1 한 줄 append (7/16 회의).
 */

const json = (data, status = 200) =>
  new Response(JSON.stringify(data, null, 1), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });

const problem = (status, title, detail) =>
  new Response(JSON.stringify({ type: "about:blank", title, status, detail }), {
    status,
    headers: { "content-type": "application/problem+json; charset=utf-8" },
  });

async function catalogRows(env) {
  const { results } = await env.DB.prepare(
    "SELECT name, description, serving_tier, tests, time_axis, columns, row_count, exported_at FROM _catalog ORDER BY name"
  ).all();
  return results.map((r) => ({ ...r, tests: JSON.parse(r.tests), columns: JSON.parse(r.columns) }));
}

async function handleData(env, table, params) {
  const meta = await env.DB.prepare("SELECT * FROM _catalog WHERE name = ?").bind(table).first();
  if (!meta) return problem(404, "unknown table", `'${table}' 은 서빙 카탈로그에 없다 — GET /catalog 참조`);

  const columns = JSON.parse(meta.columns);
  const colSet = new Set(columns.map((c) => c.name));
  const where = [];
  const binds = [];

  for (const [k, v] of params.entries()) {
    if (k === "limit" || k === "from" || k === "to") continue;
    if (!colSet.has(k)) return problem(400, "unknown filter", `'${k}' 컬럼 없음 — 사용 가능: ${[...colSet].join(", ")}`);
    where.push(`"${k}" = ?`);
    binds.push(v);
  }
  if (params.get("from") || params.get("to")) {
    if (!meta.time_axis) return problem(400, "no time axis", `'${table}' 은 시간축이 없어 from/to 를 지원하지 않는다`);
    if (params.get("from")) { where.push(`"${meta.time_axis}" >= ?`); binds.push(params.get("from")); }
    if (params.get("to"))   { where.push(`"${meta.time_axis}" <= ?`); binds.push(params.get("to")); }
  }

  const limit = Math.min(parseInt(params.get("limit") || "500", 10) || 500, 5000);
  const sql = `SELECT * FROM "${table}"${where.length ? " WHERE " + where.join(" AND ") : ""} LIMIT ${limit}`;
  const { results } = await env.DB.prepare(sql).bind(...binds).all();
  return json({ table, row_count: results.length, limit, time_axis: meta.time_axis, rows: results });
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (request.method !== "GET") return problem(405, "method not allowed", "조회 전용 API");

    // 요청 로그 — 응답을 막지 않게 waitUntil 로 (실패는 무시: 로그는 부가기능)
    ctx.waitUntil(
      env.DB.prepare("INSERT INTO _request_log (ts, path, query) VALUES (?, ?, ?)")
        .bind(new Date().toISOString(), url.pathname, url.search)
        .run()
        .catch(() => {})
    );

    try {
      if (url.pathname === "/") {
        return json({
          service: "ask-seoul citydata gold API (prototype)",
          endpoints: ["/catalog", "/data/{table}?<col>=<val>&from=&to=&limit="],
          note: "소비자는 Agent — /catalog 의 description 을 읽고 테이블을 고른다",
        });
      }
      if (url.pathname === "/catalog") return json({ tables: await catalogRows(env) });
      const m = url.pathname.match(/^\/data\/([a-z0-9_]+)$/);
      if (m) return handleData(env, m[1], url.searchParams);
      return problem(404, "not found", "GET / 에서 엔드포인트 목록 확인");
    } catch (e) {
      return problem(500, "internal error", String(e).slice(0, 200));
    }
  },
};
