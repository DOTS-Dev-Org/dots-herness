/** Translate Postgres-oriented SQL to SQLite/D1 when PG is not configured. */
function adaptSqlForD1(sql: string): string {
  let out = sql.replace(/\bNOW\(\)/gi, "CURRENT_TIMESTAMP");
  out = out.replace(
    /CURRENT_TIMESTAMP\s*-\s*make_interval\(\s*days\s*=>\s*\?\s*\)/gi,
    "datetime(CURRENT_TIMESTAMP, '-' || CAST(? AS TEXT) || ' days')"
  );
  out = out.replace(/\bcurrent_session\s*=\s*true\b/gi, "current_session = 1");
  out = out.replace(/\bcurrent_session\s*=\s*false\b/gi, "current_session = 0");
  out = out.replace(/,\s*true\s*,/gi, ", 1,");
  out = out.replace(/,\s*true\s*\)/gi, ", 1)");
  return out;
}

const SLOW_QUERY_MS = 100;

function logSlowQuery(sql: string, startedAt: number) {
  const ms = Date.now() - startedAt;
  if (ms >= SLOW_QUERY_MS) {
    const preview = sql.replace(/\s+/g, " ").trim().slice(0, 120);
    console.warn(`[d1:slow] ${ms}ms ${preview}`);
  }
}

/** Wrapper statement'ı native D1 statement'a geri çözmek için (batch bunu ister). */
const NATIVE_STMT = Symbol("nativeD1Stmt");

function wrapStatement(stmt: D1PreparedStatement, sql: string): D1PreparedStatement {
  const wrap = <T>(fn: () => Promise<T>): Promise<T> => {
    const started = Date.now();
    return fn().finally(() => logSlowQuery(sql, started));
  };

  return {
    [NATIVE_STMT]: stmt,
    bind: (...values: unknown[]) => wrapStatement(stmt.bind(...values), sql),
    first: <T = Record<string, unknown>>() => wrap(() => stmt.first<T>()),
    all: <T = Record<string, unknown>>() => wrap(() => stmt.all<T>()),
    run: () => wrap(() => stmt.run()),
    raw: stmt.raw?.bind(stmt),
  } as unknown as D1PreparedStatement;
}

function unwrapStatement(stmt: D1PreparedStatement): D1PreparedStatement {
  return (stmt as any)[NATIVE_STMT] ?? stmt;
}

export function wrapD1(d1: D1Database): D1Database {
  const wrapped = {
    prepare(sql: string) {
      const adapted = adaptSqlForD1(sql);
      return wrapStatement(d1.prepare(adapted), adapted);
    },
    // Wrapper objeleri native batch'e verilirse D1_ERROR: Malformed input — önce unwrap.
    batch: (stmts: D1PreparedStatement[]) => d1.batch(stmts.map(unwrapStatement)),
    exec: d1.exec.bind(d1),
    withSession: d1.withSession?.bind(d1),
    dump: d1.dump?.bind(d1),
  };
  return wrapped as D1Database;
}
