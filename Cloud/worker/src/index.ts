// 入口:/v1 路由(兼容 /v2)、Bearer 会话鉴权、能力协商、统一错误/日志、cron 维护。
// 日志只含方法/路径/状态/耗时/用户 ID 前缀,不含任何请求体与凭据。

import {
  handleCodeRequest,
  handleDeregister,
  handleSessionList,
  handleSessionRename,
  handleSessionRevoke,
  handleSessionSelfRevoke,
  handleVerify,
  type AuthContext,
  type UserRow,
} from "./auth";
import { exec, logRequest, q1, runWithRequestDb } from "./db";
import {
  handleAttachmentCommit,
  handleAttachmentDelete,
  handleAttachmentGet,
  handleAttachmentPut,
} from "./attachments";
import { handleBreachRange } from "./breach";
import { runMaintenance } from "./maintenance";
import { handleRekeyAbort, handleRekeyBegin, handleRekeyChunk, handleRekeyCommit } from "./rekey";
import { handleAdminSitesPut, handleSiteIcon, handleSiteLookup } from "./sites";
import { handleStats } from "./stats";
import { ApiError, json, nowMs, numVar, sha256Hex, type Env } from "./util";
import {
  handleChangesGet,
  handleItemsList,
  handleItemsPost,
} from "./items";
import {
  handleCreateVault,
  handleDeleteVault,
  handleGetVault,
  handleListVaults,
  handleRenameVault,
  handleTransferVault,
  handleVaultSeq,
} from "./vaults";

interface RouteCtx {
  env: Env;
  request: Request;
  ip: string;
  uid?: string;
}

function capabilities(): Response {
  return json({
    name: "upasswords-sync",
    version: 2,
    capabilities: [
      "auth.email_code",
      "auth.sessions",
      "vaults.registry",
      "vaults.row_sync",
      "vaults.attachments",
      "vaults.rekey",
      "sites.catalog",
      "breach.range",
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
  const row = await q1<{
    session_id: string;
    expires_ms: number;
    revoked_ms: number | null;
    last_seen_ms: number | null;
    user_id: string;
    email_hmc: string;
    email_enc: string | null;
    state: string;
    plan: string;
    created_ms: number;
    last_login_ms: number | null;
  }>(
    ctx.env,
    "SELECT s.id AS session_id, s.expires_ms, s.revoked_ms, s.last_seen_ms, " +
      "u.id AS user_id, u.email_hmc, u.email_enc, u.state, u.plan, u.created_ms, u.last_login_ms " +
      "FROM sessions s JOIN users u ON u.id = s.user_id WHERE s.token_hash = ?",
    [await sha256Hex(token)],
  );
  // 吊销/过期/注销统一 401,不泄露具体原因
  if (!row || row.revoked_ms !== null || row.expires_ms <= nowMs() || row.state !== "active") {
    throw new ApiError(401, "unauthorized");
  }
  const now = nowMs();
  const ttlDays = numVar(ctx.env, "SESSION_TTL_DAYS", 90);
  // 滑动续期节流:每次请求都 UPDATE 会放大写量;距上次记录不足 1 小时
  // 跳过(会话有效期 90 天,1 小时的续期滞后无影响)
  if (now - (row.last_seen_ms ?? 0) >= 3_600_000) {
    await exec(ctx.env, "UPDATE sessions SET last_seen_ms = ?, expires_ms = ? WHERE id = ?", [
      now,
      now + ttlDays * 86_400_000,
      row.session_id,
    ]);
  }
  const user: UserRow = {
    id: row.user_id,
    email_hmc: row.email_hmc,
    email_enc: row.email_enc,
    state: row.state,
    plan: row.plan,
    created_ms: row.created_ms,
    last_login_ms: row.last_login_ms,
  };
  ctx.uid = user.id;
  return { user, sessionId: row.session_id };
}

async function route(ctx: RouteCtx): Promise<Response> {
  const segments = new URL(ctx.request.url).pathname.split("/").filter(Boolean);
  const method = ctx.request.method;
  const auth = () => authenticate(ctx);

  // Both route prefixes expose the same row-sync protocol during migration.
  if (segments.length === 0 || (segments.length === 1 && ["v1", "v2"].includes(segments[0]))) {
    if (method !== "GET") throw methodNotAllowed();
    return capabilities();
  }
  const rest = ["v1", "v2"].includes(segments[0]) ? segments.slice(1) : null;
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
      // PATCH=自命名;DELETE=自撤销(登出/重登收尾,鉴权即身份)
      if (method === "DELETE") return handleSessionSelfRevoke(ctx.env, await auth());
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
  if (rest[0] === "breach" && rest[1] === "range" && rest.length === 3) {
    if (method !== "GET") throw methodNotAllowed();
    const startedAt = Date.now();
    await auth();
    return handleBreachRange(ctx.env, rest[2], startedAt);
  }
  if (rest[0] === "sites") {
    if (rest[1] === "lookup" && rest.length === 2) {
      if (method !== "GET") throw methodNotAllowed();
      await auth();
      return handleSiteLookup(ctx.env, ctx.request);
    }
    if (rest[1] === "icon" && rest.length === 3) {
      if (method !== "GET") throw methodNotAllowed();
      await auth();
      return handleSiteIcon(ctx.env, rest[2]);
    }
    throw new ApiError(404, "not_found");
  }
  if (rest[0] === "admin") {
    if (rest[1] === "sites" && rest.length === 2) {
      if (method !== "POST") throw methodNotAllowed();
      return handleAdminSitesPut(ctx.env, ctx.request);
    }
    if (rest[1] === "stats" && rest.length === 2) {
      if (method !== "GET") throw methodNotAllowed();
      return handleStats(ctx.env, ctx.request);
    }
    throw new ApiError(404, "not_found");
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
    if (rest.length === 3 && rest[2] === "seq") {
      if (method !== "GET") throw methodNotAllowed();
      return handleVaultSeq(ctx.env, await auth(), vaultId);
    }
    if (rest.length === 3 && rest[2] === "items") {
      if (method === "POST") return handleItemsPost(ctx.env, ctx.request, await auth(), vaultId);
      if (method === "GET") return handleItemsList(ctx.env, ctx.request, await auth(), vaultId);
      throw methodNotAllowed();
    }
    if (rest.length === 3 && rest[2] === "changes") {
      if (method !== "GET") throw methodNotAllowed();
      return handleChangesGet(ctx.env, ctx.request, await auth(), vaultId);
    }
    if (rest.length === 3 && rest[2] === "transfer") {
      if (method !== "POST") throw methodNotAllowed();
      return handleTransferVault(ctx.env, ctx.request, await auth(), vaultId);
    }
    if (rest[2] === "attachments" && rest.length === 4) {
      const attachUuid = rest[3];
      if (method === "GET") return handleAttachmentGet(ctx.env, await auth(), vaultId, attachUuid);
      if (method === "DELETE") return handleAttachmentDelete(ctx.env, await auth(), vaultId, attachUuid);
      if (method === "PUT") {
        return handleAttachmentPut(
          ctx.env,
          ctx.request,
          await auth(),
          vaultId,
          attachUuid,
          new URL(ctx.request.url),
        );
      }
      throw methodNotAllowed();
    }
    if (rest[2] === "attachments" && rest.length === 5 && rest[4] === "commit") {
      if (method !== "POST") throw methodNotAllowed();
      return handleAttachmentCommit(ctx.env, ctx.request, await auth(), vaultId, rest[3]);
    }
    if (rest[2] === "rekey") {
      if (rest.length === 4 && rest[3] === "begin") {
        if (method !== "POST") throw methodNotAllowed();
        return handleRekeyBegin(ctx.env, ctx.request, await auth(), vaultId);
      }
      if (rest.length === 5 && rest[4] === "chunk") {
        if (method !== "POST") throw methodNotAllowed();
        return handleRekeyChunk(ctx.env, ctx.request, await auth(), vaultId, rest[3]);
      }
      if (rest.length === 5 && rest[4] === "commit") {
        if (method !== "POST") throw methodNotAllowed();
        return handleRekeyCommit(ctx.env, ctx.request, await auth(), vaultId, rest[3]);
      }
      if (rest.length === 4) {
        if (method !== "DELETE") throw methodNotAllowed();
        return handleRekeyAbort(ctx.env, await auth(), vaultId, rest[3]);
      }
      throw new ApiError(404, "not_found");
    }
    throw new ApiError(404, "not_found");
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
      const response = await runWithRequestDb(() => route(ctx));
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
    await runWithRequestDb(() => runMaintenance(env));
  },
} satisfies ExportedHandler<Env>;
