// 入口:路由、鉴权中间件、能力协商、统一错误/日志、cron 清理。
// 日志只含方法/路径/状态/耗时/用户 ID 前缀,不含任何请求体与凭据。

import {
  handleCodeRequest,
  handleDeregister,
  handleSessionList,
  handleSessionRename,
  handleSessionRevoke,
  handleVerify,
  purgeDeregistered,
  type AuthContext,
  type UserRow,
} from "./auth";
import { logRequest } from "./db";
import {
  handleBodyCommit,
  handleBodyGet,
  handleBodyPut,
  handleCreateVault,
  handleDeleteVault,
  handleEnvelopePut,
  handleGetVault,
  handleHashesPut,
  handleListVaults,
  handleRenameVault,
  handleTransferVault,
  sweepStaleStaging,
} from "./vaults";
import { handleStats } from "./stats";
import { ApiError, json, nowSec, numVar, sha256Hex, type Env } from "./util";

interface RouteCtx {
  env: Env;
  request: Request;
  ip: string;
  uid?: string;
}

function capabilities(): Response {
  return json({
    name: "upasswords-sync",
    version: 1,
    capabilities: [
      "auth.email_code",
      "auth.sessions",
      "vaults.registry",
      "vaults.envelope",
      "vaults.hashes",
      "vaults.body",
      "stats.readonly",
    ],
  });
}

function methodNotAllowed(): ApiError {
  return new ApiError(405, "method_not_allowed");
}

/// Bearer 会话鉴权:令牌 SHA-256 查表,校验吊销/过期/状态,滑动续期 90 天。
async function authenticate(ctx: RouteCtx): Promise<AuthContext> {
  const token = (ctx.request.headers.get("authorization") ?? "").replace(/^Bearer /i, "");
  if (!/^[0-9a-f]{64}$/.test(token)) throw new ApiError(401, "unauthorized");
  const row = await ctx.env.DB.prepare(
    "SELECT s.id AS session_id, s.expires_at, s.revoked_at, s.last_seen_at, " +
      "u.id AS user_id, u.email_hmac, u.email_enc, u.state, u.plan, u.created_at, u.last_login_at " +
      "FROM sessions s JOIN users u ON u.id = s.user_id WHERE s.token_hash = ?",
  )
    .bind(await sha256Hex(token))
    .first<{
      session_id: string;
      expires_at: number;
      revoked_at: number | null;
      last_seen_at: number | null;
      user_id: string;
      email_hmac: string;
      email_enc: string | null;
      state: string;
      plan: string;
      created_at: number;
      last_login_at: number | null;
    }>();
  // 吊销/过期/注销统一 401,不泄露具体原因
  if (!row || row.revoked_at !== null || row.expires_at <= nowSec() || row.state !== "active") {
    throw new ApiError(401, "unauthorized");
  }
  const now = nowSec();
  const ttlDays = numVar(ctx.env, "SESSION_TTL_DAYS", 90);
  // 滑动续期节流:每次请求都 UPDATE 会放大 D1 写量;距上次记录不足 1 小时
  // 跳过(会话有效期 90 天,1 小时的续期滞后无影响;过期校验仍按已加载行)
  if (now - (row.last_seen_at ?? 0) >= 3600) {
    await ctx.env.DB.prepare(
      "UPDATE sessions SET last_seen_at = ?, expires_at = ? WHERE id = ?",
    )
      .bind(now, now + ttlDays * 86400, row.session_id)
      .run();
  }
  const user: UserRow = {
    id: row.user_id,
    email_hmac: row.email_hmac,
    email_enc: row.email_enc,
    state: row.state,
    plan: row.plan,
    created_at: row.created_at,
    last_login_at: row.last_login_at,
  };
  ctx.uid = user.id;
  return { user, sessionId: row.session_id };
}

async function route(ctx: RouteCtx): Promise<Response> {
  const segments = new URL(ctx.request.url).pathname.split("/").filter(Boolean);
  const method = ctx.request.method;
  const auth = () => authenticate(ctx);

  // "/" 与 "/v1" → 能力协商
  if (segments.length === 0 || (segments.length === 1 && segments[0] === "v1")) {
    if (method !== "GET") throw methodNotAllowed();
    return capabilities();
  }
  const rest = segments[0] === "v1" ? segments.slice(1) : null;
  if (!rest) throw new ApiError(404, "not_found");

  if (rest[0] === "auth") {
    if (rest[1] === "code" && rest.length === 2) {
      if (method !== "POST") throw methodNotAllowed();
      return handleCodeRequest(ctx.env, ctx.request, ctx.ip);
    }
    if (rest[1] === "verify" && rest.length === 2) {
      if (method !== "POST") throw methodNotAllowed();
      return handleVerify(ctx.env, ctx.request);
    }
    if (rest[1] === "session" && rest.length === 2) {
      if (method !== "PATCH") throw methodNotAllowed();
      return handleSessionRename(ctx.env, ctx.request, await auth());
    }
    if (rest[1] === "sessions" && rest.length === 2) {
      if (method !== "GET") throw methodNotAllowed();
      return handleSessionList(ctx.env, await auth());
    }
    if (rest[1] === "sessions" && rest.length === 3) {
      if (method !== "DELETE") throw methodNotAllowed();
      return handleSessionRevoke(ctx.env, await auth(), rest[2]);
    }
    throw new ApiError(404, "not_found");
  }
  if (rest[0] === "account" && rest.length === 1) {
    if (method !== "DELETE") throw methodNotAllowed();
    return handleDeregister(ctx.env, ctx.request, await auth());
  }
  if (rest[0] === "vaults") {
    if (rest.length === 1) {
      if (method === "POST") return handleCreateVault(ctx.env, ctx.request, await auth());
      if (method === "GET") return handleListVaults(ctx.env, await auth());
      throw methodNotAllowed();
    }
    const vaultId = rest[1];
    if (!/^[0-9a-f]{32}$/.test(vaultId)) throw new ApiError(404, "not_found");
    if (rest.length === 2) {
      if (method === "GET") return handleGetVault(ctx.env, await auth(), vaultId);
      if (method === "PATCH") return handleRenameVault(ctx.env, ctx.request, await auth(), vaultId);
      if (method === "DELETE") return handleDeleteVault(ctx.env, ctx.request, await auth(), vaultId);
      throw methodNotAllowed();
    }
    if (rest.length === 3 && rest[2] === "envelope") {
      if (method !== "PUT") throw methodNotAllowed();
      return handleEnvelopePut(ctx.env, ctx.request, await auth(), vaultId);
    }
    if (rest.length === 3 && rest[2] === "hashes") {
      if (method !== "PUT") throw methodNotAllowed();
      return handleHashesPut(ctx.env, ctx.request, await auth(), vaultId);
    }
    if (rest.length === 3 && rest[2] === "transfer") {
      if (method !== "POST") throw methodNotAllowed();
      return handleTransferVault(ctx.env, ctx.request, await auth(), vaultId);
    }
    if (rest.length === 3 && rest[2] === "body") {
      if (method === "GET") return handleBodyGet(ctx.env, await auth(), vaultId);
      if (method === "PUT") {
        return handleBodyPut(
          ctx.env,
          ctx.request,
          await auth(),
          vaultId,
          new URL(ctx.request.url),
        );
      }
      throw methodNotAllowed();
    }
    if (rest.length === 4 && rest[2] === "body" && rest[3] === "commit") {
      if (method !== "POST") throw methodNotAllowed();
      return handleBodyCommit(ctx.env, ctx.request, await auth(), vaultId);
    }
    throw new ApiError(404, "not_found");
  }
  if (rest[0] === "admin" && rest[1] === "stats" && rest.length === 2) {
    if (method !== "GET") throw methodNotAllowed();
    return handleStats(ctx.env, ctx.request);
  }
  throw new ApiError(404, "not_found");
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const startedAt = Date.now();
    const ctx: RouteCtx = {
      env,
      request,
      ip: request.headers.get("cf-connecting-ip") ?? "",
    };
    let status = 500;
    try {
      const response = await route(ctx);
      status = response.status;
      return response;
    } catch (error) {
      if (error instanceof ApiError) {
        status = error.status;
        const extra =
          error.retryAfter !== undefined
            ? { "retry-after": String(Math.max(1, Math.ceil(error.retryAfter))) }
            : undefined;
        return json({ error: error.code }, error.status, extra);
      }
      status = 500;
      console.log(
        JSON.stringify({
          t: Date.now(),
          action: "internal_error",
          reason: String(error).slice(0, 200),
        }),
      );
      return json({ error: "internal" }, 500);
    } finally {
      logRequest(request.method, new URL(request.url).pathname, status, startedAt, ctx.uid);
    }
  },

  async scheduled(_controller: ScheduledController, env: Env): Promise<void> {
    await purgeDeregistered(env);
    await sweepStaleStaging(env);
  },
} satisfies ExportedHandler<Env>;
