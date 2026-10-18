// 条目行级同步核心:批量 CAS 上行、变更日志游标拉取、全量重建分页。
// 语义(v7):删除 = 删行 + op=purge 日志;「缺席即删除」由 not_found 收口;
// 无墓碑行(行库即权威,见 Cloud/DESIGN.md §6.6)。

import type { AuthContext } from "./auth";
import { audit, connExec, connQuery, exec, q, q1, tx } from "./db";
import { loadVault } from "./vaults";
import {
  ApiError,
  b64ToBytes,
  bytesToB64,
  json,
  nowMs,
  numVar,
  readJson,
  sha256OfBytes,
  validItemUuid,
  validSha256Hex,
  type Env,
} from "./util";

const KIND_CARD = 1;
const KIND_LABEL = 2;
const OP_UPSERT = 1;
const OP_PURGE = 2;
const OP_REKEY = 3;

/// 上行 JSON 上限:单条目密文 ≤256KB,200 条批量 + 元数据留足余量。
const ITEMS_JSON_MAX_BYTES = 8 * 1024 * 1024;

interface IncomingItem {
  uuid: string;
  kind: number;
  op: "upsert" | "delete";
  baseRevision: number;
  body: Uint8Array | null;
  bodySha256: string | null;
  modifiedMs: number;
}

function parseIncoming(raw: unknown): IncomingItem | null {
  if (!raw || typeof raw !== "object") return null;
  const r = raw as Record<string, unknown>;
  const uuid = validItemUuid(r.uuid);
  if (!uuid) return null;
  if (r.kind !== KIND_CARD && r.kind !== KIND_LABEL) return null;
  const op = r.op === "delete" ? "delete" : r.op === "upsert" ? "upsert" : null;
  if (!op) return null;
  if (typeof r.baseRevision !== "number" || !Number.isInteger(r.baseRevision) || r.baseRevision < 0) {
    return null;
  }
  if (typeof r.modifiedMs !== "number" || !Number.isInteger(r.modifiedMs) || r.modifiedMs < 0) {
    return null;
  }
  if (op === "upsert") {
    const bytes = typeof r.bodyB64 === "string" ? b64ToBytes(r.bodyB64) : null;
    if (!bytes || bytes.length < 1) return null;
    return { uuid, kind: r.kind, op, baseRevision: r.baseRevision, body: bytes, bodySha256: null, modifiedMs: r.modifiedMs };
  }
  return { uuid, kind: r.kind, op, baseRevision: r.baseRevision, body: null, bodySha256: null, modifiedMs: r.modifiedMs };
}

interface ItemResult {
  uuid: string;
  status: "ok" | "conflict" | "not_found";
  revision?: number;
  current?: { revision: number; bodyB64: string };
  deletedAt?: number;
  seq?: number;
}

interface ChangeValues {
  uuid: string;
  op: number;
  revision: number;
}

interface PurgedAttachment {
  bytes: number;
  objectKey: string;
}

/// POST /v2/vaults/{id}/items —— 批量 CAS 上行(§6.2)。
export async function handleItemsPost(
  env: Env,
  request: Request,
  auth: AuthContext,
  vaultId: string,
): Promise<Response> {
  await loadVault(env, auth.user.id, vaultId);
  const body = await readJson(request, ITEMS_JSON_MAX_BYTES);
  const rawItems = Array.isArray(body.items) ? body.items : null;
  if (!rawItems || rawItems.length < 1) throw new ApiError(400, "bad_request");
  const batchMax = numVar(env, "ITEMS_BATCH_MAX", 200);
  if (rawItems.length > batchMax) throw new ApiError(413, "too_many_items");

  const bodyMax = numVar(env, "ITEM_BODY_MAX_BYTES", 262_144);
  const itemsPerVault = numVar(env, "ITEMS_PER_VAULT_LIMIT", 50_000);
  const items: IncomingItem[] = [];
  const seen = new Set<string>();
  for (const raw of rawItems) {
    const item = parseIncoming(raw);
    if (!item) throw new ApiError(400, "bad_request");
    if (item.body && item.body.length > bodyMax) throw new ApiError(413, "item_too_large");
    // 申报 sha256 可选;提供时服务端实算比对(不信客户端申报)
    const declaredSha = (raw as Record<string, unknown>).sha256;
    if (declaredSha !== undefined) {
      const declared = validSha256Hex(declaredSha);
      if (!declared || !item.body) throw new ApiError(400, "bad_request");
      if ((await sha256OfBytes(item.body)) !== declared) throw new ApiError(400, "hash_mismatch");
      item.bodySha256 = declared;
    }
    if (seen.has(item.uuid)) throw new ApiError(400, "duplicate_uuid");
    seen.add(item.uuid);
    items.push(item);
  }

  const now = nowMs();
  const { results, purgedAttachments } = await tx(env, async (conn) => {
    // 库行锁:串行化本库写入,保证 CAS/head_seq/item_count/attach_bytes 一致
    const vaultRows = await connQuery<{ item_count: number }>(
      conn,
      "SELECT item_count FROM vaults WHERE vault_id = ? AND user_id = ? FOR UPDATE",
      [vaultId, auth.user.id],
    );
    if (vaultRows.length < 1) throw new ApiError(404, "not_found");

    // rekey 写锁(惰性判定:过期即视为失效并顺带清理,发起端崩溃不会锁死库)
    await connExec(conn, "DELETE FROM rekeys WHERE vault_id = ? AND expires_ms < ?", [vaultId, now]);
    const activeRekey = await connQuery<{ rekey_id: string }>(
      conn,
      "SELECT rekey_id FROM rekeys WHERE vault_id = ?",
      [vaultId],
    );
    if (activeRekey.length > 0) throw new ApiError(409, "rekey_in_progress");

    // 现行版本批量加载
    const uuids = items.map((i) => i.uuid);
    const placeholders = uuids.map(() => "?").join(", ");
    const currentRows = await connQuery<{ item_uuid: string; revision: number }>(
      conn,
      `SELECT item_uuid, revision FROM vault_items WHERE vault_id = ? AND item_uuid IN (${placeholders})`,
      [vaultId, ...uuids],
    );
    const current = new Map(currentRows.map((r) => [r.item_uuid, r.revision]));

    const out: ItemResult[] = [];
    const changeRows: ChangeValues[] = [];
    // 分桶:写路径全部批量化——逐条 INSERT/UPDATE 每条都是一次隧道往返
    // (~30-300ms),200 条批曾耗时 57s;批量后任意批 ~10 条语句搞定。
    // CAS 安全性:vault 行 FOR UPDATE 已串行化全部写入者(items POST 与
    // rekey),锁内读到的 current revision 即权威,批量写无需再逐行校验。
    const inserts: IncomingItem[] = [];
    const updates: IncomingItem[] = [];
    const deletes: IncomingItem[] = [];
    const purged: PurgedAttachment[] = [];

    for (const item of items) {
      const rev = current.get(item.uuid);
      if (item.op === "upsert") {
        if (rev === undefined) {
          if (item.baseRevision > 0) {
            // 客户端认为存在而服务端无此行 = 已被删除(缺席即删除,§6.6)
            out.push({ uuid: item.uuid, status: "not_found" });
            continue;
          }
          inserts.push(item);
        } else if (rev === item.baseRevision) {
          updates.push(item);
        } else {
          out.push({ uuid: item.uuid, status: "conflict" });
        }
      } else if (rev === undefined) {
        // 删除幂等:行已不在(早被删),视为达成
        out.push({ uuid: item.uuid, status: "ok" });
      } else if (rev === item.baseRevision) {
        deletes.push(item);
      } else {
        out.push({ uuid: item.uuid, status: "conflict" });
      }
    }

    if (vaultRows[0].item_count + inserts.length - deletes.length > itemsPerVault) {
      throw new ApiError(413, "quota_exceeded");
    }

    if (inserts.length > 0) {
      const values = inserts.map(() => "(?, ?, ?, 1, ?, ?, ?, ?, ?, ?)").join(", ");
      const params: unknown[] = [];
      for (const item of inserts) {
        const sha = item.bodySha256 ?? (await sha256OfBytes(item.body!));
        params.push(vaultId, item.uuid, item.kind, item.body, sha, item.body!.length, item.modifiedMs, now, now);
      }
      await connExec(
        conn,
        `INSERT INTO vault_items (vault_id, item_uuid, kind, revision, body, body_sha256, body_bytes, modified_ms, created_ms, updated_ms) VALUES ${values}`,
        params,
      );
      for (const item of inserts) {
        out.push({ uuid: item.uuid, status: "ok", revision: 1 });
        changeRows.push({ uuid: item.uuid, op: OP_UPSERT, revision: 1 });
      }
    }

    if (updates.length > 0) {
      // 批量换入:行存在则 revision+1 换体(锁内已验 rev===base);
      // 极端下行消失(锁下不可能)则按 base+1 重建,仍一致
      const placeholders = updates.map(() => "(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)").join(", ");
      const params: unknown[] = [];
      for (const item of updates) {
        const sha = item.bodySha256 ?? (await sha256OfBytes(item.body!));
        params.push(vaultId, item.uuid, item.kind, item.baseRevision + 1, item.body, sha,
          item.body!.length, item.modifiedMs, now, now);
      }
      await connExec(
        conn,
        `INSERT INTO vault_items (vault_id, item_uuid, kind, revision, body, body_sha256, body_bytes, modified_ms, created_ms, updated_ms)
         VALUES ${placeholders}
         ON DUPLICATE KEY UPDATE kind = VALUES(kind), revision = revision + 1, body = VALUES(body),
           body_sha256 = VALUES(body_sha256), body_bytes = VALUES(body_bytes),
           modified_ms = VALUES(modified_ms), updated_ms = VALUES(updated_ms)`,
        params,
      );
      for (const item of updates) {
        out.push({ uuid: item.uuid, status: "ok", revision: item.baseRevision + 1 });
        changeRows.push({ uuid: item.uuid, op: OP_UPSERT, revision: item.baseRevision + 1 });
      }
    }

    if (deletes.length > 0) {
      // 条目行删除 + 其名下附件行同事务删除(R2 blob 事务外滞后删)
      const uuids = deletes.map((d) => d.uuid);
      const placeholders = uuids.map(() => "?").join(", ");
      const atts = await connQuery<{ bytes: number; object_key: string }>(
        conn,
        `SELECT bytes, object_key FROM attachments WHERE vault_id = ? AND card_uuid IN (${placeholders})`,
        [vaultId, ...uuids],
      );
      if (atts.length > 0) {
        for (const a of atts) purged.push({ bytes: a.bytes, objectKey: a.object_key });
        await connExec(
          conn,
          `DELETE FROM attachments WHERE vault_id = ? AND card_uuid IN (${placeholders})`,
          [vaultId, ...uuids],
        );
      }
      await connExec(
        conn,
        `DELETE FROM vault_items WHERE vault_id = ? AND item_uuid IN (${placeholders})`,
        [vaultId, ...uuids],
      );
      for (const item of deletes) {
        out.push({ uuid: item.uuid, status: "ok" });
        changeRows.push({ uuid: item.uuid, op: OP_PURGE, revision: item.baseRevision + 1 });
      }
    }

    const insertCount = inserts.length;
    const deleteCount = deletes.length;

    let newHeadSeq: number | null = null;
    if (changeRows.length > 0) {
      const values = changeRows.map(() => "(?, ?, ?, ?, ?, ?)").join(", ");
      const params: unknown[] = [];
      for (const c of changeRows) params.push(vaultId, c.uuid, c.op, c.revision, auth.sessionId, now);
      const inserted = await connExec(
        conn,
        `INSERT INTO item_changes (vault_id, item_uuid, op, revision, session_id, created_ms) VALUES ${values}`,
        params,
      );
      // 本批最大 seq:多行 INSERT 的自增值连续(Hyperdrive 中转下 UPDATE 内
      // 子查询看不到同事务先前的 INSERT,不能回读 MAX(seq),只能由 insertId 推算)
      newHeadSeq = inserted.insertId + changeRows.length - 1;
    }
    const attachDelta = purged.reduce((sum, a) => sum + a.bytes, 0);
    await connExec(
      conn,
      `UPDATE vaults SET item_count = item_count + ?, attach_bytes = attach_bytes - ?, updated_ms = ?,
         head_seq = GREATEST(head_seq, ?)
       WHERE vault_id = ?`,
      [insertCount - deleteCount, attachDelta, now, newHeadSeq ?? 0, vaultId],
    );

    // 冲突/缺席的补充信息(现行行密文 / 删除佐证)在锁内取,保证一致
    await fillConflictDetails(conn, vaultId, out);
    return { results: out, purgedAttachments: purged };
  });

  // R2 附件 blob 滞后删除(幂等;失败由 cron 孤儿清扫兜底)
  for (const a of purgedAttachments) {
    await env.VAULTS.delete(a.objectKey).catch(() => undefined);
  }

  await audit(
    env,
    "items_post",
    { userId: auth.user.id, vaultId },
    {
      n: items.length,
      ok: results.filter((r) => r.status === "ok").length,
      conflict: results.filter((r) => r.status === "conflict").length,
      notFound: results.filter((r) => r.status === "not_found").length,
    },
  );
  return json({ results });
}

/// 冲突条目附现行行(端上 mtime 决胜合并用);缺席条目附删除佐证
/// (保留期内的 purge 日志:deletedAt/seq;无佐证亦合法,端上直接丢弃)。
async function fillConflictDetails(
  conn: Parameters<Parameters<typeof tx>[1]>[0],
  vaultId: string,
  out: ItemResult[],
): Promise<void> {
  const conflicts = out.filter((r) => r.status === "conflict").map((r) => r.uuid);
  if (conflicts.length > 0) {
    const placeholders = conflicts.map(() => "?").join(", ");
    const rows = await connQuery<{ item_uuid: string; revision: number; body: Uint8Array }>(
      conn,
      `SELECT item_uuid, revision, body FROM vault_items WHERE vault_id = ? AND item_uuid IN (${placeholders})`,
      [vaultId, ...conflicts],
    );
    const byUuid = new Map(rows.map((r) => [r.item_uuid, r]));
    for (const r of out) {
      if (r.status !== "conflict") continue;
      const row = byUuid.get(r.uuid);
      if (row) r.current = { revision: row.revision, bodyB64: bytesToB64(row.body) };
    }
  }
  const missing = out.filter((r) => r.status === "not_found").map((r) => r.uuid);
  if (missing.length > 0) {
    const placeholders = missing.map(() => "?").join(", ");
    const rows = await connQuery<{ item_uuid: string; created_ms: number; seq: number }>(
      conn,
      `SELECT item_uuid, created_ms, seq FROM item_changes WHERE vault_id = ? AND op = ${OP_PURGE} AND item_uuid IN (${placeholders}) ORDER BY seq DESC`,
      [vaultId, ...missing],
    );
    const seen = new Set<string>();
    for (const r of rows) {
      if (seen.has(r.item_uuid)) continue;
      seen.add(r.item_uuid);
      const target = out.find((o) => o.uuid === r.item_uuid && o.status === "not_found");
      if (target) {
        target.deletedAt = r.created_ms;
        target.seq = r.seq;
      }
    }
  }
}

interface ChangeRow {
  seq: number;
  item_uuid: string;
  op: number;
  revision: number;
  created_ms: number;
}

interface ItemRow {
  item_uuid: string;
  kind: number;
  revision: number;
  body: Uint8Array;
  body_sha256: string;
  modified_ms: number;
  updated_ms: number;
}

/// GET /v2/vaults/{id}/changes?since=&limit= —— 游标增量下行(§6.3)。
/// 行已被删除(JOIN 不到)的变更以 deleted 标记返回;游标落后越过保留
/// 地板返回 410 cursor_expired(客户端走全量重建)。
export async function handleChangesGet(
  env: Env,
  request: Request,
  auth: AuthContext,
  vaultId: string,
): Promise<Response> {
  const vault = await loadVault(env, auth.user.id, vaultId);
  const url = new URL(request.url);
  const since = parseUint(url.searchParams.get("since"));
  if (since === null) throw new ApiError(400, "bad_request");
  const limitRaw = parseUint(url.searchParams.get("limit"));
  const limit = limitRaw === null ? 200 : Math.min(limitRaw, 500);
  if (since < vault.changes_floor_seq) throw new ApiError(410, "cursor_expired");

  const rows = await q<ChangeRow>(
    env,
    "SELECT seq, item_uuid, op, revision, created_ms FROM item_changes WHERE vault_id = ? AND seq > ? ORDER BY seq ASC LIMIT ?",
    [vaultId, since, limit],
  );

  const changes: Record<string, unknown>[] = [];
  const liveUuids = rows.filter((r) => r.op === OP_UPSERT).map((r) => r.item_uuid);
  const live = new Map<string, ItemRow>();
  if (liveUuids.length > 0) {
    const placeholders = liveUuids.map(() => "?").join(", ");
    const itemRows = await q<ItemRow>(
      env,
      `SELECT item_uuid, kind, revision, body, body_sha256, modified_ms, updated_ms FROM vault_items WHERE vault_id = ? AND item_uuid IN (${placeholders})`,
      [vaultId, ...liveUuids],
    );
    for (const r of itemRows) live.set(r.item_uuid, r);
  }
  for (const r of rows) {
    const entry: Record<string, unknown> = {
      seq: r.seq,
      uuid: r.item_uuid,
      op: r.op === OP_UPSERT ? "upsert" : r.op === OP_PURGE ? "purge" : "rekey",
      revision: r.revision,
    };
    if (r.op === OP_UPSERT) {
      const item = live.get(r.item_uuid);
      if (item) {
        entry.revision = item.revision;
        entry.bodyB64 = bytesToB64(item.body);
        entry.sha256 = item.body_sha256;
        entry.kind = item.kind;
        entry.modifiedMs = item.modified_ms;
      } else {
        // 行已被后续删除:以删除标记返回(客户端按缺席即删除收敛)
        entry.deleted = true;
      }
    } else if (r.op === OP_PURGE) {
      entry.deleted = true;
    }
    changes.push(entry);
  }
  return json({ headSeq: vault.head_seq, changes });
}

/// GET /v2/vaults/{id}/items?cursorMs=&cursorUuid=&limit= —— 全量重建分页
/// (§6.3 快照+差量:先记 headSeq,分页拉平后增量补差)。
export async function handleItemsList(
  env: Env,
  request: Request,
  auth: AuthContext,
  vaultId: string,
): Promise<Response> {
  const vault = await loadVault(env, auth.user.id, vaultId);
  const url = new URL(request.url);
  const cursorMs = parseUint(url.searchParams.get("cursorMs")) ?? 0;
  const cursorUuid = url.searchParams.get("cursorUuid") ?? "";
  const limitRaw = parseUint(url.searchParams.get("limit"));
  const limit = limitRaw === null ? 500 : Math.min(limitRaw, 500);

  const rows = await q<ItemRow>(
    env,
    "SELECT item_uuid, kind, revision, body, body_sha256, modified_ms, updated_ms FROM vault_items WHERE vault_id = ? AND (updated_ms > ? OR (updated_ms = ? AND item_uuid > ?)) ORDER BY updated_ms ASC, item_uuid ASC LIMIT ?",
    [vaultId, cursorMs, cursorMs, cursorUuid, limit],
  );
  const items = rows.map((r) => ({
    uuid: r.item_uuid,
    kind: r.kind,
    revision: r.revision,
    bodyB64: bytesToB64(r.body),
    sha256: r.body_sha256,
    modifiedMs: r.modified_ms,
  }));
  const last = rows[rows.length - 1];
  const nextCursor =
    rows.length === limit && last ? { ms: Number(last.updated_ms), uuid: last.item_uuid } : null;
  return json({ items, nextCursor, headSeq: vault.head_seq });
}

function parseUint(input: string | null): number | null {
  if (input === null || !/^\d+$/.test(input)) return null;
  const n = Number(input);
  return Number.isSafeInteger(n) ? n : null;
}
