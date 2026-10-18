// 只读统计(X-Admin-Token):按状态/套餐计数、活跃库、会话、24h 验证码与
// 条目写入量、目录规模。无任何写操作与解密能力——统计值不构成隐私泄露面。

import { q1 } from "./db";
import { requireAdmin } from "./sites";
import { json, nowMs, type Env } from "./util";

export async function handleStats(env: Env, request: Request): Promise<Response> {
  // 先过一次异步边界再抛错:规避测试 harness 对同步抛出的 unhandled 误报
  await Promise.resolve();
  requireAdmin(env, request);
  const dayMs = 86_400_000;
  const now = nowMs();

  const users = await q1<{ active: number; deregistered: number }>(
    env,
    "SELECT SUM(state = 'active') AS active, SUM(state = 'deregistered') AS deregistered FROM users",
  );
  const plans = await q1<{ normal: number; subscription: number; permanent: number }>(
    env,
    "SELECT SUM(plan = 'normal') AS normal, SUM(plan = 'subscription') AS subscription, SUM(plan = 'permanent') AS permanent FROM users WHERE state = 'active'",
  );
  const vaults = await q1<{ total: number; active365d: number; items: number; attachBytes: number }>(
    env,
    `SELECT COUNT(*) AS total, SUM(updated_ms > ?) AS active365d,
       (SELECT COALESCE(SUM(item_count), 0) FROM vaults v2) AS items,
       (SELECT COALESCE(SUM(attach_bytes), 0) FROM vaults v3) AS attachBytes
     FROM vaults`,
    [now - 365 * dayMs],
  );
  const sessions = await q1<{ c: number }>(
    env,
    "SELECT COUNT(*) AS c FROM sessions WHERE revoked_ms IS NULL AND expires_ms > ?",
    [now],
  );
  const codes24h = await q1<{ c: number }>(
    env,
    "SELECT COUNT(*) AS c FROM email_codes WHERE created_ms > ?",
    [now - dayMs],
  );
  const changes24h = await q1<{ c: number }>(
    env,
    "SELECT COUNT(*) AS c FROM item_changes WHERE created_ms > ?",
    [now - dayMs],
  );
  const sites = await q1<{ c: number }>(
    env,
    "SELECT COUNT(*) AS c FROM websites WHERE status = 1",
  );

  return json({
    users: {
      active: Number(users?.active ?? 0),
      deregistered: Number(users?.deregistered ?? 0),
      plans: {
        normal: Number(plans?.normal ?? 0),
        subscription: Number(plans?.subscription ?? 0),
        permanent: Number(plans?.permanent ?? 0),
      },
    },
    vaults: {
      total: Number(vaults?.total ?? 0),
      active365d: Number(vaults?.active365d ?? 0),
      items: Number(vaults?.items ?? 0),
      attachBytes: Number(vaults?.attachBytes ?? 0),
    },
    sessions: Number(sessions?.c ?? 0),
    codes24h: Number(codes24h?.c ?? 0),
    itemChanges24h: Number(changes24h?.c ?? 0),
    sites: Number(sites?.c ?? 0),
  });
}
