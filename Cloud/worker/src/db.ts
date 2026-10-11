// D1 访问辅助 + 审计日志。所有 SQL 一律参数化绑定,禁止拼接。

import type { Env } from "./util";

export interface AuditIds {
  userId?: string;
  vaultId?: string;
}

/// 审计:只记动作、ID、rev/尺寸/结果等非敏感细节;绝不记邮箱/令牌/验证码/信封。
export async function audit(
  db: D1Database,
  action: string,
  ids: AuditIds = {},
  detail: Record<string, unknown> = {},
): Promise<void> {
  try {
    await db
      .prepare("INSERT INTO audit_log (user_id, vault_id, action, detail, ts) VALUES (?, ?, ?, ?, ?)")
      .bind(ids.userId ?? null, ids.vaultId ?? null, action, JSON.stringify(detail), Date.now() / 1000)
      .run();
  } catch (error) {
    // 审计失败不阻断主流程,但必须留痕
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

export type DbEnv = Env;
