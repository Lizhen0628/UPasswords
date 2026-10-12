// vault 注册表:登记/列表/详情(含信封)/信封上报(changedAt 决胜+偏斜钳制)/
// 哈希上报/改名/解绑。所有操作按会话用户行级隔离;缺失与他库一律 404。

import {
  consumeCodeForEmail,
  getOrCreateUser,
  issueSession,
  requireSensitiveCode,
  type AuthContext,
} from "./auth";
import { audit } from "./db";
import {
  ApiError,
  b64ToBytes,
  bytesToB64,
  deleteR2Prefix,
  emailHmac,
  json,
  kekOpen,
  kekSeal,
  normalizeEmail,
  nowSec,
  numVar,
  randomHex,
  readJson,
  sha256OfBytes,
  utf8,
  validSha256Hex,
  validVaultName,
  type Env,
} from "./util";

interface VaultRow {
  vault_id: string;
  user_id: string;
  name: string;
  password_version: number;
  password_changed_at: number;
  envelope_enc: string | null;
  envelope_changed_at: number | null;
  cipher_sha256: string | null;
  xml_sha256: string | null;
  created_at: number;
  updated_at: number;
  body_sha256: string | null;
  body_bytes: number | null;
  body_updated_at: number | null;
}

/// UPWKEY1 信封魔数(8 字节,服务端只验格式不解密内容)。
const KEY_ENVELOPE_MAGIC = [0x55, 0x50, 0x57, 0x4b, 0x45, 0x59, 0x31, 0x00];

function looksLikeKeyEnvelope(bytes: Uint8Array): boolean {
  if (bytes.length < KEY_ENVELOPE_MAGIC.length) return false;
  for (let i = 0; i < KEY_ENVELOPE_MAGIC.length; i++) {
    if (bytes[i] !== KEY_ENVELOPE_MAGIC[i]) return false;
  }
  return true;
}

async function loadVault(env: Env, userId: string, vaultId: string): Promise<VaultRow> {
  const row = await env.DB.prepare("SELECT * FROM vaults WHERE vault_id = ? AND user_id = ?")
    .bind(vaultId, userId)
    .first<VaultRow>();
  if (!row) throw new ApiError(404, "not_found");
  return row;
}

function toMeta(row: VaultRow) {
  return {
    vaultId: row.vault_id,
    name: row.name,
    passwordVersion: row.password_version,
    passwordChangedAt: row.password_changed_at,
    envelopeChangedAt: row.envelope_changed_at,
    hasEnvelope: row.envelope_enc !== null,
    cipherSha256: row.cipher_sha256,
    xmlSha256: row.xml_sha256,
    bodySha256: row.body_sha256,
    bodyBytes: row.body_bytes,
    bodyUpdatedAt: row.body_updated_at,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

export async function handleCreateVault(
  env: Env,
  request: Request,
  auth: AuthContext,
): Promise<Response> {
  const body = await readJson(request);
  const name = validVaultName(body.name);
  if (!name) throw new ApiError(400, "invalid_name");

  const limit = numVar(env, "VAULT_LIMIT_PER_USER", 10);
  const count = await env.DB.prepare("SELECT COUNT(*) AS c FROM vaults WHERE user_id = ?")
    .bind(auth.user.id)
    .first<{ c: number }>();
  if ((count?.c ?? 0) >= limit) throw new ApiError(413, "quota_exceeded");

  const vaultId = randomHex(16);
  const now = nowSec();
  try {
    await env.DB.prepare(
      "INSERT INTO vaults (vault_id, user_id, name, password_version, password_changed_at, created_at, updated_at) VALUES (?, ?, ?, 1, ?, ?, ?)",
    )
      .bind(vaultId, auth.user.id, name, now, now, now)
      .run();
  } catch (error) {
    if (String(error).includes("UNIQUE")) throw new ApiError(409, "name_exists");
    throw error;
  }
  await audit(env.DB, "vault_create", { userId: auth.user.id, vaultId });
  return json({ vaultId, passwordVersion: 1 }, 201);
}

export async function handleListVaults(env: Env, auth: AuthContext): Promise<Response> {
  const rows = await env.DB.prepare(
    "SELECT * FROM vaults WHERE user_id = ? ORDER BY created_at ASC",
  )
    .bind(auth.user.id)
    .all<VaultRow>();
  return json({ vaults: (rows.results ?? []).map(toMeta) });
}

export async function handleGetVault(
  env: Env,
  auth: AuthContext,
  vaultId: string,
): Promise<Response> {
  const row = await loadVault(env, auth.user.id, vaultId);
  // KEK 轮换丢失等极端情况下解不开 → envelope:null,客户端回退网盘信封
  const envelopeBytes = await kekOpen(env, row.envelope_enc);
  return json({ ...toMeta(row), envelope: envelopeBytes ? bytesToB64(envelopeBytes) : null });
}

export async function handleEnvelopePut(
  env: Env,
  request: Request,
  auth: AuthContext,
  vaultId: string,
): Promise<Response> {
  const body = await readJson(request);
  const bytes = typeof body.envelope === "string" ? b64ToBytes(body.envelope) : null;
  if (!bytes || bytes.length < 100 || bytes.length > 4096 || !looksLikeKeyEnvelope(bytes)) {
    throw new ApiError(400, "invalid_envelope");
  }
  if (typeof body.changedAt !== "number" || !Number.isFinite(body.changedAt)) {
    throw new ApiError(400, "bad_request");
  }

  // 时钟偏斜钳制:超窗 changedAt 视为"现在",防坏钟设备的 changedAt 永胜
  let changedAt = body.changedAt;
  const now = nowSec();
  const skew = numVar(env, "CHANGED_AT_MAX_SKEW_SECONDS", 300);
  if (Math.abs(changedAt - now) > skew) changedAt = now;

  const row = await loadVault(env, auth.user.id, vaultId);
  // changedAt 决胜:不新于现有值即拒绝覆盖(相等也算过期,现值优先)
  if (row.envelope_changed_at !== null && changedAt <= row.envelope_changed_at) {
    await audit(env.DB, "envelope_stale", { userId: auth.user.id, vaultId });
    return json({ stale: true, changedAt: row.envelope_changed_at });
  }
  const version = row.password_version + 1;
  await env.DB.prepare(
    "UPDATE vaults SET envelope_enc = ?, envelope_changed_at = ?, password_version = ?, updated_at = ? WHERE vault_id = ?",
  )
    .bind(await kekSeal(env, bytes), changedAt, version, now, vaultId)
    .run();
  await audit(env.DB, "envelope_put", { userId: auth.user.id, vaultId }, { version, size: bytes.length });
  return json({ passwordVersion: version, changedAt });
}

export async function handleHashesPut(
  env: Env,
  request: Request,
  auth: AuthContext,
  vaultId: string,
): Promise<Response> {
  const body = await readJson(request);
  const cipherSha256 = validSha256Hex(body.cipherSha256);
  const xmlSha256 = validSha256Hex(body.xmlSha256);
  if (!cipherSha256 || !xmlSha256) throw new ApiError(400, "invalid_hash");
  await loadVault(env, auth.user.id, vaultId);
  await env.DB.prepare(
    "UPDATE vaults SET cipher_sha256 = ?, xml_sha256 = ?, updated_at = ? WHERE vault_id = ?",
  )
    .bind(cipherSha256, xmlSha256, nowSec(), vaultId)
    .run();
  await audit(env.DB, "hashes_put", { userId: auth.user.id, vaultId });
  return json({ ok: true });
}

export async function handleRenameVault(
  env: Env,
  request: Request,
  auth: AuthContext,
  vaultId: string,
): Promise<Response> {
  const body = await readJson(request);
  const name = validVaultName(body.name);
  if (!name) throw new ApiError(400, "invalid_name");
  await loadVault(env, auth.user.id, vaultId);
  const dup = await env.DB.prepare(
    "SELECT 1 AS hit FROM vaults WHERE user_id = ? AND name = ? AND vault_id <> ?",
  )
    .bind(auth.user.id, name, vaultId)
    .first<{ hit: number }>();
  if (dup) throw new ApiError(409, "name_exists");
  await env.DB.prepare("UPDATE vaults SET name = ?, updated_at = ? WHERE vault_id = ?")
    .bind(name, nowSec(), vaultId)
    .run();
  await audit(env.DB, "vault_rename", { userId: auth.user.id, vaultId });
  return json({ ok: true });
}

export async function handleDeleteVault(
  env: Env,
  request: Request,
  auth: AuthContext,
  vaultId: string,
): Promise<Response> {
  await loadVault(env, auth.user.id, vaultId);
  const body = await readJson(request);
  // 不可逆操作:必须持有当次新鲜 sensitive 验证码
  await requireSensitiveCode(env, auth.user, body.code);
  await env.DB.prepare("DELETE FROM vaults WHERE vault_id = ? AND user_id = ?")
    .bind(vaultId, auth.user.id)
    .run();
  // R2 库体与该库全部 staging 一并清除(元数据列随注册表行消亡)
  await env.VAULTS.delete(bodyKey(vaultId));
  await deleteR2Prefix(env.VAULTS, stagingPrefix(vaultId));
  await audit(env.DB, "vault_registry_delete", { userId: auth.user.id, vaultId });
  return json({ ok: true });
}

// MARK: - 库体密文存储(R2 对象存储)

/// 库体配额:默认 50MB(附件型大库也覆盖);R2 单对象上限 5TB,大小不再是
/// 结构问题,配额只是资源治理。Worker 请求体上限:免费版 100MB/付费版 200MB,
/// 配额须低于所用计划的请求体上限。
function bodyQuotaBytes(env: Env): number {
  return numVar(env, "VAULT_BODY_MAX_BYTES", 50 * 1024 * 1024);
}

/// 库体对象键:生效副本按 vault 唯一;staging 按上传会话隔离。
/// 全部收纳在 vaults/ 前缀下(桶内其他前缀留给未来的非库体数据)。
function bodyKey(vaultId: string): string {
  return `vaults/${vaultId}`;
}
function stagingPrefix(vaultId: string): string {
  return `vaults/staging/${vaultId}/`;
}
function stagingKey(vaultId: string, uploadId: string): string {
  return `vaults/staging/${vaultId}/${uploadId}`;
}

/// 上传库体(暂存):PUT /v1/vaults/{id}/body?upload=UID
/// 单请求携带完整密文(流式写入 R2,不分块);commit 前对读端不可见。
/// 必须携带 content-length(配额预判,免得传完才拒)。
export async function handleBodyPut(
  env: Env,
  request: Request,
  auth: AuthContext,
  vaultId: string,
  url: URL,
): Promise<Response> {
  await loadVault(env, auth.user.id, vaultId);
  const uploadId = url.searchParams.get("upload") ?? "";
  if (!/^[0-9a-f]{32}$/.test(uploadId)) throw new ApiError(400, "invalid_upload_id");
  const declared = Number(request.headers.get("content-length") ?? "");
  if (!Number.isFinite(declared) || declared < 1) throw new ApiError(411, "length_required");
  if (declared > bodyQuotaBytes(env)) throw new ApiError(413, "quota_exceeded");
  // 单库未提交 staging 数量配额:staging 24h 才被 cron 清扫,
  // 无配额时登录用户可无限堆 R2 存储(账单 DoS)
  const stagingMax = numVar(env, "VAULT_STAGING_MAX_OBJECTS", 4);
  const existing = await env.VAULTS.list({ prefix: stagingPrefix(vaultId) });
  if (existing.objects.length >= stagingMax) throw new ApiError(413, "quota_exceeded");
  await env.VAULTS.put(stagingKey(vaultId, uploadId), request.body, {
    httpMetadata: { contentType: "application/octet-stream" },
  });
  return json({ ok: true, received: declared });
}

/// 提交换入:POST /v1/vaults/{id}/body/commit {uploadId,sha256}
/// 服务端对 staging 字节实算 SHA-256 并与申报值比对(不信客户端申报,
/// 中断/损坏的密文不换入),通过后写生效对象、更新 D1、删除 staging。
/// 库体已在配额内(≤50MB),经缓冲区哈希后整写 R2。
/// 崩溃窗口:R2 已写生效对象但 D1 未更新 → 读端哈希不匹配可检测,下次上传自愈;
/// staging 残留 → 日度 cron 清扫。
export async function handleBodyCommit(
  env: Env,
  request: Request,
  auth: AuthContext,
  vaultId: string,
): Promise<Response> {
  await loadVault(env, auth.user.id, vaultId);
  const body = await readJson(request);
  const uploadId = typeof body.uploadId === "string" ? body.uploadId : "";
  const sha256 = validSha256Hex(body.sha256);
  if (!/^[0-9a-f]{32}$/.test(uploadId) || !sha256) throw new ApiError(400, "bad_request");

  const staged = await env.VAULTS.head(stagingKey(vaultId, uploadId));
  if (!staged) throw new ApiError(400, "incomplete_upload");
  if (staged.size < 1 || staged.size > bodyQuotaBytes(env)) throw new ApiError(413, "quota_exceeded");

  const stagedObject = await env.VAULTS.get(stagingKey(vaultId, uploadId));
  if (!stagedObject) throw new ApiError(400, "incomplete_upload");
  const bytes = new Uint8Array(await stagedObject.arrayBuffer());
  const actual = await sha256OfBytes(bytes);
  if (actual !== sha256) {
    // 申报哈希与实际字节不符:上传中断/损坏,废弃本次 staging
    await env.VAULTS.delete(stagingKey(vaultId, uploadId));
    console.log(JSON.stringify({ t: Date.now(), action: "body_commit_hash_mismatch", size: bytes.length }));
    throw new ApiError(400, "hash_mismatch");
  }
  await env.VAULTS.put(bodyKey(vaultId), bytes, {
    httpMetadata: { contentType: "application/octet-stream" },
  });
  const now = nowSec();
  await env.DB.prepare(
    "UPDATE vaults SET body_sha256 = ?, body_bytes = ?, body_updated_at = ?, updated_at = ? WHERE vault_id = ?",
  )
    .bind(sha256, staged.size, now, now, vaultId)
    .run();
  await env.VAULTS.delete(stagingKey(vaultId, uploadId));
  await audit(env.DB, "body_put", { userId: auth.user.id, vaultId }, { size: staged.size });
  return json({ ok: true, bytes: staged.size, updatedAt: now });
}

/// 下载库体:GET /v1/vaults/{id}/body → R2 对象流式回传。
/// 元数据经响应头回传;客户端先对 GET /vaults 的 bodySha256 短路,未变不拉。
export async function handleBodyGet(env: Env, auth: AuthContext, vaultId: string): Promise<Response> {
  const row = await loadVault(env, auth.user.id, vaultId);
  if (row.body_updated_at === null) throw new ApiError(404, "body_not_found");
  const object = await env.VAULTS.get(bodyKey(vaultId));
  if (!object) throw new ApiError(404, "body_not_found");
  const headers = new Headers({
    "content-type": "application/octet-stream",
    "x-body-sha256": row.body_sha256 ?? "",
    "x-body-bytes": String(object.size),
    "x-body-updated-at": String(row.body_updated_at ?? 0),
  });
  return new Response(object.body, { status: 200, headers });
}

/// cron 顺带清理:超过 1 天未 commit 的孤儿 staging 对象(中断上传残渣)。
export async function sweepStaleStaging(env: Env): Promise<void> {
  const cutoff = Date.now() - 86400 * 1000;
  let cursor: string | undefined;
  do {
    const listing = await env.VAULTS.list({ prefix: "vaults/staging/", cursor });
    for (const item of listing.objects) {
      if (item.uploaded.getTime() < cutoff) await env.VAULTS.delete(item.key);
    }
    cursor = listing.truncated ? listing.cursor : undefined;
  } while (cursor);
}

/// 换绑邮箱:把当前库的注册表记录迁移到新邮箱名下(vaultId 不变,云端
/// 同步结构随之换主;R2 库体键按 vaultId 寻址,换主无感)。前置条件由客户端
/// 保证(已验当前主密码);服务端门槛 = 当前账户会话 + 新邮箱的 sensitive 验证码。
/// 成功后直接为新账户签发本设备会话(等价完成新邮箱登录)。
export async function handleTransferVault(
  env: Env,
  request: Request,
  auth: AuthContext,
  vaultId: string,
): Promise<Response> {
  const body = await readJson(request);
  const email = normalizeEmail(body.email);
  if (!email) throw new ApiError(400, "invalid_email");
  await loadVault(env, auth.user.id, vaultId);
  // 门槛一:当前账户的 sensitive 码——令牌被盗不足以过户库,
  // 攻击者自发新邮箱的码无效(与删库/注销同级敏感操作)
  await requireSensitiveCode(env, auth.user, body.currentCode);
  // 门槛二:新邮箱的 sensitive 码(证明新邮箱归属)
  const codeOk = await consumeCodeForEmail(env, email, "sensitive", body.code);
  if (!codeOk) throw new ApiError(403, "invalid_code");

  // 目标账户:不存在则建(同注册语义);曾注销则清残行后重建
  const targetEh = await emailHmac(env, email);
  const target = await getOrCreateUser(env, email, targetEh, "transfer");

  // 注册表换主(vaultId/信封/哈希/库体全部保留,双端无感);
  // 目标账户已有同名库时 UNIQUE 约束 → 409(与建库同语义)
  try {
    await env.DB.prepare("UPDATE vaults SET user_id = ?, updated_at = ? WHERE vault_id = ?")
      .bind(target.id, nowSec(), vaultId)
      .run();
  } catch (error) {
    if (String(error).includes("UNIQUE")) throw new ApiError(409, "name_exists");
    throw error;
  }
  const session = await issueSession(env, target.id, typeof body.deviceName === "string" ? body.deviceName : "");
  await audit(env.DB, "vault_transfer", { userId: auth.user.id, vaultId }, { toUserId: target.id.slice(0, 8) });
  return json({ token: session.token, expiresAt: session.expiresAt, userId: target.id });
}
