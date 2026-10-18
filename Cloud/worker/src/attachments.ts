// 附件:密文 blob 走 R2(staging→commit 原子换入),MariaDB 只存登记行
// (object_key/大小/密文哈希/VEK 包裹的 DEK)。上传顺序规约:先附件 commit、
// 后推所属条目(对端拉到引用时 blob 必已就位)。

import type { AuthContext } from "./auth";
import { audit, connExec, connQuery, q1, tx } from "./db";
import { loadVault } from "./vaults";
import {
  ApiError,
  b64ToBytes,
  json,
  nowMs,
  numVar,
  readJson,
  sha256OfBytes,
  validItemUuid,
  validSha256Hex,
  type Env,
} from "./util";

function attachKey(vaultId: string, attachUuid: string): string {
  return `vaults/${vaultId}/attachments/${attachUuid}`;
}

function stagingPrefix(vaultId: string): string {
  return `vaults/${vaultId}/attachments/staging/`;
}

function stagingKey(vaultId: string, uploadId: string): string {
  return `vaults/${vaultId}/attachments/staging/${uploadId}`;
}

function attachMaxBytes(env: Env): number {
  return numVar(env, "ATTACHMENT_MAX_BYTES", 20 * 1024 * 1024);
}

/// PUT /v2/vaults/{id}/attachments/{uuid}?upload=UID —— 密文暂存。
/// 单请求携带完整密文;必须带 content-length(配额预判,免得传完才拒)。
export async function handleAttachmentPut(
  env: Env,
  request: Request,
  auth: AuthContext,
  vaultId: string,
  attachUuid: string,
  url: URL,
): Promise<Response> {
  await loadVault(env, auth.user.id, vaultId);
  if (!validItemUuid(attachUuid)) throw new ApiError(404, "not_found");
  const uploadId = url.searchParams.get("upload") ?? "";
  if (!/^[0-9a-f]{32}$/.test(uploadId)) throw new ApiError(400, "invalid_upload_id");
  const declared = Number(request.headers.get("content-length") ?? "");
  if (!Number.isFinite(declared) || declared < 1) throw new ApiError(411, "length_required");
  if (declared > attachMaxBytes(env)) throw new ApiError(413, "quota_exceeded");
  // 单库未提交 staging 数量配额:staging 由 cron 清扫,无配额时登录用户
  // 可无限堆 R2 存储(账单 DoS)
  const stagingMax = numVar(env, "ATTACH_STAGING_MAX_OBJECTS", 8);
  let existing = await env.VAULTS.list({ prefix: stagingPrefix(vaultId) });
  if (existing.objects.length >= stagingMax) {
    // 配额触发先清 1 小时以上的陈旧 staging(中断上传残渣)
    const cutoff = Date.now() - 3_600_000;
    for (const item of existing.objects) {
      if (item.uploaded.getTime() < cutoff) await env.VAULTS.delete(item.key);
    }
    existing = await env.VAULTS.list({ prefix: stagingPrefix(vaultId) });
    if (existing.objects.length >= stagingMax) throw new ApiError(413, "quota_exceeded");
  }
  await env.VAULTS.put(stagingKey(vaultId, uploadId), request.body, {
    httpMetadata: { contentType: "application/octet-stream" },
  });
  return json({ ok: true, received: declared });
}

/// POST /v2/vaults/{id}/attachments/{uuid}/commit —— 校验 sha256 后原子换入:
/// 服务端对 staging 字节实算哈希(不信客户端申报),R2 写生效对象、
/// 事务内写登记行并推进配额核算,最后删 staging。
export async function handleAttachmentCommit(
  env: Env,
  request: Request,
  auth: AuthContext,
  vaultId: string,
  attachUuid: string,
): Promise<Response> {
  await loadVault(env, auth.user.id, vaultId);
  if (!validItemUuid(attachUuid)) throw new ApiError(404, "not_found");
  const body = await readJson(request);
  const uploadId = typeof body.uploadId === "string" ? body.uploadId : "";
  const sha256 = validSha256Hex(body.sha256);
  const cardUuid = validItemUuid(body.cardUuid);
  const dek = typeof body.dekWrapped === "string" ? b64ToBytes(body.dekWrapped) : null;
  if (!/^[0-9a-f]{32}$/.test(uploadId) || !sha256 || !cardUuid || !dek || dek.length < 28 || dek.length > 256) {
    throw new ApiError(400, "bad_request");
  }

  const staged = await env.VAULTS.head(stagingKey(vaultId, uploadId));
  if (!staged) throw new ApiError(400, "incomplete_upload");
  if (staged.size < 1 || staged.size > attachMaxBytes(env)) throw new ApiError(413, "quota_exceeded");
  const stagedObject = await env.VAULTS.get(stagingKey(vaultId, uploadId));
  if (!stagedObject) throw new ApiError(400, "incomplete_upload");
  const bytes = new Uint8Array(await stagedObject.arrayBuffer());
  const actual = await sha256OfBytes(bytes);
  if (actual !== sha256 || bytes.length !== staged.size) {
    // 申报哈希与实际字节不符:上传中断/损坏,废弃本次 staging
    await env.VAULTS.delete(stagingKey(vaultId, uploadId));
    console.log(
      JSON.stringify({ t: Date.now(), action: "attach_commit_hash_mismatch", size: bytes.length }),
    );
    throw new ApiError(400, "hash_mismatch");
  }

  const quota = numVar(env, "ATTACH_QUOTA_PER_VAULT", 500 * 1024 * 1024);
  const now = nowMs();
  await tx(env, async (conn) => {
    await connQuery(conn, "SELECT vault_id FROM vaults WHERE vault_id = ? AND user_id = ? FOR UPDATE", [
      vaultId,
      auth.user.id,
    ]);
    const prev = await connQuery<{ bytes: number }>(
      conn,
      "SELECT bytes FROM attachments WHERE vault_id = ? AND attach_uuid = ?",
      [vaultId, attachUuid],
    );
    const prevBytes = prev[0]?.bytes ?? 0;
    // 同附件重传按差量核算配额(先删旧行再加新行等价)
    const currentTotal = await connQuery<{ total: bigint | number }>(
      conn,
      "SELECT attach_bytes AS total FROM vaults WHERE vault_id = ?",
      [vaultId],
    );
    const total = Number(currentTotal[0]?.total ?? 0) - prevBytes + bytes.length;
    if (total > quota) throw new ApiError(413, "quota_exceeded");
    await connExec(
      conn,
      `INSERT INTO attachments (vault_id, attach_uuid, card_uuid, object_key, dek_wrapped, sha256, bytes, created_ms)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?)
       ON DUPLICATE KEY UPDATE card_uuid = VALUES(card_uuid), object_key = VALUES(object_key),
         dek_wrapped = VALUES(dek_wrapped), sha256 = VALUES(sha256), bytes = VALUES(bytes)`,
      [vaultId, attachUuid, cardUuid, attachKey(vaultId, attachUuid), dek, sha256, bytes.length, now],
    );
    await connExec(
      conn,
      "UPDATE vaults SET attach_bytes = attach_bytes - ? + ?, updated_ms = ? WHERE vault_id = ?",
      [prevBytes, bytes.length, now, vaultId],
    );
  });

  await env.VAULTS.put(attachKey(vaultId, attachUuid), bytes, {
    httpMetadata: { contentType: "application/octet-stream" },
  });
  await env.VAULTS.delete(stagingKey(vaultId, uploadId));
  await audit(env, "attach_commit", { userId: auth.user.id, vaultId }, { size: bytes.length });
  return json({ ok: true, bytes: bytes.length });
}

/// GET /v2/vaults/{id}/attachments/{uuid} —— 拉取密文流(懒拉取)。
export async function handleAttachmentGet(
  env: Env,
  auth: AuthContext,
  vaultId: string,
  attachUuid: string,
): Promise<Response> {
  if (!validItemUuid(attachUuid)) throw new ApiError(404, "not_found");
  const row = await q1<{ sha256: string; bytes: number }>(
    env,
    "SELECT sha256, bytes FROM attachments WHERE vault_id = ? AND attach_uuid = ?",
    [vaultId, attachUuid],
  );
  if (!row) throw new ApiError(404, "not_found");
  const object = await env.VAULTS.get(attachKey(vaultId, attachUuid));
  if (!object) throw new ApiError(404, "not_found");
  const headers = new Headers({
    "content-type": "application/octet-stream",
    "x-sha256": row.sha256,
    "x-bytes": String(object.size),
    "cache-control": "private, max-age=0, no-store",
  });
  return new Response(object.body, { status: 200, headers });
}

/// DELETE /v2/vaults/{id}/attachments/{uuid} —— 删行 + 删 blob
/// (随条目硬清除触发;对端懒拉 404 由重试兜底)。
export async function handleAttachmentDelete(
  env: Env,
  auth: AuthContext,
  vaultId: string,
  attachUuid: string,
): Promise<Response> {
  if (!validItemUuid(attachUuid)) throw new ApiError(404, "not_found");
  const removed = await tx(env, async (conn) => {
    await connQuery(conn, "SELECT vault_id FROM vaults WHERE vault_id = ? AND user_id = ? FOR UPDATE", [
      vaultId,
      auth.user.id,
    ]);
    const rows = await connQuery<{ bytes: number; object_key: string }>(
      conn,
      "SELECT bytes, object_key FROM attachments WHERE vault_id = ? AND attach_uuid = ?",
      [vaultId, attachUuid],
    );
    if (rows.length < 1) return null;
    await connExec(conn, "DELETE FROM attachments WHERE vault_id = ? AND attach_uuid = ?", [
      vaultId,
      attachUuid,
    ]);
    await connExec(
      conn,
      "UPDATE vaults SET attach_bytes = attach_bytes - ?, updated_ms = ? WHERE vault_id = ?",
      [rows[0].bytes, nowMs(), vaultId],
    );
    return rows[0];
  });
  if (!removed) throw new ApiError(404, "not_found");
  await env.VAULTS.delete(removed.object_key);
  await audit(env, "attach_delete", { userId: auth.user.id, vaultId });
  return json({ ok: true });
}
