// 只读统计(管理面):按状态分组的用户计数与活动量。
// 无任何写操作、无密文访问、无邮箱展示——统计值不构成隐私泄露面。

import {
  ApiError,
  json,
  nowSec,
  timingSafeEqual,
  type Env,
} from "./util";

export async function handleStats(env: Env, request: Request): Promise<Response> {
  // 先过一次异步边界再抛错:规避测试 harness 对同步抛出的 unhandled 误报
  await Promise.resolve();
  const token = request.headers.get("x-admin-token") ?? "";
  // 空令牌必须短路:timingSafeEqual("", "") 是相等比较,忘配 ADMIN_TOKEN
  // 且请求不带头的组合曾把统计端点放行给任何人
  if (!env.ADMIN_TOKEN || !token) throw new ApiError(401, "unauthorized");
  if (!timingSafeEqual(token, env.ADMIN_TOKEN)) throw new ApiError(401, "unauthorized");

  const now = nowSec();
  const userRows = await env.DB.prepare(
    "SELECT state, plan, COUNT(*) AS c FROM users GROUP BY state, plan",
  ).all<{ state: string; plan: string; c: number }>();
  const active: Record<string, number> = { normal: 0, subscription: 0, permanent: 0 };
  let deregistered = 0;
  for (const row of userRows.results ?? []) {
    if (row.state === "deregistered") deregistered += row.c;
    else if (row.plan in active) active[row.plan] += row.c;
  }

  const vaultTotal = await env.DB.prepare("SELECT COUNT(*) AS c FROM vaults").first<{ c: number }>();
  const vaultActive = await env.DB.prepare(
    "SELECT COUNT(*) AS c FROM vaults WHERE updated_at > ?",
  )
    .bind(now - 365 * 86400)
    .first<{ c: number }>();
  const sessions = await env.DB.prepare(
    "SELECT COUNT(*) AS c FROM sessions WHERE revoked_at IS NULL AND expires_at > ?",
  )
    .bind(now)
    .first<{ c: number }>();
  const codes = await env.DB.prepare(
    "SELECT COUNT(*) AS c FROM email_codes WHERE created_at > ?",
  )
    .bind(now - 86400)
    .first<{ c: number }>();
  const envelopePuts = await env.DB.prepare(
    "SELECT COUNT(*) AS c FROM audit_log WHERE action = 'envelope_put' AND ts > ?",
  )
    .bind(now - 86400)
    .first<{ c: number }>();

  return json({
    users: { active, deregistered },
    vaults: { total: vaultTotal?.c ?? 0, active365d: vaultActive?.c ?? 0 },
    sessions: { active: sessions?.c ?? 0 },
    activity: { codes24h: codes?.c ?? 0, envelopePuts24h: envelopePuts?.c ?? 0 },
  });
}
