// 每日 cron 维护:注销到期清除、变更日志保留 + 地板推进、rekey 过期清理、
// 附件孤儿清扫(行 + R2 对象)、staging 清扫、计数对账自愈、审计保留。

import { purgeDeregistered } from "./auth";
import { exec, q } from "./db";
import { deleteR2Prefix, nowMs, numVar, type Env } from "./util";

const DAY_MS = 86_400_000;

/// 变更日志保留(默认 90 天):先推进各库 changes_floor_seq 到保留窗口
/// 下界(拉取端 since < floor → 410 cursor_expired 走全量重建),再删旧行。
async function changesRetention(env: Env): Promise<void> {
  const days = numVar(env, "CHANGE_RETENTION_DAYS", 90);
  const cutoff = nowMs() - days * DAY_MS;
  const floors = await q<{ vault_id: string; m: number }>(
    env,
    "SELECT vault_id, MAX(seq) AS m FROM item_changes WHERE created_ms < ? GROUP BY vault_id",
    [cutoff],
  );
  for (const row of floors) {
    await exec(
      env,
      "UPDATE vaults SET changes_floor_seq = GREATEST(changes_floor_seq, ?) WHERE vault_id = ?",
      [Number(row.m) + 1, row.vault_id],
    );
  }
  const removed = await exec(env, "DELETE FROM item_changes WHERE created_ms < ?", [cutoff]);
  if (removed.affectedRows > 0) {
    console.log(JSON.stringify({ t: Date.now(), action: "cron_changes_retention", removed: removed.affectedRows }));
  }
}

/// 附件孤儿:行在而属主条目行已删(超过 7 天宽限)→ 删行 + 删 R2 对象;
/// R2 对象在而行不在(commit 后崩溃残渣 / 行已删 blob 删失败)→ 删对象。
async function attachmentOrphans(env: Env): Promise<void> {
  const grace = nowMs() - 7 * DAY_MS;
  const orphanRows = await q<{ vault_id: string; attach_uuid: string; object_key: string }>(
    env,
    `SELECT a.vault_id, a.attach_uuid, a.object_key FROM attachments a
     LEFT JOIN vault_items i ON i.vault_id = a.vault_id AND i.item_uuid = a.card_uuid
     WHERE i.item_uuid IS NULL AND a.created_ms < ?`,
    [grace],
  );
  for (const row of orphanRows) {
    await exec(env, "DELETE FROM attachments WHERE vault_id = ? AND attach_uuid = ?", [
      row.vault_id,
      row.attach_uuid,
    ]);
    await env.VAULTS.delete(row.object_key).catch(() => undefined);
  }
  if (orphanRows.length > 0) {
    console.log(JSON.stringify({ t: Date.now(), action: "cron_attach_orphan_rows", n: orphanRows.length }));
  }

  // R2 对象对账:逐库列出 attachments/ 前缀对象,行里没有的删掉
  const vaults = await q<{ vault_id: string }>(env, "SELECT vault_id FROM vaults", []);
  for (const v of vaults) {
    const prefix = `vaults/${v.vault_id}/attachments/`;
    const known = new Set(
      (await q<{ object_key: string }>(env, "SELECT object_key FROM attachments WHERE vault_id = ?", [
        v.vault_id,
      ])).map((r) => r.object_key),
    );
    let cursor: string | undefined;
    do {
      const listing = await env.VAULTS.list({ prefix, cursor });
      for (const item of listing.objects) {
        if (item.key.includes("/staging/")) continue;
        if (!known.has(item.key)) await env.VAULTS.delete(item.key);
      }
      cursor = listing.truncated ? listing.cursor : undefined;
    } while (cursor);
  }
}

/// 上传暂存清扫:超过 1 天未 commit 的孤儿 staging(中断上传残渣)。
async function sweepStaleStaging(env: Env): Promise<void> {
  const cutoff = Date.now() - DAY_MS;
  let cursor: string | undefined;
  do {
    const listing = await env.VAULTS.list({ prefix: "vaults/", cursor });
    for (const item of listing.objects) {
      if (item.key.includes("/attachments/staging/") && item.uploaded.getTime() < cutoff) {
        await env.VAULTS.delete(item.key);
      }
    }
    cursor = listing.truncated ? listing.cursor : undefined;
  } while (cursor);
}

/// 计数对账自愈:item_count / attach_bytes 以行级实数重算
/// (同事务维护已尽量一致,此处兜底漂移)。
async function reconcileCounters(env: Env): Promise<void> {
  await exec(
    env,
    `UPDATE vaults v SET
       item_count = (SELECT COUNT(*) FROM vault_items i WHERE i.vault_id = v.vault_id),
       attach_bytes = (SELECT COALESCE(SUM(bytes), 0) FROM attachments a WHERE a.vault_id = v.vault_id)`,
  );
  // attach_bytes 不得为负(差量核算的瞬时窗口兜底)
  await exec(env, "UPDATE vaults SET attach_bytes = 0 WHERE attach_bytes < 0");
}

/// 过期 rekey 清理(begin 后发起端崩溃,写路径惰性清理之外的兜底)。
async function sweepExpiredRekeys(env: Env): Promise<void> {
  const removed = await exec(env, "DELETE FROM rekeys WHERE expires_ms < ?", [nowMs()]);
  if (removed.affectedRows > 0) {
    console.log(JSON.stringify({ t: Date.now(), action: "cron_rekey_sweep", n: removed.affectedRows }));
  }
}

/// 审计保留 180 天。
async function auditRetention(env: Env): Promise<void> {
  await exec(env, "DELETE FROM audit_log WHERE ts_ms < ?", [nowMs() - 180 * DAY_MS]);
}

/// 旧整库 R2 单对象布局退役清扫:vaults/<vaultId>(无 /attachments/
/// 段的裸键)是遗留库体副本,开发期无数据,直接清掉防残留。
async function sweepLegacyBodyObjects(env: Env): Promise<void> {
  let cursor: string | undefined;
  do {
    const listing = await env.VAULTS.list({ prefix: "vaults/", cursor });
    for (const item of listing.objects) {
      const parts = item.key.split("/");
      if (parts.length === 2 && !item.key.includes("/staging/")) {
        await env.VAULTS.delete(item.key);
      }
    }
    cursor = listing.truncated ? listing.cursor : undefined;
  } while (cursor);
}

export async function runMaintenance(env: Env): Promise<void> {
  await purgeDeregistered(env);
  await sweepExpiredRekeys(env);
  await changesRetention(env);
  await attachmentOrphans(env);
  await sweepStaleStaging(env);
  await reconcileCounters(env);
  await auditRetention(env);
  await sweepLegacyBodyObjects(env);
  console.log(JSON.stringify({ t: Date.now(), action: "cron_done" }));
}
