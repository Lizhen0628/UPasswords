import {
    getVaultChanges,
    getVaultEnvelope,
    getVaultSeq,
    isValidRelayItemRow,
    listVaultItems,
    RelayApiError,
    type RelayChange,
    type RelayItemRow,
} from "../api/relay.js";
import type { CacheScope, EncryptedCache, EncryptedSnapshot } from "../storage/encrypted-cache.js";
import {
    parseEncryptedSyncQuarantineItems,
    type EncryptedSyncQuarantineItem,
    type SyncQuarantineIdentity,
    type SyncQuarantineReason,
} from "../core/sync-quarantine.js";

/** 同步验证、会话或分页边界失败的机器可识别错误。 */
export class VaultSyncError extends Error {
    constructor(public readonly code: string) {
        super(`vault sync failed: ${code}`);
        this.name = "VaultSyncError";
    }
}

/** 同步所需的账户、密文缓存及会话校验依赖，解密验证由调用方注入。 */
export interface SynchronizeVaultOptions {
    token: string;
    scope: CacheScope;
    cache: EncryptedCache;
    keyVersion?: number;
    /** 每个异步边界检查账户、库和解锁代次；失效时必须抛错。 */
    validate: () => Promise<void>;
    /** 缓存提交前逐行解密并验证；可将认证/格式失败作为隔离候选返回。 */
    verifyRows: (rows: RelayItemRow[]) => Promise<RowVerificationFailure[] | void>;
    /** 使用后台解锁会话的 VEK 加密隔离载荷，不把密钥传给弹窗。 */
    sealQuarantine?: (identity: SyncQuarantineIdentity, row: RelayItemRow) => Promise<string>;
}

export interface RowVerificationFailure {
    uuid: string;
    reason: SyncQuarantineReason;
}

interface SyncResult {
    snapshot: EncryptedSnapshot;
    changedRows: RelayItemRow[];
    deletedIds: string[];
    rebuilt: boolean;
    changedCount: number;
    quarantinedCount: number;
}

interface RowProvenance {
    source: "change" | "snapshot";
    sequence: number | null;
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
    const { token, scope, cache, validate, verifyRows, sealQuarantine } = options;
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
            const provenance = new Map<string, RowProvenance>();
            let cursor = rebuilt ? initialHead : cached?.cursor ?? initialHead;
            try {
                stage = rebuilt ? "snapshot" : "changes";
                rows = rebuilt
                    ? await fetchFullSnapshot(token, scope.vaultId, validate, provenance)
                    : new Map((cached?.rows ?? []).map((row) => [row.uuid.toLowerCase(), row]));
                cursor = await drainChanges(
                    token, scope.vaultId, cursor, validate, rows, provenance,
                    initial.passwordVersion, rebuilt,
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
            const oldRows = new Map((cached?.rows ?? []).map((row) => [row.uuid.toLowerCase(), row]));
            const previousQuarantines = cached?.quarantinedItems ?? [];
            const quarantinesByID = new Map(previousQuarantines.map(item => [item.id, item]));
            const candidateRows = [...rows.values()].sort((a, b) => a.uuid.localeCompare(b.uuid));
            const candidateChanges = changedRowsFor(candidateRows, oldRows, rebuilt);
            // Rebuilds always authenticate the complete final snapshot, including unchanged rows.
            const fallbackRows: RelayItemRow[] = [];
            if (candidateChanges.length) {
                stage = "verify";
                const failures = await checked(validate, () => verifyRows(candidateChanges)) ?? [];
                const failureByUUID = new Map<string, SyncQuarantineReason>();
                for (const failure of failures) {
                    if (!failure || typeof failure.uuid !== "string"
                        || (failure.reason !== "authenticationFailed" && failure.reason !== "unsupportedFormat")) {
                        throw new VaultSyncError("invalid_row_verification_result");
                    }
                    const uuid = failure.uuid.toLowerCase();
                    if (!rows.has(uuid) || failureByUUID.has(uuid)) {
                        throw new VaultSyncError("invalid_row_verification_result");
                    }
                    failureByUUID.set(uuid, failure.reason);
                }
                for (const [uuid, reason] of failureByUUID) {
                    const row = rows.get(uuid);
                    const source = provenance.get(uuid);
                    if (!row || !source) throw new VaultSyncError("missing_quarantine_source");
                    if (!sealQuarantine) throw new VaultSyncError("quarantine_unavailable");
                    const identity: SyncQuarantineIdentity = {
                        id: source.source === "change"
                            ? `change:${source.sequence}`
                            : `snapshot:${row.uuid.toLowerCase()}:${row.revision}`,
                        uuid: row.uuid,
                        revision: row.revision,
                        source: source.source,
                        sequence: source.sequence,
                        reason,
                        capturedAt: Date.now(),
                    };
                    if (!quarantinesByID.has(identity.id)) {
                        const encryptedPayloadB64 = await checked(validate, () => sealQuarantine(identity, row));
                        const [quarantine] = parseEncryptedSyncQuarantineItems([
                            { ...identity, encryptedPayloadB64 },
                        ]);
                        quarantinesByID.set(identity.id, quarantine);
                    }
                    const previous = oldRows.get(uuid);
                    if (previous) {
                        rows.set(uuid, previous);
                        if (rebuilt) fallbackRows.push(previous);
                    } else {
                        rows.delete(uuid);
                    }
                    provenance.delete(uuid);
                    console.warn(`[upw] row isolated uuid=${uuid} reason=${reason}`);
                }
                if (fallbackRows.length) {
                    const fallbackFailures = await checked(validate, () => verifyRows(fallbackRows)) ?? [];
                    if (fallbackFailures.length) throw new VaultSyncError("cached_row_unreadable");
                }
            }
            const nextRows = [...rows.values()].sort((a, b) => a.uuid.localeCompare(b.uuid));
            const differences = nextRows.filter((row) => {
                const previous = oldRows.get(row.uuid.toLowerCase());
                return !previous || !sameRow(previous, row);
            });
            const deletedIds = [...oldRows.keys()].filter((uuid) => !rows.has(uuid));
            const changedRows = rebuilt ? nextRows : differences;
            const quarantinedItems = [...quarantinesByID.values()].sort((a, b) => a.id.localeCompare(b.id));
            const quarantinesChanged = JSON.stringify(quarantinedItems) !== JSON.stringify(previousQuarantines);
            const unchanged = cached !== null && !rebuilt && differences.length === 0
                && deletedIds.length === 0 && cursor === cached.cursor && envelope === cached.envelope
                && !quarantinesChanged;
            await validate();
            if (unchanged) {
                console.info(`[upw] vault sync unchanged elapsedMs=${Date.now() - startedAt}`);
                return {
                    snapshot: cached, changedRows: [], deletedIds: [], rebuilt: false,
                    changedCount: 0, quarantinedCount: 0,
                };
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
                quarantinedItems,
            }, expectedVersion);
            const changedCount = differences.length + deletedIds.length;
            const priorQuarantineIDs = new Set(previousQuarantines.map(item => item.id));
            const quarantinedCount = quarantinedItems.filter(item => !priorQuarantineIDs.has(item.id)).length;
            console.info(`[upw] vault sync completed rebuilt=${rebuilt} rows=${changedRows.length} deleted=${deletedIds.length} elapsedMs=${Date.now() - startedAt}`);
            return { snapshot, changedRows, deletedIds, rebuilt, changedCount, quarantinedCount };
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
    provenance: Map<string, RowProvenance>,
): Promise<Map<string, RelayItemRow>> {
    const rows = new Map<string, RelayItemRow>();
    let cursor: { ms: number; uuid: string } | null = null;
    for (let page = 0; page < MAX_SNAPSHOT_PAGES; page++) {
        const result = await checked(validate, () => listVaultItems(token, vaultId, cursor));
        for (const row of result.items) {
            const key = row.uuid.toLowerCase();
            const previous = rows.get(key);
            if (!previous || row.revision > previous.revision) {
                rows.set(key, row);
                provenance.set(key, { source: "snapshot", sequence: null });
            }
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
    provenance: Map<string, RowProvenance>,
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
            if (change.op === "resolve") {
                const resolved = applyResolutionChange(rows, change);
                provenance.delete(change.uuid.toLowerCase());
                if (change.resolvedItemUuid) provenance.delete(change.resolvedItemUuid.toLowerCase());
                if (resolved) provenance.set(resolved.uuid.toLowerCase(), {
                    source: "change", sequence: change.seq,
                });
                continue;
            }
            const key = change.uuid.toLowerCase();
            if (change.op === "purge" || change.deleted) {
                rows.delete(key);
                provenance.delete(key);
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
            if (!previous || row.revision > previous.revision) {
                rows.set(key, row);
                provenance.set(key, { source: "change", sequence: change.seq });
            }
            else if (row.revision === previous.revision && !sameRow(previous, row)) {
                throw new VaultSyncError("inconsistent_revision");
            }
        }
        if (result.changes.length < CHANGE_PAGE_SIZE) return cursor;
    }
    throw new VaultSyncError("too_many_change_pages");
}

/**
 * Apply the server's atomic resolution event without treating it as an ordinary upsert.
 * A restore may move the live content to a new UUID, so both identities must be updated
 * before the cursor is committed.
 */
function applyResolutionChange(
    rows: Map<string, RelayItemRow>,
    change: RelayChange,
): RelayItemRow | null {
    rows.delete(change.uuid.toLowerCase());
    if (change.winnerOp === "delete" || change.deleted === true) {
        if (change.resolvedItemUuid) rows.delete(change.resolvedItemUuid.toLowerCase());
        return null;
    }
    if (!change.resolvedItemUuid || change.resolvedRevision === undefined
        || change.kind === undefined || !change.bodyB64 || change.modifiedMs === undefined) {
        throw new VaultSyncError("incomplete_resolution");
    }
    const row: RelayItemRow = {
        uuid: change.resolvedItemUuid,
        kind: change.kind,
        revision: change.resolvedRevision,
        bodyB64: change.bodyB64,
        modifiedMs: change.modifiedMs,
    };
    if (!isValidRelayItemRow(row)) throw new VaultSyncError("incomplete_resolution");
    const key = row.uuid.toLowerCase();
    const previous = rows.get(key);
    if (previous && previous.revision > row.revision) {
        throw new VaultSyncError("inconsistent_resolution");
    }
    if (previous && previous.revision === row.revision && !sameRow(previous, row)) {
        throw new VaultSyncError("inconsistent_resolution");
    }
    rows.set(key, row);
    return row;
}

function changedRowsFor(
    rows: RelayItemRow[],
    oldRows: Map<string, RelayItemRow>,
    rebuilt: boolean,
): RelayItemRow[] {
    if (rebuilt) return rows;
    return rows.filter(row => {
        const previous = oldRows.get(row.uuid.toLowerCase());
        return !previous || !sameRow(previous, row);
    });
}

/** Reopens locally VEK-protected rows after a client gains support for their format. */
export async function retryQuarantinedRows(options: {
    quarantinedItems: EncryptedSyncQuarantineItem[];
    rows: RelayItemRow[];
    openQuarantine: (item: EncryptedSyncQuarantineItem) => Promise<RelayItemRow>;
    verifyRows: (rows: RelayItemRow[]) => Promise<RowVerificationFailure[] | void>;
}): Promise<{ rows: RelayItemRow[]; quarantinedItems: EncryptedSyncQuarantineItem[]; restoredRows: RelayItemRow[]; recoveredCount: number }> {
    const rowsByUUID = new Map(options.rows.map(row => [row.uuid.toLowerCase(), row]));
    const remaining = new Map(options.quarantinedItems.map(item => [item.id, item]));
    const restoredRows: RelayItemRow[] = [];
    for (const item of options.quarantinedItems) {
        let row: RelayItemRow;
        try {
            row = await options.openQuarantine(item);
        } catch (error) {
            if (error instanceof Error && error.message === "quarantine_decrypt_failed") continue;
            throw error;
        }
        if (!isValidRelayItemRow(row) || row.uuid.toLowerCase() !== item.uuid.toLowerCase()
            || row.revision !== item.revision) {
            continue;
        }
        const failures = await options.verifyRows([row]) ?? [];
        if (failures.length) continue;
        const current = rowsByUUID.get(row.uuid.toLowerCase());
        if (current && current.revision === row.revision && !sameRow(current, row)) continue;
        if (!current || current.revision < row.revision) {
            rowsByUUID.set(row.uuid.toLowerCase(), row);
            restoredRows.push(row);
        }
        remaining.delete(item.id);
    }
    return {
        rows: [...rowsByUUID.values()].sort((a, b) => a.uuid.localeCompare(b.uuid)),
        quarantinedItems: [...remaining.values()].sort((a, b) => a.id.localeCompare(b.id)),
        restoredRows,
        recoveredCount: options.quarantinedItems.length - remaining.size,
    };
}
