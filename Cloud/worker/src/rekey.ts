// 改密(VEK 轮换)批量 rekey:begin(写锁+新信封暂存) → chunk(分块暂存,
// 断点续传,续期锁) → commit(单事务原子换入) / abort。
// 换入时全部条目行 revision+1:旧 VEK 密文的迟到推送必然撞 409,被迫走
// 「拉取→见 op=rekey→强制锁定」的收敛路径,不污染新密文(DESIGN §6.5)。

import type { AuthContext } from "./auth";
import { audit, connExec, connQuery, exec, q, q1, tx } from "./db";
import { loadVault, looksLikeKeyEnvelope } from "./vaults";
import {
  ApiError,
  b64ToBytes,
  json,
  kekSeal,
  nowMs,
  numVar,
  randomHex,
  readJson,
  sha256OfBytes,
  validItemUuid,
  validSha256Hex,
  type Env,
} from "./util";

const STAGE_ITEM = 1;
const STAGE_DEK = 2;
const ITEMS_JSON_MAX_BYTES = 8 * 1024 * 1024;

/// 惰性清掉本库已过期的 rekey(写路径与 begin 共用;发起端崩溃不锁死库)。
async function lazyCleanExpired(env: Env, vaultId: string): Promise<void> {
  await exec(env, "DELETE FROM rekeys WHERE vault_id = ? AND expires_ms < ?", [vaultId, nowMs()]);
}

export async function handleRekeyBegin(
  env: Env,
  request: Request,
  auth: AuthContext,
  vaultId: string,
): Promise<Response> {
  const vault = await loadVault(env, auth.user.id, vaultId);
  const body = await readJson(request);
  const envelope = typeof body.envelope === "string" ? b64ToBytes(body.envelope) : null;
  if (!envelope || !looksLikeKeyEnvelope(envelope)) throw new ApiError(400, "invalid_envelope");
  const itemTotal = positiveInt(body.itemCount);
  const dekTotal = nonNegativeInt(body.dekCount);
  if (itemTotal === null || dekTotal === null) throw new ApiError(400, "bad_request");

  await lazyCleanExpired(env, vaultId);
  const active = await q1<{ rekey_id: string }>(
    env,
    "SELECT rekey_id FROM rekeys WHERE vault_id = ?",
    [vaultId],
  );
  if (active) throw new ApiError(409, "rekey_in_progress");

  const rekeyId = randomHex(16);
  const now = nowMs();
  const ttl = numVar(env, "REKEY_TTL_MS", 3_600_000);
  await exec(
    env,
    "INSERT INTO rekeys (rekey_id, vault_id, new_envelope_enc, new_password_version, item_total, dek_total, item_staged, dek_staged, expires_ms, created_ms) VALUES (?, ?, ?, ?, ?, ?, 0, 0, ?, ?)",
    [
      rekeyId,
      vaultId,
      await kekSeal(env, envelope),
      vault.password_version + 1,
      itemTotal,
      dekTotal,
      now + ttl,
      now,
    ],
  );
  await audit(env, "rekey_begin", { userId: auth.user.id, vaultId }, { itemTotal, dekTotal });
  return json({ rekeyId, expiresAt: now + ttl, passwordVersion: vault.password_version + 1 }, 201);
}

export async function handleRekeyChunk(
  env: Env,
  request: Request,
  auth: AuthContext,
  vaultId: string,
  rekeyId: string,
): Promise<Response> {
  await loadVault(env, auth.user.id, vaultId);
  const body = await readJson(request, ITEMS_JSON_MAX_BYTES);
  const rekey = await mustLoadRekey(env, vaultId, rekeyId);
  const ttl = numVar(env, "REKEY_TTL_MS", 3_600_000);

  const bodyMax = numVar(env, "ITEM_BODY_MAX_BYTES", 262_144);
  const rawItems = Array.isArray(body.items) ? body.items : [];
  const rawDeks = Array.isArray(body.dekWraps) ? body.dekWraps : [];
  if (rawItems.length + rawDeks.length < 1) throw new ApiError(400, "bad_request");

  for (const raw of rawItems) {
    const r = raw as Record<string, unknown>;
    const uuid = validItemUuid(r.uuid);
    const bytes = typeof r.bodyB64 === "string" ? b64ToBytes(r.bodyB64) : null;
    const sha = validSha256Hex(r.sha256);
    if (!uuid || !bytes || bytes.length < 1 || bytes.length > bodyMax) throw new ApiError(400, "bad_request");
    if (!sha || (await sha256OfBytes(bytes)) !== sha) throw new ApiError(400, "hash_mismatch");
    await exec(
      env,
      "INSERT INTO rekey_staging (rekey_id, item_uuid, kind, payload, sha256) VALUES (?, ?, ?, ?, ?) ON DUPLICATE KEY UPDATE payload = VALUES(payload), sha256 = VALUES(sha256)",
      [rekeyId, uuid, STAGE_ITEM, bytes, sha],
    );
  }
  for (const raw of rawDeks) {
    const r = raw as Record<string, unknown>;
    const uuid = validItemUuid(r.uuid);
    const dek = typeof r.dekB64 === "string" ? b64ToBytes(r.dekB64) : null;
    if (!uuid || !dek || dek.length < 28 || dek.length > 256) throw new ApiError(400, "bad_request");
    await exec(
      env,
      "INSERT INTO rekey_staging (rekey_id, item_uuid, kind, payload, sha256) VALUES (?, ?, ?, ?, ?) ON DUPLICATE KEY UPDATE payload = VALUES(payload), sha256 = VALUES(sha256)",
      [rekeyId, uuid, STAGE_DEK, dek, await sha256OfBytes(dek)],
    );
  }

  // 重算已暂存计数(幂等,重传同 uuid 不虚增)并续期锁
  const counts = await q<{ kind: number; c: number }>(
    env,
    "SELECT kind, COUNT(*) AS c FROM rekey_staging WHERE rekey_id = ? GROUP BY kind",
    [rekeyId],
  );
  const itemStaged = Number(counts.find((c) => c.kind === STAGE_ITEM)?.c ?? 0);
  const dekStaged = Number(counts.find((c) => c.kind === STAGE_DEK)?.c ?? 0);
  if (itemStaged > rekey.item_total || dekStaged > rekey.dek_total) {
    throw new ApiError(400, "bad_request");
  }
  await exec(env, "UPDATE rekeys SET item_staged = ?, dek_staged = ?, expires_ms = ? WHERE rekey_id = ?", [
    itemStaged,
    dekStaged,
    nowMs() + ttl,
    rekeyId,
  ]);
  await audit(env, "rekey_chunk", { userId: auth.user.id, vaultId }, { itemStaged, dekStaged });
  return json({ itemStaged, dekStaged });
}

/// POST /v2/vaults/{id}/rekey/{rekeyId}/commit —— 校验计数齐全后单事务换入:
/// 条目行(新 VEK 密文,revision+1) ← staging;附件 DEK 重裹;信封与
/// password_version 原子切换;写 op=rekey 变更;清暂存。
/// 库内现行条目/附件数必须与 begin 申报一致(begin 后有过漂移 → 409 rekey_stale,
/// 客户端重新同步后重启 rekey)。
export async function handleRekeyCommit(
  env: Env,
  request: Request,
  auth: AuthContext,
  vaultId: string,
  rekeyId: string,
): Promise<Response> {
  await readJson(request);
  const rekey = await mustLoadRekey(env, vaultId, rekeyId);
  if (rekey.item_staged !== rekey.item_total || rekey.dek_staged !== rekey.dek_total) {
    throw new ApiError(409, "rekey_incomplete");
  }

  const now = nowMs();
  const passwordVersion = await tx(env, async (conn) => {
    const vaultRows = await connQuery<{ password_version: number }>(
      conn,
      "SELECT password_version FROM vaults WHERE vault_id = ? AND user_id = ? FOR UPDATE",
      [vaultId, auth.user.id],
    );
    if (vaultRows.length < 1) throw new ApiError(404, "not_found");
    // begin 之后的漂移防护:现行条目/附件数必须与申报一致
    const itemCount = await connQuery<{ c: number }>(
      conn,
      "SELECT COUNT(*) AS c FROM vault_items WHERE vault_id = ?",
      [vaultId],
    );
    const attachCount = await connQuery<{ c: number }>(
      conn,
      "SELECT COUNT(*) AS c FROM attachments WHERE vault_id = ?",
      [vaultId],
    );
    if (Number(itemCount[0]?.c ?? 0) !== rekey.item_total || Number(attachCount[0]?.c ?? 0) !== rekey.dek_total) {
      throw new ApiError(409, "rekey_stale");
    }

    // 条目整批换入(revision+1:旧 VEK 迟到推送必然 CAS 冲突)
    await connQuery(
      conn,
      `INSERT INTO vault_items (vault_id, item_uuid, kind, revision, body, body_sha256, body_bytes, modified_ms, created_ms, updated_ms)
       SELECT ?, rs.item_uuid, rs.kind, 1, rs.payload, rs.sha256, LENGTH(rs.payload), 0, ?, ?
       FROM rekey_staging rs WHERE rs.rekey_id = ? AND rs.kind = ${STAGE_ITEM}
       ON DUPLICATE KEY UPDATE kind = VALUES(kind), revision = vault_items.revision + 1,
         body = VALUES(body), body_sha256 = VALUES(body_sha256), body_bytes = VALUES(body_bytes), updated_ms = VALUES(updated_ms)`,
      [vaultId, now, now, rekeyId],
    );
    // 附件 DEK 重裹(blob 不动)
    await connQuery(
      conn,
      `UPDATE attachments a JOIN rekey_staging rs ON rs.rekey_id = ? AND rs.kind = ${STAGE_DEK} AND rs.item_uuid = a.attach_uuid
       SET a.dek_wrapped = rs.payload`,
      [rekeyId],
    );
    // 信封 + password_version 原子切换(信封唯一写入入口之二)
    await connExec(
      conn,
      "UPDATE vaults SET envelope_enc = ?, envelope_changed_ms = ?, password_version = ?, password_changed_ms = ?, updated_ms = ? WHERE vault_id = ?",
      [rekey.new_envelope_enc, now, rekey.new_password_version, now, now, vaultId],
    );
    // 库级 op=rekey(对端见此即强制锁定走全量重建);seq 由 insertId 推算
    // (Hyperdrive 下 UPDATE 内子查询看不到同事务 INSERT,见 items.ts 同款注释)
    const change = await connExec(
      conn,
      "INSERT INTO item_changes (vault_id, item_uuid, op, revision, session_id, created_ms) VALUES (?, '', ?, ?, ?, ?)",
      [vaultId, 3, rekey.new_password_version, auth.sessionId, now],
    );
    await connExec(
      conn,
      "UPDATE vaults SET head_seq = GREATEST(head_seq, ?) WHERE vault_id = ?",
      [change.insertId, vaultId],
    );
    // 清暂存(rekeys 删除级联 rekey_staging)
    await connExec(conn, "DELETE FROM rekeys WHERE rekey_id = ?", [rekeyId]);
    return rekey.new_password_version;
  });

  await audit(env, "rekey_commit", { userId: auth.user.id, vaultId }, { passwordVersion });
  return json({ ok: true, passwordVersion });
}

/// DELETE /v2/vaults/{id}/rekey/{rekeyId} —— 放弃(库回旧态,暂存清空)。
export async function handleRekeyAbort(
  env: Env,
  auth: AuthContext,
  vaultId: string,
  rekeyId: string,
): Promise<Response> {
  await loadVault(env, auth.user.id, vaultId);
  await mustLoadRekey(env, vaultId, rekeyId);
  await exec(env, "DELETE FROM rekeys WHERE rekey_id = ?", [rekeyId]);
  await audit(env, "rekey_abort", { userId: auth.user.id, vaultId });
  return json({ ok: true });
}

interface RekeyRow {
  rekey_id: string;
  vault_id: string;
  new_envelope_enc: string;
  new_password_version: number;
  item_total: number;
  dek_total: number;
  item_staged: number;
  dek_staged: number;
  expires_ms: number;
}

async function mustLoadRekey(env: Env, vaultId: string, rekeyId: string): Promise<RekeyRow> {
  if (!/^[0-9a-f]{32}$/.test(rekeyId)) throw new ApiError(404, "not_found");
  const row = await q1<RekeyRow>(env, "SELECT * FROM rekeys WHERE rekey_id = ? AND vault_id = ?", [
    rekeyId,
    vaultId,
  ]);
  if (!row) throw new ApiError(404, "not_found");
  if (row.expires_ms < nowMs()) {
    // 过期惰性判定:视同不存在,顺带清理
    await exec(env, "DELETE FROM rekeys WHERE rekey_id = ?", [rekeyId]);
    throw new ApiError(410, "rekey_expired");
  }
  return row;
}

function positiveInt(input: unknown): number | null {
  if (typeof input !== "number" || !Number.isInteger(input) || input < 1) return null;
  return input;
}

function nonNegativeInt(input: unknown): number | null {
  if (typeof input !== "number" || !Number.isInteger(input) || input < 0) return null;
  return input;
}
