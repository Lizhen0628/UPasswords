// vault 注册表:登记(创建即携带初始信封)/列表/详情(含信封)/高水位/改名/
// 解绑/换绑。所有操作按会话用户行级隔离;缺失与他库一律 404。
// 信封唯一写入入口 = 建库与 rekey commit(独立 PUT /envelope 已取消,
// 防止「信封已换、条目未重加密」的漂移态)。

import {
  consumeCodeForEmail,
  getOrCreateUser,
  issueSession,
  requireSensitiveCode,
  type AuthContext,
} from "./auth";
import { audit, exec, q, q1 } from "./db";
import {
  ApiError,
  b64ToBytes,
  bytesToB64,
  deleteR2Prefix,
  emailHmc,
  json,
  kekOpen,
  kekSeal,
  normalizeEmail,
  nowMs,
  numVar,
  randomHex,
  readJson,
  validVaultName,
  type Env,
} from "./util";

export interface VaultRow {
  vault_id: string;
  user_id: string;
  name: string;
  password_version: number;
  password_changed_ms: number;
  envelope_enc: string | null;
  envelope_changed_ms: number | null;
  head_seq: number;
  changes_floor_seq: number;
  item_count: number;
  attach_bytes: number;
  created_ms: number;
  updated_ms: number;
}

/// UPWKEY1 信封魔数(8 字节,服务端只验格式不解密内容)。
const KEY_ENVELOPE_MAGIC = [0x55, 0x50, 0x57, 0x4b, 0x45, 0x59, 0x31, 0x00];

export function looksLikeKeyEnvelope(bytes: Uint8Array): boolean {
  if (bytes.length < 100 || bytes.length > 4096) return false;
  for (let i = 0; i < KEY_ENVELOPE_MAGIC.length; i++) {
    if (bytes[i] !== KEY_ENVELOPE_MAGIC[i]) return false;
  }
  return true;
}

export async function loadVault(env: Env, userId: string, vaultId: string): Promise<VaultRow> {
  if (!/^[0-9a-f]{32}$/.test(vaultId)) throw new ApiError(404, "not_found");
  const row = await q1<VaultRow>(
    env,
    "SELECT * FROM vaults WHERE vault_id = ? AND user_id = ?",
    [vaultId, userId],
  );
  if (!row) throw new ApiError(404, "not_found");
  return row;
}

function toMeta(row: VaultRow) {
  return {
    vaultId: row.vault_id,
    name: row.name,
    passwordVersion: row.password_version,
    passwordChangedAt: row.password_changed_ms,
    envelopeChangedAt: row.envelope_changed_ms,
    hasEnvelope: row.envelope_enc !== null,
    headSeq: row.head_seq,
    itemCount: row.item_count,
    attachBytes: row.attach_bytes,
    createdAt: row.created_ms,
    updatedAt: row.updated_ms,
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
  const count = await q1<{ c: number }>(
    env,
    "SELECT COUNT(*) AS c FROM vaults WHERE user_id = ?",
    [auth.user.id],
  );
  if ((count?.c ?? 0) >= limit) throw new ApiError(413, "quota_exceeded");

  // 创建即携带初始信封(绑定即全量上行的第一块拼图;可为空,绑定上行时
  // 由 rekey 之外的首个条目批次前补——客户端规约:首个 items 批次前
  // 必须已存在信封,否则其他设备无法解密恢复)
  let envelopeEnc: string | null = null;
  if (body.envelope !== undefined && body.envelope !== null) {
    const bytes = typeof body.envelope === "string" ? b64ToBytes(body.envelope) : null;
    if (!bytes || !looksLikeKeyEnvelope(bytes)) throw new ApiError(400, "invalid_envelope");
    envelopeEnc = await kekSeal(env, bytes);
  }

  const vaultId = randomHex(16);
  const now = nowMs();
  try {
    await exec(
      env,
      "INSERT INTO vaults (vault_id, user_id, name, password_version, password_changed_ms, envelope_enc, envelope_changed_ms, created_ms, updated_ms) VALUES (?, ?, ?, 1, ?, ?, ?, ?, ?)",
      [vaultId, auth.user.id, name, now, envelopeEnc, envelopeEnc ? now : null, now, now],
    );
  } catch (error) {
    if (String(error).includes("uq_vaults_user_name")) throw new ApiError(409, "name_exists");
    throw error;
  }
  await audit(env, "vault_create", { userId: auth.user.id, vaultId });
  return json({ vaultId, passwordVersion: 1 }, 201);
}

export async function handleListVaults(env: Env, auth: AuthContext): Promise<Response> {
  const rows = await q<VaultRow>(
    env,
    "SELECT * FROM vaults WHERE user_id = ? ORDER BY created_ms ASC",
    [auth.user.id],
  );
  return json({ vaults: rows.map(toMeta) });
}

export async function handleGetVault(
  env: Env,
  auth: AuthContext,
  vaultId: string,
): Promise<Response> {
  const row = await loadVault(env, auth.user.id, vaultId);
  // KEK 轮换丢失等极端情况下解不开 → envelope:null,客户端回退本地信封
  const envelopeBytes = await kekOpen(env, row.envelope_enc);
  return json({ ...toMeta(row), envelope: envelopeBytes ? bytesToB64(envelopeBytes) : null });
}

/// 便宜轮询:单行主键读,活跃设备每 60s 打一次,判断有无任何变更。
export async function handleVaultSeq(env: Env, auth: AuthContext, vaultId: string): Promise<Response> {
  const row = await loadVault(env, auth.user.id, vaultId);
  return json({ headSeq: row.head_seq, passwordVersion: row.password_version });
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
  const dup = await q1<{ hit: number }>(
    env,
    "SELECT 1 AS hit FROM vaults WHERE user_id = ? AND name = ? AND vault_id <> ?",
    [auth.user.id, name, vaultId],
  );
  if (dup) throw new ApiError(409, "name_exists");
  try {
    await exec(env, "UPDATE vaults SET name = ?, updated_ms = ? WHERE vault_id = ? AND user_id = ?", [
      name,
      nowMs(),
      vaultId,
      auth.user.id,
    ]);
  } catch (error) {
    // dup 检查与 UPDATE 之间的并发同名:UNIQUE 冲突按 409 而非 500
    if (String(error).includes("uq_vaults_user_name")) throw new ApiError(409, "name_exists");
    throw error;
  }
  await audit(env, "vault_rename", { userId: auth.user.id, vaultId });
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
  // R2 附件密文先删(行删除后再也找不回 vaultId,密文会无限期残留)
  await deleteR2Prefix(env.VAULTS, `vaults/${vaultId}/attachments/`);
  // 行删除:vaults 级联清 items/changes/attachments/rekeys
  await exec(env, "DELETE FROM vaults WHERE vault_id = ? AND user_id = ?", [vaultId, auth.user.id]);
  await audit(env, "vault_registry_delete", { userId: auth.user.id, vaultId });
  return json({ ok: true });
}

/// 换绑邮箱:把当前库整体迁移到新邮箱名下(vaultId/信封/条目/附件全部
// 保留,双端无感)。前置条件由客户端保证(已验当前主密码);服务端门槛 =
/// 当前账户会话 + 当前账户 sensitive 码 + 新邮箱 sensitive 码(证明归属)。
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
  const targetEh = await emailHmc(env, email);
  // 过户给当前账户自身没有意义,且两级 sensitive 码同邮箱单活跃必然失败
  if (targetEh === auth.user.email_hmc) throw new ApiError(400, "invalid_email");
  const target = await getOrCreateUser(env, email, targetEh, "transfer");

  // 注册表换主(行级数据按键 vaultId 寻址,换主无感);
  // 目标账户已有同名库时 UNIQUE 约束 → 409(与建库同语义)
  try {
    await exec(env, "UPDATE vaults SET user_id = ?, updated_ms = ? WHERE vault_id = ? AND user_id = ?", [
      target.id,
      nowMs(),
      vaultId,
      auth.user.id,
    ]);
  } catch (error) {
    if (String(error).includes("uq_vaults_user_name")) throw new ApiError(409, "name_exists");
    throw error;
  }
  const session = await issueSession(
    env,
    target.id,
    typeof body.deviceName === "string" ? body.deviceName : "",
    typeof body.platform === "string" ? body.platform : "other",
  );
  await audit(env, "vault_transfer", { userId: auth.user.id, vaultId }, { toUserId: target.id.slice(0, 8) });
  return json({ token: session.token, expiresAt: session.expiresAt, userId: target.id });
}
