// MariaDB 访问层(Hyperdrive/mysql2)+ 审计日志。所有 SQL 一律参数化,禁止拼接。
// 连接来源:生产 env.DB(Hyperdrive connectionString);测试/本地 env.DATABASE_URL
// 直连(可选 DATABASE_SSL=1 启用 TLS,自签证书不校验)。
//
// workerd 红线:I/O 对象(socket)不得跨请求复用——连接池必须按请求创建/销毁
// (真正的连接复用由 Hyperdrive 在运行时层完成,每请求建 mysql2 池开销极低)。
// 池生命周期经 AsyncLocalStorage 作用域管理,由 index.ts 的 fetch/scheduled
// 入口统一包裹并在 finally 中 end。

import { AsyncLocalStorage } from "node:async_hooks";
import { createPool, type Pool, type PoolConnection, type ResultSetHeader } from "mysql2/promise";
import type { Env } from "./util";

export interface AuditIds {
  userId?: string;
  vaultId?: string;
}

interface RequestDbScope {
  pool: Pool | null;
}

const requestScope = new AsyncLocalStorage<RequestDbScope>();

export function dbPool(env: Env): Pool {
  const url = env.DB?.connectionString ?? env.DATABASE_URL;
  if (!url) throw new Error("no database connection (DB binding / DATABASE_URL)");
  const scope = requestScope.getStore();
  if (scope?.pool) return scope.pool;
  const pool = createPool({
    uri: url,
    waitForConnections: true,
    connectionLimit: 4,
    multipleStatements: false,
    supportBigNumbers: true,
    // workerd 禁 eval/new Function:mysql2 默认的行解析器靠运行时代码
    // 生成,disableEval 切静态解析器(Hyperdrive 必需,否则 EvalError)
    disableEval: true,
    // Hyperdrive 已在入口终结 TLS;直连(测试/本地)按需启用
    ...(env.DATABASE_SSL === "1" ? { ssl: { rejectUnauthorized: false } } : {}),
  });
  if (scope) scope.pool = pool;
  return pool;
}

/// 请求级 DB 作用域:入口(fetch/scheduled)包裹业务,结束时关池。
/// 池创建是惰性的(首个查询才发生),未触库的请求零开销。
export async function runWithRequestDb<T>(fn: () => Promise<T>): Promise<T> {
  const scope: RequestDbScope = { pool: null };
  try {
    return await requestScope.run(scope, fn);
  } finally {
    // 关池失败不应吞掉业务结果
    await scope.pool?.end().catch(() => undefined);
  }
}

export async function q<T>(env: Env, sql: string, params: unknown[] = []): Promise<T[]> {
  const [rows] = await dbPool(env).query(sql, params);
  return rows as T[];
}

export async function q1<T>(env: Env, sql: string, params: unknown[] = []): Promise<T | null> {
  const rows = await q<T>(env, sql, params);
  return rows[0] ?? null;
}

export async function exec(env: Env, sql: string, params: unknown[] = []): Promise<ResultSetHeader> {
  const [result] = await dbPool(env).query(sql, params);
  return result as ResultSetHeader;
}

/// 事务:条目 CAS/配额/head_seq 维护、rekey 换入都必须单事务完成。
export async function tx<T>(env: Env, fn: (conn: PoolConnection) => Promise<T>): Promise<T> {
  const conn = await dbPool(env).getConnection();
  try {
    await conn.beginTransaction();
    const out = await fn(conn);
    await conn.commit();
    return out;
  } catch (error) {
    await conn.rollback();
    throw error;
  } finally {
    conn.release();
  }
}

export async function connQuery<T>(
  conn: PoolConnection,
  sql: string,
  params: unknown[] = [],
): Promise<T[]> {
  const [rows] = await conn.query(sql, params);
  return rows as T[];
}

export async function connExec(
  conn: PoolConnection,
  sql: string,
  params: unknown[] = [],
): Promise<ResultSetHeader> {
  const [result] = await conn.query(sql, params);
  return result as ResultSetHeader;
}

/// 审计:只记动作、ID、rev/尺寸/结果等非敏感细节;绝不记邮箱/令牌/验证码/
/// 信封/条目密文/查询前缀。失败不阻断主流程,但必须留痕。
export async function audit(
  env: Env,
  action: string,
  ids: AuditIds = {},
  detail: Record<string, unknown> = {},
): Promise<void> {
  try {
    await exec(
      env,
      "INSERT INTO audit_log (user_id, vault_id, action, detail, ts_ms) VALUES (?, ?, ?, ?, ?)",
      [ids.userId ?? null, ids.vaultId ?? null, action, JSON.stringify(detail), Date.now()],
    );
  } catch (error) {
    console.log(JSON.stringify({ t: Date.now(), action: "audit_failed", reason: String(error) }));
  }
}

/// 结构化请求日志:方法/路径/状态/耗时/(已认证时)用户 ID 前缀,不含任何请求体。
export function logRequest(
  method: string,
  path: string,
  status: number,
  startedAt: number,
  userId?: string,
): void {
  console.log(
    JSON.stringify({
      t: Date.now(),
      m: method,
      p: path,
      s: status,
      ms: Date.now() - startedAt,
      u: userId ? userId.slice(0, 8) : null,
    }),
  );
}
