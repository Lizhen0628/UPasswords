import {
    getVaultChanges,
    getVaultEnvelope,
    getVaultSeq,
    isValidRelayItemRow,
    listVaultItems,
    RelayApiError,
    type RelayItemRow,
} from "../api/relay.js";
import type { CacheScope, EncryptedCache, EncryptedSnapshot } from "../storage/encrypted-cache.js";

export class VaultSyncError extends Error {
    constructor(public readonly code: string) {
        super(`vault sync failed: ${code}`);
        this.name = "VaultSyncError";
    }
}

export interface SynchronizeVaultOptions {
    token: string;
    scope: CacheScope;
    cache: EncryptedCache;
    keyVersion?: number;
    validate: () => Promise<void>;
    verifyRows: (rows: RelayItemRow[]) => Promise<void>;
}

interface SyncResult {
    snapshot: EncryptedSnapshot;
    changedRows: RelayItemRow[];
    deletedIds: string[];
    rebuilt: boolean;
    changedCount: number;
}

const MAX_SNAPSHOT_PAGES = 200;
const MAX_CHANGE_PAGES = 500;
const CHANGE_PAGE_SIZE = 200;
const MAX_RESTARTS = 2;

function sameRow(left: RelayItemRow, right: RelayItemRow): boolean {
    return left.revision === right.revision && left.bodyB64 === right.bodyB64
        && left.kind === right.kind && left.modifiedMs === right.modifiedMs;
}

function cursorExpired(error: unknown): boolean {
    return error instanceof RelayApiError && error.status === 410 && error.code === "cursor_expired";
}

/** 失败诊断摘要:只含错误类型/状态/阶段,不含令牌与密文。 */
function describeSyncError(error: unknown): string {
    if (error instanceof RelayApiError) return `relay=${error.status}:${error.code}`;
    if (error instanceof VaultSyncError) return `sync=${error.code}`;
    if (error instanceof Error) return `error=${error.name}`;
    return "error=unknown";
}

/** All network/decryption work stays outside the single atomic cache transaction. */
export async function synchronizeVault(options: SynchronizeVaultOptions): Promise<SyncResult> {
    const { token, scope, cache, validate, verifyRows } = options;
    const startedAt = Date.now();
    let stage = "cache-read";
    console.info("[upw] vault sync started");
    try {
        const initialEpoch = await checked(validate, () => cache.getEpoch(scope));
        const cached = await checked(validate, () => cache.read(scope));
        if (cached && cached.accountEpoch !== initialEpoch) throw new VaultSyncError("account_epoch_mismatch");
        // Both CAS and epoch are captured before network work and remain fixed across retries.
        const expectedVersion = cached?.version ?? null;
        let forceRebuild = false;
        for (let attempt = 0; attempt <= MAX_RESTARTS; attempt++) {
            stage = "seq";
            const initial = await checked(validate, () => getVaultSeq(token, scope.vaultId));
            const expectedKeyVersion = options.keyVersion ?? cached?.passwordVersion;
            if (expectedKeyVersion !== undefined && expectedKeyVersion !== initial.passwordVersion) {
                throw new VaultSyncError("password_changed");
            }
            const rebuilt = cached === null || forceRebuild
                || cached.passwordVersion !== initial.passwordVersion;
            let envelope = cached?.envelope;
            let initialHead = initial.headSeq;
            if (rebuilt) {
                stage = "envelope";
                const detail = await checked(validate, () => getVaultEnvelope(token, scope.vaultId));
                if (detail.meta.vaultId !== scope.vaultId) throw new VaultSyncError("bad_vault_response");
                if (detail.meta.passwordVersion !== initial.passwordVersion) {
                    if (expectedKeyVersion !== undefined) throw new VaultSyncError("password_changed");
                    if (attempt === MAX_RESTARTS) throw new VaultSyncError("sync_incomplete");
                    continue;
                }
                if (!detail.envelope) throw new VaultSyncError("missing_envelope");
                envelope = detail.envelope;
                // Start from the earlier head, never a page's later high-water mark.
                initialHead = Math.min(initialHead, detail.meta.headSeq);
            }
            if (!envelope) throw new VaultSyncError("missing_envelope");
            let rows: Map<string, RelayItemRow>;
            let cursor = rebuilt ? initialHead : cached?.cursor ?? initialHead;
            try {
                stage = rebuilt ? "snapshot" : "changes";
                rows = rebuilt
                    ? await fetchFullSnapshot(token, scope.vaultId, validate)
                    : new Map((cached?.rows ?? []).map((row) => [row.uuid.toLowerCase(), row]));
                cursor = await drainChanges(
                    token, scope.vaultId, cursor, validate, rows, initial.passwordVersion, rebuilt,
                );
            } catch (error) {
                if (!cursorExpired(error)) throw error;
                forceRebuild = true;
                console.warn("[upw] vault sync cursor expired; rebuilding");
                if (attempt === MAX_RESTARTS) throw new VaultSyncError("sync_incomplete");
                continue;
            }
            stage = "final-seq";
            const final = await checked(validate, () => getVaultSeq(token, scope.vaultId));
            if (final.passwordVersion !== initial.passwordVersion) {
                throw new VaultSyncError("password_changed");
            }
            if (final.headSeq !== cursor) {
                if (attempt === MAX_RESTARTS) throw new VaultSyncError("sync_incomplete");
                continue;
            }
            const nextRows = [...rows.values()].sort((a, b) => a.uuid.localeCompare(b.uuid));
            const oldRows = new Map((cached?.rows ?? []).map((row) => [row.uuid.toLowerCase(), row]));
            const differences = nextRows.filter((row) => {
                const previous = oldRows.get(row.uuid.toLowerCase());
                return !previous || !sameRow(previous, row);
            });
            const deletedIds = [...oldRows.keys()].filter((uuid) => !rows.has(uuid));
            const changedRows = rebuilt ? nextRows : differences;
            // Rebuilds always authenticate the complete final snapshot, including unchanged rows.
            if (changedRows.length) {
                stage = "verify";
                await checked(validate, () => verifyRows(changedRows));
            }
            const unchanged = cached !== null && !rebuilt && differences.length === 0
                && deletedIds.length === 0 && cursor === cached.cursor && envelope === cached.envelope;
            await validate();
            if (unchanged) {
                console.info(`[upw] vault sync unchanged elapsedMs=${Date.now() - startedAt}`);
                return { snapshot: cached, changedRows: [], deletedIds: [], rebuilt: false, changedCount: 0 };
            }
            // No post-commit validator: the caller must receive the persisted result before invalidating UI.
            stage = "commit";
            const snapshot = await cache.commit({
                scope,
                envelope,
                passwordVersion: initial.passwordVersion,
                cursor,
                accountEpoch: initialEpoch,
                rows: nextRows,
            }, expectedVersion);
            const changedCount = differences.length + deletedIds.length;
            console.info(`[upw] vault sync completed rebuilt=${rebuilt} rows=${changedRows.length} deleted=${deletedIds.length} elapsedMs=${Date.now() - startedAt}`);
            return { snapshot, changedRows, deletedIds, rebuilt, changedCount };
        }
        throw new VaultSyncError("sync_incomplete");
    } catch (error) {
        console.warn(`[upw] vault sync failed stage=${stage} elapsedMs=${Date.now() - startedAt} ${describeSyncError(error)}`);
        throw error;
    }
}

async function checked<T>(validate: () => Promise<void>, operation: () => Promise<T>): Promise<T> {
    await validate();
    const result = await operation();
    await validate();
    return result;
}

async function fetchFullSnapshot(
    token: string,
    vaultId: string,
    validate: () => Promise<void>,
): Promise<Map<string, RelayItemRow>> {
    const rows = new Map<string, RelayItemRow>();
    let cursor: { ms: number; uuid: string } | null = null;
    for (let page = 0; page < MAX_SNAPSHOT_PAGES; page++) {
        const result = await checked(validate, () => listVaultItems(token, vaultId, cursor));
        for (const row of result.items) {
            const key = row.uuid.toLowerCase();
            const previous = rows.get(key);
            if (!previous || row.revision > previous.revision) rows.set(key, row);
            else if (row.revision === previous.revision && !sameRow(previous, row)) {
                throw new VaultSyncError("inconsistent_revision");
            }
        }
        if (!result.nextCursor) return rows;
        const next = result.nextCursor;
        if (!result.items.length || cursor && (next.ms < cursor.ms
            || next.ms === cursor.ms && next.uuid <= cursor.uuid)) {
            throw new VaultSyncError("bad_snapshot_cursor");
        }
        cursor = next;
    }
    throw new VaultSyncError("too_many_snapshot_pages");
}

async function drainChanges(
    token: string,
    vaultId: string,
    startingCursor: number,
    validate: () => Promise<void>,
    rows: Map<string, RelayItemRow>,
    passwordVersion: number,
    rebuilt: boolean,
): Promise<number> {
    let cursor = startingCursor;
    for (let page = 0; page < MAX_CHANGE_PAGES; page++) {
        const result = await checked(validate, () => getVaultChanges(token, vaultId, cursor, CHANGE_PAGE_SIZE));
        for (const change of result.changes) {
            cursor = change.seq;
            if (change.op === "rekey") {
                if (change.revision > passwordVersion || !rebuilt) throw new VaultSyncError("password_changed");
                continue;
            }
            const key = change.uuid.toLowerCase();
            if (change.op === "purge" || change.deleted) {
                rows.delete(key);
                continue;
            }
            const row = {
                uuid: change.uuid,
                revision: change.revision,
                kind: change.kind,
                bodyB64: change.bodyB64,
                modifiedMs: change.modifiedMs,
            };
            if (!isValidRelayItemRow(row)) throw new VaultSyncError("incomplete_upsert");
            const previous = rows.get(key);
            if (!previous || row.revision > previous.revision) rows.set(key, row);
            else if (row.revision === previous.revision && !sameRow(previous, row)) {
                throw new VaultSyncError("inconsistent_revision");
            }
        }
        if (result.changes.length < CHANGE_PAGE_SIZE) return cursor;
    }
    throw new VaultSyncError("too_many_change_pages");
}
