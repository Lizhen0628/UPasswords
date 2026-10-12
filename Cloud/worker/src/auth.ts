// 账户层:邮箱验证码(注册=登录)、会话、注销、敏感操作码。
// 响应恒定防枚举;验证码单活跃、限次、限速;会话令牌只存 SHA-256。

import { audit } from "./db";
import { sendVerificationMail } from "./smtp";
import {
  ApiError,
  codeHash,
  deleteR2Prefix,
  emailHmac,
  json,
  kekHmac,
  kekSeal,
  normalizeEmail,
  nowSec,
  numVar,
  randomHex,
  randomCode6,
  readJson,
  sha256Hex,
  timingSafeEqual,
  utf8,
  type Env,
} from "./util";

export interface UserRow {
  id: string;
  email_hmac: string;
  email_enc: string | null;
  state: string;
  plan: string;
  created_at: number;
  last_login_at: number | null;
}

export interface AuthContext {
  user: UserRow;
  sessionId: string;
}

function sanitizeDeviceName(input: unknown): string {
  if (typeof input !== "string") return "";
  return input.replace(/[\u0000-\u001f]/g, "").trim().slice(0, 64);
}

/// SMTP mock 模式下验证码由确定性派生(测试可复算;生产 SMTP_MOCK 未设,走随机)。
export async function deriveMockCode(env: Env, email: string, purpose: string): Promise<string> {
  const eh = await emailHmac(env, email);
  const mac = await kekHmac(env, `mock-code:${eh}:${purpose}`);
  return String(parseInt(mac.slice(0, 8), 16) % 1_000_000).padStart(6, "0");
}

// ---------- 验证码 ----------

export async function handleCodeRequest(
  env: Env,
  request: Request,
  ip: string,
): Promise<Response> {
  const body = await readJson(request);
  const email = normalizeEmail(body.email);
  if (!email) throw new ApiError(400, "invalid_email");
  const purpose = body.purpose === "sensitive" ? "sensitive" : "login";

  const now = nowSec();
  const cooldown = numVar(env, "CODE_RESEND_COOLDOWN_SECONDS", 60);
  const hourlyEmail = numVar(env, "CODE_HOURLY_PER_EMAIL", 10);
  const hourlyIp = numVar(env, "CODE_HOURLY_PER_IP", 20);
  const ttl = numVar(env, "CODE_TTL_SECONDS", 600);
  const eh = await emailHmac(env, email);

  // 重发冷却
  const last = await env.DB.prepare(
    "SELECT created_at FROM email_codes WHERE email_hmac = ? AND purpose = ? ORDER BY created_at DESC LIMIT 1",
  )
    .bind(eh, purpose)
    .first<{ created_at: number }>();
  if (last && now - last.created_at < cooldown) {
    throw new ApiError(429, "rate_limited", Math.ceil(cooldown - (now - last.created_at)));
  }
  // 每邮箱小时限额
  const perEmail = await env.DB.prepare(
    "SELECT COUNT(*) AS c FROM email_codes WHERE email_hmac = ? AND created_at > ?",
  )
    .bind(eh, now - 3600)
    .first<{ c: number }>();
  if ((perEmail?.c ?? 0) >= hourlyEmail) throw new ApiError(429, "rate_limited", 3600);
  // 每 IP 小时限额
  const perIp = await env.DB.prepare(
    "SELECT COUNT(*) AS c FROM email_codes WHERE ip = ? AND created_at > ?",
  )
    .bind(ip, now - 3600)
    .first<{ c: number }>();
  if ((perIp?.c ?? 0) >= hourlyIp) throw new ApiError(429, "rate_limited", 3600);

  // 单活跃码:新码即作废全部未用旧码(爆破上限=限速内码数×限次,对 6 位不可行)
  await env.DB.prepare(
    "UPDATE email_codes SET used_at = ? WHERE email_hmac = ? AND purpose = ? AND used_at IS NULL",
  )
    .bind(now, eh, purpose)
    .run();
  // 顺手清理过期一小时以上的历史码
  await env.DB.prepare("DELETE FROM email_codes WHERE expires_at < ?")
    .bind(now - 3600)
    .run();

  const code = env.SMTP_MOCK === "1" ? await deriveMockCode(env, email, purpose) : randomCode6();
  await env.DB.prepare(
    "INSERT INTO email_codes (email_hmac, code_hash, purpose, expires_at, attempts, used_at, created_at, ip) VALUES (?, ?, ?, ?, 0, NULL, ?, ?)",
  )
    .bind(eh, await codeHash(env, eh, code, purpose), purpose, now + ttl, now, ip)
    .run();

  // 发码尽力而为:失败不改变响应(响应恒定防枚举),靠监控发现
  try {
    await sendVerificationMail(env, email, code, purpose);
  } catch (error) {
    console.log(JSON.stringify({ t: Date.now(), action: "smtp_failed", reason: String(error).slice(0, 120) }));
  }
  await audit(env.DB, "code_send", {}, { purpose });
  return json({ ok: true }, 202);
}

/// 校验并消费一条验证码;返回是否匹配。
/// 尝试配额采用「原子领取」:并发爆破请求中每次 UPDATE 只有一个能推进
/// 计数(check-then-act 竞态曾把 5 次/码的上限放大到整批并发全有效)。
async function consumeCode(env: Env, eh: string, purpose: string, code: unknown): Promise<boolean> {
  if (typeof code !== "string" || !/^\d{6}$/.test(code)) return false;
  const now = nowSec();
  const row = await env.DB.prepare(
    "SELECT id, code_hash, attempts FROM email_codes WHERE email_hmac = ? AND purpose = ? AND used_at IS NULL AND expires_at > ? ORDER BY created_at DESC LIMIT 1",
  )
    .bind(eh, purpose, now)
    .first<{ id: number; code_hash: string; attempts: number }>();
  if (!row) return false;
  const maxAttempts = numVar(env, "CODE_MAX_ATTEMPTS", 5);
  // 先原子领取一次尝试名额:领不到(已达上限/已被并发领完)直接作废该码
  const claim = await env.DB.prepare(
    "UPDATE email_codes SET attempts = attempts + 1 WHERE id = ? AND used_at IS NULL AND attempts < ?",
  )
    .bind(row.id, maxAttempts)
    .run();
  if (!claim.meta.changes) {
    await env.DB.prepare("UPDATE email_codes SET used_at = ? WHERE id = ?").bind(now, row.id).run();
    return false;
  }
  const expected = await codeHash(env, eh, code, purpose);
  if (!timingSafeEqual(expected, row.code_hash)) return false;
  await env.DB.prepare("UPDATE email_codes SET used_at = ? WHERE id = ?").bind(now, row.id).run();
  return true;
}

/** 敏感操作码校验(删库/注销复用);失败统一 403,不泄露具体原因。 */
export async function requireSensitiveCode(env: Env, user: UserRow, code: unknown): Promise<void> {
  const ok = await consumeCode(env, user.email_hmac, "sensitive", code);
  if (!ok) throw new ApiError(403, "invalid_code");
}

/** 按邮箱 HMAC 校验并消费验证码(换绑邮箱:码发往新邮箱而非会话账户)。 */
export async function consumeCodeForEmail(env: Env, email: string, purpose: string, code: unknown): Promise<boolean> {
  const eh = await emailHmac(env, email);
  return consumeCode(env, eh, purpose, code);
}

/** 签发会话(登录与换绑共用):令牌只在返回值出现一次,库中仅存 SHA-256。 */
export async function issueSession(env: Env, userId: string, deviceName: unknown): Promise<{ token: string; expiresAt: number }> {
  const token = randomHex(32);
  const now = nowSec();
  const ttlDays = numVar(env, "SESSION_TTL_DAYS", 90);
  const expiresAt = now + ttlDays * 86400;
  await env.DB.prepare(
    "INSERT INTO sessions (id, user_id, token_hash, device_name, created_at, last_seen_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
  )
    .bind(randomHex(16), userId, await sha256Hex(token), sanitizeDeviceName(deviceName), now, now, expiresAt)
    .run();
  return { token, expiresAt };
}

/** 查目标账户:注销态先物理清除再重建,不存在则注册(登录与换绑共用)。 */
export async function getOrCreateUser(env: Env, email: string, eh: string, via?: "transfer"): Promise<UserRow> {
  const now = nowSec();
  let user = await env.DB.prepare("SELECT * FROM users WHERE email_hmac = ?")
    .bind(eh)
    .first<UserRow>();
  if (user && user.state === "deregistered") {
    // 注销后重新注册:清干净旧数据,以全新身份开始
    await purgeUser(env, user.id, eh);
    user = null;
  }
  if (!user) {
    const id = randomHex(16);
    const emailEnc = await kekSeal(env, utf8(email));
    await env.DB.prepare(
      "INSERT INTO users (id, email_hmac, email_enc, state, plan, created_at, last_login_at) VALUES (?, ?, ?, 'active', 'normal', ?, ?)",
    )
      .bind(id, eh, emailEnc, now, now)
      .run();
    user = { id, email_hmac: eh, email_enc: emailEnc, state: "active", plan: "normal", created_at: now, last_login_at: now };
    await audit(env.DB, "register", { userId: id }, via ? { via } : undefined);
  }
  return user;
}

// ---------- 注册/登录(统一) ----------

export async function handleVerify(env: Env, request: Request): Promise<Response> {
  const body = await readJson(request);
  const email = normalizeEmail(body.email);
  if (!email) throw new ApiError(400, "invalid_email");
  const eh = await emailHmac(env, email);

  if (!(await consumeCode(env, eh, "login", body.code))) throw new ApiError(400, "invalid_code");

  const user = await getOrCreateUser(env, email, eh);
  // 存量账户刷新登录时间(新建账户 INSERT 时已带同值,多跑一条 UPDATE 幂等)
  await env.DB.prepare("UPDATE users SET last_login_at = ? WHERE id = ?")
    .bind(nowSec(), user.id)
    .run();

  // 签发会话:令牌只在此响应出现一次,库中仅存 SHA-256
  const session = await issueSession(env, user.id, body.deviceName);
  await audit(env.DB, "login", { userId: user.id }, { expiresAt: session.expiresAt });
  return json({ token: session.token, expiresAt: session.expiresAt, userId: user.id, createdAt: user.created_at });
}

// ---------- 会话 ----------

export async function handleSessionList(env: Env, auth: AuthContext): Promise<Response> {
  const rows = await env.DB.prepare(
    "SELECT id, device_name, created_at, last_seen_at, expires_at FROM sessions WHERE user_id = ? AND revoked_at IS NULL ORDER BY last_seen_at DESC",
  )
    .bind(auth.user.id)
    .all<{ id: string; device_name: string; created_at: number; last_seen_at: number; expires_at: number }>();
  return json({
    sessions: (rows.results ?? []).map((r) => ({
      id: r.id,
      deviceName: r.device_name,
      createdAt: r.created_at,
      lastSeenAt: r.last_seen_at,
      expiresAt: r.expires_at,
    })),
  });
}

/// 会话自命名:调用方会话刷新自己的设备名。客户端解锁后即调用——
/// 历史会话的通用名(如未改名的 "iPhone")无需重新登录即可自愈为
/// 型号+设备名;只能改自己(鉴权即身份),改他人会话不可达。
export async function handleSessionRename(env: Env, request: Request, auth: AuthContext): Promise<Response> {
  const body = await readJson(request);
  const name = sanitizeDeviceName(body.deviceName);
  if (!name) throw new ApiError(400, "invalid_name");
  await env.DB.prepare("UPDATE sessions SET device_name = ? WHERE id = ? AND revoked_at IS NULL")
    .bind(name, auth.sessionId)
    .run();
  return json({ ok: true });
}

export async function handleSessionRevoke(env: Env, auth: AuthContext, sessionId: string): Promise<Response> {
  if (!/^[0-9a-f]{32}$/.test(sessionId)) throw new ApiError(404, "not_found");
  const result = await env.DB.prepare(
    "UPDATE sessions SET revoked_at = ? WHERE user_id = ? AND id = ? AND revoked_at IS NULL",
  )
    .bind(nowSec(), auth.user.id, sessionId)
    .run();
  if (!result.meta.changes) throw new ApiError(404, "not_found");
  await audit(env.DB, "session_revoke", { userId: auth.user.id }, { sessionId: sessionId.slice(0, 8) });
  return json({ ok: true });
}

// ---------- 注销 ----------

export async function handleDeregister(env: Env, request: Request, auth: AuthContext): Promise<Response> {
  const body = await readJson(request);
  await requireSensitiveCode(env, auth.user, body.code);
  const now = nowSec();
  // 立即清空敏感数据(信封/邮箱)并吊销全部会话;状态行仅留统计用途
  await env.DB.prepare(
    "UPDATE users SET state = 'deregistered', email_enc = NULL, deregistered_at = ? WHERE id = ?",
  )
    .bind(now, auth.user.id)
    .run();
  await env.DB.prepare("DELETE FROM vaults WHERE user_id = ?").bind(auth.user.id).run();
  await env.DB.prepare(
    "UPDATE sessions SET revoked_at = ? WHERE user_id = ? AND revoked_at IS NULL",
  )
    .bind(now, auth.user.id)
    .run();
  await audit(env.DB, "account_deregister", { userId: auth.user.id });
  return json({ ok: true });
}

/// 物理清除单个用户的全部行(注销重注册立即路径,与 cron 30 天路径共用)。
export async function purgeUser(env: Env, userId: string, eh: string): Promise<void> {
  // R2 库体按库清掉,再删注册表行(防孤儿密文残留)
  const vaults = await env.DB.prepare("SELECT vault_id FROM vaults WHERE user_id = ?")
    .bind(userId)
    .all<{ vault_id: string }>();
  for (const row of vaults.results ?? []) {
    await env.VAULTS.delete(`vaults/${row.vault_id}`);
    await deleteR2Prefix(env.VAULTS, `vaults/staging/${row.vault_id}/`);
  }
  await env.DB.prepare("DELETE FROM vaults WHERE user_id = ?").bind(userId).run();
  await env.DB.prepare("DELETE FROM sessions WHERE user_id = ?").bind(userId).run();
  await env.DB.prepare("DELETE FROM users WHERE id = ?").bind(userId).run();
  await env.DB.prepare("DELETE FROM email_codes WHERE email_hmac = ?").bind(eh).run();
}

/// cron:清除注销超过保留期(默认 30 天)的用户残行。
export async function purgeDeregistered(env: Env): Promise<void> {
  const days = numVar(env, "DEREGISTER_PURGE_DAYS", 30);
  const cutoff = nowSec() - days * 86400;
  const rows = await env.DB.prepare(
    "SELECT id, email_hmac FROM users WHERE state = 'deregistered' AND deregistered_at < ?",
  )
    .bind(cutoff)
    .all<{ id: string; email_hmac: string }>();
  for (const row of rows.results ?? []) {
    await purgeUser(env, row.id, row.email_hmac);
  }
  console.log(
    JSON.stringify({ t: Date.now(), action: "cron_purge", count: (rows.results ?? []).length }),
  );
}
