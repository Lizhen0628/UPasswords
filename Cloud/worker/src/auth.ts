// 账户层:邮箱验证码(注册=登录)、会话、注销、敏感操作码。
// 响应恒定防枚举;验证码单活跃、限次、限速;会话令牌只存 SHA-256。

import { audit, exec, q, q1 } from "./db";
import { sendVerificationMail } from "./smtp";
import {
  ApiError,
  codeHash,
  deleteR2Prefix,
  scrubEmails,
  emailHmc,
  json,
  kekHmac,
  kekSeal,
  normalizeEmail,
  nowMs,
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
  email_hmc: string;
  email_enc: string | null;
  state: string;
  plan: string;
  created_ms: number;
  last_login_ms: number | null;
}

export interface AuthContext {
  user: UserRow;
  sessionId: string;
}

const PLATFORMS = new Set([
  "macos",
  "ios",
  "autofill",
  "ext-safari",
  "ext-chrome",
  "ext-edge",
  "ext-firefox",
  "other",
]);

/// 邮件语言:客户端上报(App 内语言优先、系统语言其次),仅认 zh*/en,
/// 缺省与未知值一律英文。
function normalizeLang(input: unknown): "zh" | "en" {
  return typeof input === "string" && input.toLowerCase().startsWith("zh") ? "zh" : "en";
}

function sanitizeDeviceName(input: unknown): string {
  if (typeof input !== "string") return "";
  return input.replace(/[\u0000-\u001f]/g, "").trim().slice(0, 64);
}

function sanitizePlatform(input: unknown): string {
  if (typeof input !== "string") return "other";
  return PLATFORMS.has(input) ? input : "other";
}

/// SMTP mock 模式下验证码由确定性派生(测试可复算;生产 SMTP_MOCK 未设,走随机)。
export async function deriveMockCode(env: Env, email: string, purpose: string): Promise<string> {
  const eh = await emailHmc(env, email);
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
  const lang = normalizeLang(body.lang);

  const now = nowMs();
  const cooldownMs = numVar(env, "CODE_RESEND_COOLDOWN_SECONDS", 60) * 1000;
  const hourlyEmail = numVar(env, "CODE_HOURLY_PER_EMAIL", 10);
  const hourlyIp = numVar(env, "CODE_HOURLY_PER_IP", 20);
  const ttlMs = numVar(env, "CODE_TTL_SECONDS", 600) * 1000;
  const eh = await emailHmc(env, email);

  // 重发冷却
  const last = await q1<{ created_ms: number }>(
    env,
    "SELECT created_ms FROM email_codes WHERE email_hmc = ? AND purpose = ?",
    [eh, purpose],
  );
  if (last && now - last.created_ms < cooldownMs) {
    throw new ApiError(429, "rate_limited", Math.ceil((cooldownMs - (now - last.created_ms)) / 1000));
  }
  // 每邮箱小时限额
  const perEmail = await q1<{ c: number }>(
    env,
    "SELECT COUNT(*) AS c FROM email_codes WHERE email_hmc = ? AND created_ms > ?",
    [eh, now - 3_600_000],
  );
  if ((perEmail?.c ?? 0) >= hourlyEmail) throw new ApiError(429, "rate_limited", 3600);
  // 每 IP 小时限额
  const perIp = await q1<{ c: number }>(
    env,
    "SELECT COUNT(*) AS c FROM email_codes WHERE ip = ? AND created_ms > ?",
    [ip, now - 3_600_000],
  );
  if ((perIp?.c ?? 0) >= hourlyIp) throw new ApiError(429, "rate_limited", 3600);

  // 顺手清理过期一小时以上的历史码
  await exec(env, "DELETE FROM email_codes WHERE expires_ms < ?", [now - 3_600_000]);

  const code = env.SMTP_MOCK === "1" ? await deriveMockCode(env, email, purpose) : randomCode6();
  // 单活跃码:同 (邮箱, purpose) 唯一行,新码整体覆盖旧码
  // (爆破上限=限速内码数×限次,对 6 位不可行)
  await exec(
    env,
    `INSERT INTO email_codes (email_hmc, purpose, code_hash, ip, expires_ms, attempts, used_ms, created_ms)
     VALUES (?, ?, ?, ?, ?, 0, NULL, ?)
     ON DUPLICATE KEY UPDATE code_hash = VALUES(code_hash), ip = VALUES(ip),
       expires_ms = VALUES(expires_ms), attempts = 0, used_ms = NULL, created_ms = VALUES(created_ms)`,
    [eh, purpose, await codeHash(env, eh, code, purpose), ip, now + ttlMs, now],
  );

  // 发码尽力而为:失败不改变响应(响应恒定防枚举),靠监控发现
  try {
    await sendVerificationMail(env, email, code, purpose, lang);
  } catch (error) {
    console.log(
      JSON.stringify({
        t: Date.now(),
        action: "smtp_failed",
        reason: scrubEmails(String(error)).slice(0, 120),
      }),
    );
  }
  await audit(env, "code_send", {}, { purpose });
  return json({ ok: true }, 202);
}

/// 校验并消费一条验证码;返回是否匹配。
/// 尝试配额采用「原子领取」:并发爆破请求中每次 UPDATE 只有一个能推进计数。
async function consumeCode(env: Env, eh: string, purpose: string, code: unknown): Promise<boolean> {
  if (typeof code !== "string" || !/^\d{6}$/.test(code)) return false;
  const now = nowMs();
  const row = await q1<{ code_hash: string; attempts: number }>(
    env,
    "SELECT code_hash, attempts FROM email_codes WHERE email_hmc = ? AND purpose = ? AND used_ms IS NULL AND expires_ms > ?",
    [eh, purpose, now],
  );
  if (!row) return false;
  const maxAttempts = numVar(env, "CODE_MAX_ATTEMPTS", 5);
  // 先原子领取一次尝试名额:领不到(已达上限/已被并发领完)直接作废该码
  const claim = await exec(
    env,
    "UPDATE email_codes SET attempts = attempts + 1 WHERE email_hmc = ? AND purpose = ? AND used_ms IS NULL AND attempts < ?",
    [eh, purpose, maxAttempts],
  );
  if (!claim.affectedRows) {
    await exec(env, "UPDATE email_codes SET used_ms = ? WHERE email_hmc = ? AND purpose = ?", [
      now,
      eh,
      purpose,
    ]);
    return false;
  }
  const expected = await codeHash(env, eh, code, purpose);
  if (!timingSafeEqual(expected, row.code_hash)) return false;
  // 条件置位保单次性:并发双请求持同一正确码时只有先落地的那个成功
  const spend = await exec(
    env,
    "UPDATE email_codes SET used_ms = ? WHERE email_hmc = ? AND purpose = ? AND used_ms IS NULL",
    [now, eh, purpose],
  );
  return spend.affectedRows === 1;
}

/** 敏感操作码校验(删库/注销复用);失败统一 403,不泄露具体原因。 */
export async function requireSensitiveCode(env: Env, user: UserRow, code: unknown): Promise<void> {
  const ok = await consumeCode(env, user.email_hmc, "sensitive", code);
  if (!ok) throw new ApiError(403, "invalid_code");
}

/** 按邮箱 HMAC 校验并消费验证码(换绑邮箱:码发往新邮箱而非会话账户)。 */
export async function consumeCodeForEmail(
  env: Env,
  email: string,
  purpose: string,
  code: unknown,
): Promise<boolean> {
  const eh = await emailHmc(env, email);
  return consumeCode(env, eh, purpose, code);
}

/** 签发会话(登录与换绑共用):令牌只在返回值出现一次,库中仅存 SHA-256。 */
export async function issueSession(
  env: Env,
  userId: string,
  deviceName: unknown,
  platform: unknown = "other",
): Promise<{ token: string; expiresAt: number }> {
  const token = randomHex(32);
  const now = nowMs();
  const ttlDays = numVar(env, "SESSION_TTL_DAYS", 90);
  const expiresAt = now + ttlDays * 86_400_000;
  await exec(
    env,
    "INSERT INTO sessions (id, user_id, token_hash, device_name, platform, created_ms, last_seen_ms, expires_ms) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
    [
      randomHex(16),
      userId,
      await sha256Hex(token),
      sanitizeDeviceName(deviceName),
      sanitizePlatform(platform),
      now,
      now,
      expiresAt,
    ],
  );
  return { token, expiresAt };
}

/** 查目标账户:注销态先物理清除再重建,不存在则注册(登录与换绑共用)。 */
export async function getOrCreateUser(
  env: Env,
  email: string,
  eh: string,
  via?: "transfer",
): Promise<UserRow> {
  const now = nowMs();
  let user = await q1<UserRow>(env, "SELECT * FROM users WHERE email_hmc = ?", [eh]);
  if (user && user.state === "deregistered") {
    // 注销后重新注册:清干净旧数据,以全新身份开始
    await purgeUser(env, user.id, eh);
    user = null;
  }
  if (!user) {
    const id = randomHex(16);
    const emailEnc = await kekSeal(env, utf8(email));
    await exec(
      env,
      "INSERT INTO users (id, email_hmc, email_enc, state, plan, created_ms, last_login_ms) VALUES (?, ?, ?, 'active', 'normal', ?, ?)",
      [id, eh, emailEnc, now, now],
    );
    user = {
      id,
      email_hmc: eh,
      email_enc: emailEnc,
      state: "active",
      plan: "normal",
      created_ms: now,
      last_login_ms: now,
    };
    await audit(env, "register", { userId: id }, via ? { via } : undefined);
  }
  return user;
}

// ---------- 注册/登录(统一) ----------

export async function handleVerify(env: Env, request: Request): Promise<Response> {
  const body = await readJson(request);
  const email = normalizeEmail(body.email);
  if (!email) throw new ApiError(400, "invalid_email");
  const eh = await emailHmc(env, email);

  if (!(await consumeCode(env, eh, "login", body.code))) throw new ApiError(400, "invalid_code");

  const user = await getOrCreateUser(env, email, eh);
  // 存量账户刷新登录时间(新建账户 INSERT 时已带同值,多跑一条 UPDATE 幂等)
  await exec(env, "UPDATE users SET last_login_ms = ? WHERE id = ?", [nowMs(), user.id]);

  // 签发会话:令牌只在此响应出现一次,库中仅存 SHA-256
  const session = await issueSession(env, user.id, body.deviceName, body.platform);
  await audit(env, "login", { userId: user.id }, { expiresAt: session.expiresAt });
  return json({
    token: session.token,
    expiresAt: session.expiresAt,
    userId: user.id,
    createdAt: user.created_ms,
  });
}

// ---------- 会话 ----------

interface SessionRow {
  id: string;
  device_name: string;
  platform: string;
  created_ms: number;
  last_seen_ms: number;
  expires_ms: number;
}

export async function handleSessionList(env: Env, auth: AuthContext): Promise<Response> {
  const rows = await q<SessionRow>(
    env,
    "SELECT id, device_name, platform, created_ms, last_seen_ms, expires_ms FROM sessions WHERE user_id = ? AND revoked_ms IS NULL ORDER BY last_seen_ms DESC",
    [auth.user.id],
  );
  return json({
    sessions: rows.map((r) => ({
      id: r.id,
      deviceName: r.device_name,
      platform: r.platform,
      createdAt: r.created_ms,
      lastSeenAt: r.last_seen_ms,
      expiresAt: r.expires_ms,
      // 发起列表请求的会话标 current:客户端据此区分「本机」与其他设备,
      // 重名设备(同型号同名)也能识别出哪条是当前会话
      current: r.id === auth.sessionId,
    })),
  });
}

/// 会话自命名:调用方会话刷新自己的设备名。客户端解锁后即调用——
/// 历史会话的通用名(如未改名的 "iPhone")无需重新登录即可自愈为
/// 型号+设备名;只能改自己(鉴权即身份),改他人会话不可达。
export async function handleSessionRename(
  env: Env,
  request: Request,
  auth: AuthContext,
): Promise<Response> {
  const body = await readJson(request);
  const name = sanitizeDeviceName(body.deviceName);
  if (!name) throw new ApiError(400, "invalid_name");
  await exec(env, "UPDATE sessions SET device_name = ? WHERE id = ? AND revoked_ms IS NULL", [
    name,
    auth.sessionId,
  ]);
  return json({ ok: true });
}

export async function handleSessionRevoke(
  env: Env,
  auth: AuthContext,
  sessionId: string,
): Promise<Response> {
  if (!/^[0-9a-f]{32}$/.test(sessionId)) throw new ApiError(404, "not_found");
  const result = await exec(
    env,
    "UPDATE sessions SET revoked_ms = ? WHERE user_id = ? AND id = ? AND revoked_ms IS NULL",
    [nowMs(), auth.user.id, sessionId],
  );
  if (!result.affectedRows) throw new ApiError(404, "not_found");
  await audit(env, "session_revoke", { userId: auth.user.id }, { sessionId: sessionId.slice(0, 8) });
  return json({ ok: true });
}

/// 自撤销:登出/换设备重登时调用方吊销自己的会话(鉴权即身份,无需会话号)。
/// 客户端登录成功后会先自撤销本机旧令牌对应的会话,避免同一设备堆积多条会话。
export async function handleSessionSelfRevoke(env: Env, auth: AuthContext): Promise<Response> {
  const result = await exec(
    env,
    "UPDATE sessions SET revoked_ms = ? WHERE id = ? AND user_id = ? AND revoked_ms IS NULL",
    [nowMs(), auth.sessionId, auth.user.id],
  );
  if (!result.affectedRows) throw new ApiError(404, "not_found");
  await audit(env, "session_revoke", { userId: auth.user.id }, { self: true });
  return json({ ok: true });
}

// ---------- 注销 ----------

/// R2 侧某用户全部附件对象清除(行由 users 级联删除覆盖,R2 需显式删)。
async function deleteUserR2Objects(env: Env, userId: string): Promise<void> {
  const vaults = await q<{ vault_id: string }>(env, "SELECT vault_id FROM vaults WHERE user_id = ?", [
    userId,
  ]);
  for (const row of vaults) {
    await deleteR2Prefix(env.VAULTS, `vaults/${row.vault_id}/attachments/`);
  }
}

export async function handleDeregister(env: Env, request: Request, auth: AuthContext): Promise<Response> {
  const body = await readJson(request);
  await requireSensitiveCode(env, auth.user, body.code);
  const now = nowMs();
  // 先吊销全部会话再删数据:注销进行中其他设备的并发写入不再产生孤儿
  await exec(env, "UPDATE sessions SET revoked_ms = ? WHERE user_id = ? AND revoked_ms IS NULL", [
    now,
    auth.user.id,
  ]);
  // R2 附件先于行清除:行删了就再也找不回 vaultId,密文副本会无限期残留
  await deleteUserR2Objects(env, auth.user.id);
  // 立即清空敏感数据(信封/邮箱);vaults 级联删 items/changes/attachments/rekeys
  await exec(env, "DELETE FROM vaults WHERE user_id = ?", [auth.user.id]);
  await exec(
    env,
    "UPDATE users SET state = 'deregistered', email_enc = NULL, deregistered_at_ms = ? WHERE id = ?",
    [now, auth.user.id],
  );
  await audit(env, "account_deregister", { userId: auth.user.id });
  return json({ ok: true });
}

/// 物理清除单个用户的全部行(注销重注册立即路径,与 cron 30 天路径共用)。
export async function purgeUser(env: Env, userId: string, eh: string): Promise<void> {
  await deleteUserR2Objects(env, userId);
  await exec(env, "DELETE FROM users WHERE id = ?", [userId]);
  await exec(env, "DELETE FROM email_codes WHERE email_hmc = ?", [eh]);
}

/// cron:清除注销超过保留期(默认 30 天)的用户残行。
export async function purgeDeregistered(env: Env): Promise<void> {
  const days = numVar(env, "DEREGISTER_PURGE_DAYS", 30);
  const cutoff = nowMs() - days * 86_400_000;
  const rows = await q<{ id: string; email_hmc: string }>(
    env,
    "SELECT id, email_hmc FROM users WHERE state = 'deregistered' AND deregistered_at_ms < ?",
    [cutoff],
  );
  for (const row of rows) {
    await purgeUser(env, row.id, row.email_hmc);
  }
  console.log(JSON.stringify({ t: Date.now(), action: "cron_purge", count: rows.length }));
}
