import { parseAttachmentLedger, type AttachmentLedgerState } from "../core/attachment-download-policy.js";
import { sha256BytesHex } from "../core/crypto.js";
import {
    parseEncryptedSyncQuarantineItems,
    type EncryptedSyncQuarantineItem,
} from "../core/sync-quarantine.js";
import {
    base64ToBytes,
    bytesToBase64,
    RELAY_BASE_URL,
    isValidRelayItemRow,
    type RelayAttachmentVersion,
    type RelayItemRow,
} from "../api/relay.js";

/** 密文缓存隔离身份，由 API origin、账户 ID 与库 ID 共同决定。 */
export interface CacheScope {
    userId: string;
    vaultId: string;
    origin?: string;
}

/** 可持久化的完整密文快照；禁止加入主密码、库密钥或解密片段。 */
export interface EncryptedSnapshot {
    scope: CacheScope;
    envelope: string;
    passwordVersion: number;
    cursor: number;
    version: number;
    accountEpoch: number;
    rows: RelayItemRow[];
    quarantinedItems: EncryptedSyncQuarantineItem[];
}

export type EncryptedSnapshotInput = Omit<EncryptedSnapshot, "version" | "quarantinedItems">
    & Partial<Pick<EncryptedSnapshot, "quarantinedItems">>;

/** Non-secret attachment policy has its own CAS version and shares the account invalidation epoch. */
export interface StoredAttachmentLedger {
    scope: CacheScope;
    accountEpoch: number;
    version: number;
    state: AttachmentLedgerState;
}

export interface AttachmentLedgerCommit {
    state: AttachmentLedgerState;
    expectedVersion: number | null;
}

interface StoredAttachmentRow {
    scopeKey: string;
    vaultId: string;
    attachmentId: string;
    contentVersion: string;
    cardUuid: string;
    dekWrapped: string;
    sha256: string;
    bytes: number;
    createdMs: number;
    retiredMs?: number;
}

interface StoredAttachmentContentRow {
    scopeKey: string;
    vaultId: string;
    attachmentId: string;
    contentVersion: string;
    cipherB64: string;
    updatedMs: number;
}

/** 原子密文快照存储；version 防止并发覆盖，accountEpoch 防止登出后旧任务复写。 */
export interface EncryptedCache {
    /** 读取并验证快照；损坏记录应拒绝，不能当作合法空库。 */
    read(scope: CacheScope): Promise<EncryptedSnapshot | null>;
    /** 在同一 IndexedDB 事务内检查预期版本和账户 epoch 后替换整份快照。 */
    commit(
        snapshot: EncryptedSnapshotInput,
        expectedVersion: number | null,
        attachmentLedger?: AttachmentLedgerCommit,
    ): Promise<EncryptedSnapshot>;
    /** Read policy without treating damaged data as a new retry round. */
    readAttachmentLedger(scope: CacheScope): Promise<StoredAttachmentLedger | null>;
    /** Replace cloud-aligned current attachment and version metadata in one transaction. */
    replaceAttachmentVersions(
        scope: CacheScope,
        accountEpoch: number,
        expectedSnapshotVersion: number,
        versions: RelayAttachmentVersion[],
    ): Promise<void>;
    /** Retain one verified encrypted cloud object separately from item-row ciphertext. */
    writeAttachmentContent(
        scope: CacheScope,
        accountEpoch: number,
        expectedSnapshotVersion: number,
        version: RelayAttachmentVersion,
        cipher: Uint8Array,
    ): Promise<void>;
    /** Persist retry/retention without modifying row revisions or the cloud cursor. */
    writeAttachmentLedger(
        input: Omit<StoredAttachmentLedger, "version">, expectedVersion: number | null,
    ): Promise<StoredAttachmentLedger>;
    /** Advance the account epoch while retaining and rebasing its encrypted local copies. */
    preserveAccount(userId: string): Promise<void>;
    /** 删除该账户快照并推进 epoch，使先前在途任务无法提交。 */
    removeAccount(userId: string): Promise<void>;
    /** 获取账户失效代次；应在发起网络工作前捕获。 */
    getEpoch(scope: CacheScope): Promise<number>;
    /** 关闭连接并使此实例停止接受后续数据库工作。 */
    close(): void;
}

const DATABASE_NAME = "upasswords-encrypted-vault-cache";
const DATABASE_VERSION = 3;
const SNAPSHOTS_STORE = "snapshots";
const EPOCHS_STORE = "accountEpochs";
const ATTACHMENT_POLICIES_STORE = "attachmentPolicies";
const VAULTS_STORE = "vaults";
const VAULT_ITEMS_STORE = "vault_items";
const VAULT_PROFILES_STORE = "vault_user_profiles";
const ATTACHMENTS_STORE = "attachments";
const ATTACHMENT_VERSIONS_STORE = "attachment_versions";
const ATTACHMENT_CONTENT_STORE = "attachmentContent";

interface StoredVaultRow {
    scope: CacheScope;
    envelope: string;
    passwordVersion: number;
    cursor: number;
    version: number;
    accountEpoch: number;
    quarantinedItems: EncryptedSyncQuarantineItem[];
}

interface StoredBusinessRow extends RelayItemRow {
    scopeKey: string;
    bodyBytes: number;
    bodySha256: string;
    createdMs: number;
    updatedMs: number;
}

function normalizedOrigin(scope: CacheScope): string {
    const origin = scope.origin ?? new URL(RELAY_BASE_URL).origin;
    try {
        return new URL(origin).origin;
    } catch {
        throw new Error("encrypted_cache_invalid_scope");
    }
}

function storageKey(scope: CacheScope): string {
    return `${normalizedOrigin(scope)}\u0000${scope.userId}\u0000${scope.vaultId}`;
}

function epochKey(scope: CacheScope): string {
    return scope.userId;
}

function businessRowKey(scope: CacheScope, uuid: string): string {
    return `${storageKey(scope)}\u0000${uuid.toLowerCase()}`;
}

function attachmentKey(scope: CacheScope, attachmentID: string): string {
    return `${storageKey(scope)}\u0000${attachmentID.toLowerCase()}`;
}

function attachmentVersionKey(
    scope: CacheScope,
    attachmentID: string,
    contentVersion: string,
): string {
    return `${attachmentKey(scope, attachmentID)}\u0000${contentVersion.toLowerCase()}`;
}

async function businessRowMetadata(
    rows: RelayItemRow[],
): Promise<Map<string, { bodyBytes: number; bodySha256: string }>> {
    return new Map(await Promise.all(rows.map(async row => {
        const cipher = base64ToBytes(row.bodyB64);
        return [row.uuid.toLowerCase(), {
            bodyBytes: cipher.byteLength,
            bodySha256: await sha256BytesHex(cipher),
        }] as const;
    })));
}

function parseStoredVault(value: unknown): StoredVaultRow {
    if (typeof value !== "object" || value === null) throw new Error("encrypted_cache_corrupt");
    const record = value as StoredVaultRow;
    if (!record.scope || typeof record.envelope !== "string" || !record.envelope
        || !Number.isSafeInteger(record.passwordVersion) || record.passwordVersion < 0
        || !Number.isSafeInteger(record.cursor) || record.cursor < 0
        || !Number.isSafeInteger(record.version) || record.version < 1
        || !Number.isSafeInteger(record.accountEpoch) || record.accountEpoch < 0
        || !Array.isArray(record.quarantinedItems)) throw new Error("encrypted_cache_corrupt");
    return {
        scope: {
            userId: record.scope.userId,
            vaultId: record.scope.vaultId,
            origin: normalizedOrigin(record.scope),
        },
        envelope: record.envelope,
        passwordVersion: record.passwordVersion,
        cursor: record.cursor,
        version: record.version,
        accountEpoch: record.accountEpoch,
        quarantinedItems: parseEncryptedSyncQuarantineItems(record.quarantinedItems),
    };
}

async function readBusinessRows(db: IDBDatabase, scope: CacheScope): Promise<RelayItemRow[]> {
    const tx = db.transaction([VAULT_ITEMS_STORE, VAULT_PROFILES_STORE], "readonly");
    const scopeKey = storageKey(scope);
    const [items, profiles] = await Promise.all([
        requestValue(tx.objectStore(VAULT_ITEMS_STORE).getAll()),
        requestValue(tx.objectStore(VAULT_PROFILES_STORE).getAll()),
    ]);
    await transactionDone(tx);
    const seen = new Set<string>();
    return [...items, ...profiles]
        .filter((row): row is StoredBusinessRow => row && row.scopeKey === scopeKey)
        .map(row => ({
            uuid: row.uuid,
            kind: row.kind,
            revision: row.revision,
            bodyB64: row.bodyB64,
            modifiedMs: row.modifiedMs,
        }))
        .filter(row => {
            if (!isValidRelayItemRow(row) || seen.has(row.uuid.toLowerCase())) return false;
            seen.add(row.uuid.toLowerCase());
            return true;
        });
}

function snapshotFrom(value: unknown): EncryptedSnapshot {
    if (typeof value !== "object" || value === null) throw new Error("encrypted_cache_corrupt");
    const record = value as Record<string, unknown>;
    const allowedKeys = new Set([
        "scope", "envelope", "passwordVersion", "cursor", "version", "accountEpoch", "rows", "quarantinedItems",
    ]);
    if (Object.keys(record).some((key) => !allowedKeys.has(key))) throw new Error("encrypted_cache_corrupt");
    const scope = record.scope;
    if (typeof scope !== "object" || scope === null) throw new Error("encrypted_cache_corrupt");
    const storedScope = scope as Record<string, unknown>;
    if (Object.keys(storedScope).some((key) => !["userId", "vaultId", "origin"].includes(key))) {
        throw new Error("encrypted_cache_corrupt");
    }
    if (typeof storedScope.userId !== "string" || !storedScope.userId
        || typeof storedScope.vaultId !== "string" || !storedScope.vaultId
        || typeof record.envelope !== "string" || !record.envelope
        || !Number.isSafeInteger(record.passwordVersion) || (record.passwordVersion as number) < 0
        || !Number.isSafeInteger(record.cursor) || (record.cursor as number) < 0
        || !Number.isSafeInteger(record.version) || (record.version as number) < 1
        || !Number.isSafeInteger(record.accountEpoch) || (record.accountEpoch as number) < 0
        || !Array.isArray(record.rows)) throw new Error("encrypted_cache_corrupt");
    const seen = new Set<string>();
    const rows = record.rows.map((row) => {
        if (!isValidRelayItemRow(row) || seen.has(row.uuid.toLowerCase())) {
            throw new Error("encrypted_cache_corrupt");
        }
        seen.add(row.uuid.toLowerCase());
        return {
            uuid: row.uuid,
            kind: row.kind,
            revision: row.revision,
            bodyB64: row.bodyB64,
            modifiedMs: row.modifiedMs,
        };
    });
    return {
        scope: {
            userId: storedScope.userId,
            vaultId: storedScope.vaultId,
            origin: typeof storedScope.origin === "string"
                ? normalizedOrigin({
                    userId: storedScope.userId,
                    vaultId: storedScope.vaultId,
                    origin: storedScope.origin,
                })
                : new URL(RELAY_BASE_URL).origin,
        },
        envelope: record.envelope,
        passwordVersion: record.passwordVersion as number,
        cursor: record.cursor as number,
        version: record.version as number,
        accountEpoch: record.accountEpoch as number,
        rows,
        quarantinedItems: parseEncryptedSyncQuarantineItems(record.quarantinedItems ?? []),
    };
}

function ledgerFrom(value: unknown, scope: CacheScope): StoredAttachmentLedger {
    if (typeof value !== "object" || value === null) throw new Error("attachment_policy_corrupt");
    const record = value as StoredAttachmentLedger;
    if (Object.keys(record).some(key => !["scope", "accountEpoch", "version", "state"].includes(key))
        || !record.scope || Object.keys(record.scope).some(key => !["userId", "vaultId", "origin"].includes(key))
        || record.scope.userId !== scope.userId || record.scope.vaultId !== scope.vaultId
        || normalizedOrigin(record.scope) !== normalizedOrigin(scope)
        || !Number.isSafeInteger(record.version) || record.version < 1
        || !Number.isSafeInteger(record.accountEpoch) || record.accountEpoch < 0) {
        throw new Error("attachment_policy_corrupt");
    }
    return { scope: { ...record.scope }, accountEpoch: record.accountEpoch,
        version: record.version, state: parseAttachmentLedger(record.state) };
}

function validateLedgerVersion(version: number | null): void {
    if (version !== null && (!Number.isSafeInteger(version) || version < 1 || version >= Number.MAX_SAFE_INTEGER)) {
        throw new Error("attachment_policy_invalid_version");
    }
}

/** IndexedDB cache containing only encrypted row payloads and relay metadata. */
export function createEncryptedCache(factory: IDBFactory = indexedDB): EncryptedCache {
    let closed = false;
    const database = new Promise<IDBDatabase>((resolve, reject) => {
        const request = factory.open(DATABASE_NAME, DATABASE_VERSION);
        request.onupgradeneeded = (event) => {
            const db = request.result;
            if (!db.objectStoreNames.contains(SNAPSHOTS_STORE)) db.createObjectStore(SNAPSHOTS_STORE);
            if (!db.objectStoreNames.contains(EPOCHS_STORE)) db.createObjectStore(EPOCHS_STORE);
            if (!db.objectStoreNames.contains(ATTACHMENT_POLICIES_STORE)) db.createObjectStore(ATTACHMENT_POLICIES_STORE);
            if (!db.objectStoreNames.contains(VAULTS_STORE)) db.createObjectStore(VAULTS_STORE);
            if (!db.objectStoreNames.contains(VAULT_ITEMS_STORE)) db.createObjectStore(VAULT_ITEMS_STORE);
            if (!db.objectStoreNames.contains(VAULT_PROFILES_STORE)) db.createObjectStore(VAULT_PROFILES_STORE);
            if (!db.objectStoreNames.contains(ATTACHMENTS_STORE)) db.createObjectStore(ATTACHMENTS_STORE);
            if (!db.objectStoreNames.contains(ATTACHMENT_VERSIONS_STORE)) db.createObjectStore(ATTACHMENT_VERSIONS_STORE);
            if (!db.objectStoreNames.contains(ATTACHMENT_CONTENT_STORE)) db.createObjectStore(ATTACHMENT_CONTENT_STORE);

            // v2 stored one encrypted snapshot. Split it into the shared
            // business stores during the upgrade transaction; malformed data
            // is left untouched in `snapshots` for recovery diagnostics.
            if (request.transaction && (event as IDBVersionChangeEvent).oldVersion < 3) {
                const vaults = request.transaction.objectStore(VAULTS_STORE);
                const items = request.transaction.objectStore(VAULT_ITEMS_STORE);
                const profiles = request.transaction.objectStore(VAULT_PROFILES_STORE);
                const snapshots = request.transaction.objectStore(SNAPSHOTS_STORE);
                const cursorRequest = snapshots.openCursor();
                cursorRequest.onsuccess = () => {
                    const cursor = cursorRequest.result;
                    if (!cursor) return;
                    try {
                        const snapshot = snapshotFrom(cursor.value);
                        const scope = {
                            userId: snapshot.scope.userId,
                            vaultId: snapshot.scope.vaultId,
                            origin: normalizedOrigin(snapshot.scope),
                        };
                        const key = storageKey(scope);
                        vaults.put({
                            scope,
                            envelope: snapshot.envelope,
                            passwordVersion: snapshot.passwordVersion,
                            cursor: snapshot.cursor,
                            version: snapshot.version,
                            accountEpoch: snapshot.accountEpoch,
                            quarantinedItems: snapshot.quarantinedItems,
                        }, key);
                        for (const row of snapshot.rows) {
                            const target = row.kind === 3 ? profiles : items;
                            const stored: StoredBusinessRow = {
                                ...row,
                                scopeKey: key,
                                bodyBytes: row.bodyB64.length,
                                bodySha256: "legacy",
                                createdMs: row.modifiedMs,
                                updatedMs: row.modifiedMs,
                            };
                            target.put(stored, businessRowKey(scope, row.uuid));
                        }
                    } catch {
                        // Keep the original snapshot. Normal read validation
                        // will report corruption instead of treating it as empty.
                    }
                    cursor.continue();
                };
            }
        };
        request.onsuccess = () => {
            request.result.onversionchange = () => request.result.close();
            resolve(request.result);
        };
        request.onerror = () => reject(request.error ?? new Error("indexeddb_open_failed"));
        request.onblocked = () => reject(new Error("indexeddb_open_blocked"));
    });
    // Observe eager-open failure even before the first cache consumer; operations still reject.
    void database.catch(() => undefined);

    async function read(scope: CacheScope): Promise<EncryptedSnapshot | null> {
        if (closed) throw new Error("cache_closed");
        const db = await database;
        const tx = db.transaction([SNAPSHOTS_STORE, EPOCHS_STORE, VAULTS_STORE, VAULT_ITEMS_STORE, VAULT_PROFILES_STORE], "readonly");
        const done = transactionDone(tx);
        const snapshotRequest = tx.objectStore(SNAPSHOTS_STORE).get(storageKey(scope));
        const vaultRequest = tx.objectStore(VAULTS_STORE).get(storageKey(scope));
        const epochRequest = tx.objectStore(EPOCHS_STORE).get(epochKey(scope));
        const [stored, vaultValue, epochValue] = await Promise.all([
            requestValue(snapshotRequest),
            requestValue(vaultRequest),
            requestValue(epochRequest),
        ]);
        await done;
        const legacySnapshot = stored === undefined ? null : snapshotFrom(stored);
        const epoch = typeof epochValue === "number" ? epochValue : 0;
        if (legacySnapshot && legacySnapshot.accountEpoch !== epoch) return null;
        let snapshot: EncryptedSnapshot | null = vaultValue === undefined
            ? legacySnapshot
            : { ...parseStoredVault(vaultValue), rows: [] };
        if (snapshot === null) return null;
        if (snapshot.accountEpoch !== epoch) return null;
        if (vaultValue !== undefined) {
            const rows = await readBusinessRows(db, scope);
            snapshot.rows = rows;
        }
        if (snapshot.scope.userId !== scope.userId || snapshot.scope.vaultId !== scope.vaultId
            || normalizedOrigin(snapshot.scope) !== normalizedOrigin(scope)) {
            throw new Error("encrypted_cache_corrupt");
        }
        return snapshot;
    }

    async function getEpoch(scope: CacheScope): Promise<number> {
        if (closed) throw new Error("cache_closed");
        const db = await database;
        const tx = db.transaction(EPOCHS_STORE, "readonly");
        const value = await requestValue(tx.objectStore(EPOCHS_STORE).get(epochKey(scope)));
        await transactionDone(tx);
        return typeof value === "number" ? value : 0;
    }

    async function commit(
        input: EncryptedSnapshotInput,
        expectedVersion: number | null,
        attachmentLedger?: AttachmentLedgerCommit,
    ): Promise<EncryptedSnapshot> {
        if (closed) throw new Error("cache_closed");
        if (typeof input.scope.userId !== "string" || !input.scope.userId
            || typeof input.scope.vaultId !== "string" || !input.scope.vaultId
            || typeof input.envelope !== "string" || !input.envelope
            || !Number.isSafeInteger(input.passwordVersion) || input.passwordVersion < 0
            || !Number.isSafeInteger(input.cursor) || input.cursor < 0
            || !Number.isSafeInteger(input.accountEpoch) || input.accountEpoch < 0
            || !Array.isArray(input.rows) || (input.quarantinedItems !== undefined
                && !Array.isArray(input.quarantinedItems)) || (expectedVersion !== null
                && (!Number.isSafeInteger(expectedVersion) || expectedVersion < 1
                    || expectedVersion >= Number.MAX_SAFE_INTEGER))
            || input.scope.userId.includes("\u0000") || input.scope.vaultId.includes("\u0000")) {
            throw new Error("encrypted_cache_invalid_snapshot");
        }
        const policyState = attachmentLedger ? parseAttachmentLedger(attachmentLedger.state) : undefined;
        const quarantinedItems = parseEncryptedSyncQuarantineItems(input.quarantinedItems ?? []);
        if (attachmentLedger) validateLedgerVersion(attachmentLedger.expectedVersion);
        const seen = new Set<string>();
        const rows = input.rows.map((row) => {
            if (!isValidRelayItemRow(row) || seen.has(row.uuid.toLowerCase())) {
                throw new Error("encrypted_cache_invalid_row");
            }
            seen.add(row.uuid.toLowerCase());
            return {
                uuid: row.uuid,
                kind: row.kind,
                revision: row.revision,
                bodyB64: row.bodyB64,
                modifiedMs: row.modifiedMs,
            };
        });
        const safeScope: CacheScope = {
            userId: input.scope.userId,
            vaultId: input.scope.vaultId,
            origin: normalizedOrigin(input.scope),
        };
        const metadataByUUID = await businessRowMetadata(rows);
        const db = await database;
        const tx = db.transaction([
            SNAPSHOTS_STORE,
            EPOCHS_STORE,
            ATTACHMENT_POLICIES_STORE,
            VAULTS_STORE,
            VAULT_ITEMS_STORE,
            VAULT_PROFILES_STORE,
        ], "readwrite");
        const done = transactionDone(tx);
        void done.catch(() => undefined);
        const snapshots = tx.objectStore(SNAPSHOTS_STORE);
        const epochs = tx.objectStore(EPOCHS_STORE);
        const key = storageKey(safeScope);
        const eKey = epochKey(safeScope);
        const policies = tx.objectStore(ATTACHMENT_POLICIES_STORE);
        const vaults = tx.objectStore(VAULTS_STORE);
        const [currentValue, currentEpochValue, policyValue] = await Promise.all([
            requestValue(snapshots.get(key)),
            requestValue(epochs.get(eKey)),
            attachmentLedger ? requestValue(policies.get(key)) : Promise.resolve(undefined),
        ]);
        const current = currentValue === undefined ? undefined : snapshotFrom(currentValue);
        const currentEpoch = typeof currentEpochValue === "number" ? currentEpochValue : 0;
        if (input.accountEpoch !== currentEpoch) {
            tx.abort();
            throw new Error("account_epoch_mismatch");
        }
        if (expectedVersion === null ? current !== undefined : current === undefined
            || current.version !== expectedVersion || current.accountEpoch !== currentEpoch) {
            tx.abort();
            throw new Error("cache_version_conflict");
        }
        let nextPolicy: StoredAttachmentLedger | undefined;
        if (attachmentLedger && policyState) {
            const currentPolicy = policyValue === undefined ? null : ledgerFrom(policyValue, safeScope);
            if ((currentPolicy?.version ?? null) !== attachmentLedger.expectedVersion
                || currentPolicy && currentPolicy.accountEpoch !== currentEpoch) {
                tx.abort();
                throw new Error("attachment_policy_version_conflict");
            }
            nextPolicy = { scope: safeScope, accountEpoch: currentEpoch, state: policyState,
                version: (attachmentLedger.expectedVersion ?? 0) + 1 };
        }
        const next: EncryptedSnapshot = {
            scope: safeScope,
            envelope: input.envelope,
            passwordVersion: input.passwordVersion,
            cursor: input.cursor,
            accountEpoch: input.accountEpoch,
            rows,
            quarantinedItems,
            version: expectedVersion === null ? 1 : expectedVersion + 1,
        };
        await deleteBusinessRowsForScope(tx, safeScope);
        for (const row of rows) {
            const target = row.kind === 3
                ? tx.objectStore(VAULT_PROFILES_STORE)
                : tx.objectStore(VAULT_ITEMS_STORE);
            const stored: StoredBusinessRow = {
                ...row,
                scopeKey: key,
                bodyBytes: metadataByUUID.get(row.uuid.toLowerCase())?.bodyBytes ?? 0,
                bodySha256: metadataByUUID.get(row.uuid.toLowerCase())?.bodySha256 ?? "",
                createdMs: row.modifiedMs,
                updatedMs: row.modifiedMs,
            };
            target.put(stored, businessRowKey(safeScope, row.uuid));
        }
        try {
            vaults.put({
                scope: safeScope,
                envelope: next.envelope,
                passwordVersion: next.passwordVersion,
                cursor: next.cursor,
                version: next.version,
                accountEpoch: next.accountEpoch,
                quarantinedItems: next.quarantinedItems,
            }, key);
            if (nextPolicy) policies.put(nextPolicy, key);
            // Keep the old snapshot as a recovery record, but write it last so
            // an injected snapshot failure aborts the whole transaction.
            snapshots.put(next, key);
        } catch (error) {
            tx.abort();
            throw error;
        }
        await done;
        return next;
    }

    async function readAttachmentLedger(scope: CacheScope): Promise<StoredAttachmentLedger | null> {
        if (closed) throw new Error("cache_closed");
        const db = await database;
        const tx = db.transaction([ATTACHMENT_POLICIES_STORE, EPOCHS_STORE], "readonly");
        const done = transactionDone(tx);
        const [value, epochValue] = await Promise.all([
            requestValue(tx.objectStore(ATTACHMENT_POLICIES_STORE).get(storageKey(scope))),
            requestValue(tx.objectStore(EPOCHS_STORE).get(epochKey(scope))),
        ]);
        await done;
        if (value === undefined) return null;
        const policy = ledgerFrom(value, scope);
        return policy.accountEpoch === (epochValue ?? 0) ? policy : null;
    }

    async function replaceAttachmentVersions(
        scope: CacheScope,
        accountEpoch: number,
        expectedSnapshotVersion: number,
        versions: RelayAttachmentVersion[],
    ): Promise<void> {
        if (closed) throw new Error("cache_closed");
        if (!Array.isArray(versions)) throw new Error("attachment_versions_invalid");
        const identities = new Set<string>();
        const currentIDs = new Set<string>();
        for (const version of versions) {
            const identity = `${version.attachmentId.toLowerCase()}:${version.contentVersion.toLowerCase()}`;
            if (identities.has(identity)
                || version.isCurrent && currentIDs.has(version.attachmentId.toLowerCase())) {
                throw new Error("attachment_versions_invalid");
            }
            identities.add(identity);
            if (version.isCurrent) currentIDs.add(version.attachmentId.toLowerCase());
        }
        const safeScope = {
            userId: scope.userId,
            vaultId: scope.vaultId,
            origin: normalizedOrigin(scope),
        };
        const key = storageKey(safeScope);
        const db = await database;
        const tx = db.transaction([
            EPOCHS_STORE,
            VAULTS_STORE,
            ATTACHMENTS_STORE,
            ATTACHMENT_VERSIONS_STORE,
        ], "readwrite");
        const done = transactionDone(tx);
        void done.catch(() => undefined);
        const [epochValue, vaultValue] = await Promise.all([
            requestValue(tx.objectStore(EPOCHS_STORE).get(epochKey(safeScope))),
            requestValue(tx.objectStore(VAULTS_STORE).get(key)),
        ]);
        if (accountEpoch !== (epochValue ?? 0)
            || (vaultValue as StoredVaultRow | undefined)?.version !== expectedSnapshotVersion) {
            tx.abort();
            throw new Error("attachment_snapshot_version_conflict");
        }
        await Promise.all([
            clearStoreScope(tx, ATTACHMENTS_STORE, key),
            clearStoreScope(tx, ATTACHMENT_VERSIONS_STORE, key),
        ]);
        for (const version of versions) {
            const record: StoredAttachmentRow = {
                scopeKey: key,
                vaultId: safeScope.vaultId,
                attachmentId: version.attachmentId.toLowerCase(),
                contentVersion: version.contentVersion.toLowerCase(),
                cardUuid: version.cardUuid.toLowerCase(),
                dekWrapped: version.dekWrapped,
                sha256: version.sha256.toLowerCase(),
                bytes: version.bytes,
                createdMs: version.createdMs,
                ...(version.retiredMs === undefined ? {} : { retiredMs: version.retiredMs }),
            };
            tx.objectStore(ATTACHMENT_VERSIONS_STORE).put(
                record,
                attachmentVersionKey(safeScope, record.attachmentId, record.contentVersion),
            );
            if (version.isCurrent) {
                tx.objectStore(ATTACHMENTS_STORE).put(
                    record,
                    attachmentKey(safeScope, record.attachmentId),
                );
            }
        }
        await done;
    }

    async function writeAttachmentContent(
        scope: CacheScope,
        accountEpoch: number,
        expectedSnapshotVersion: number,
        version: RelayAttachmentVersion,
        cipher: Uint8Array,
    ): Promise<void> {
        if (closed) throw new Error("cache_closed");
        if (cipher.byteLength !== version.bytes
            || await sha256BytesHex(cipher) !== version.sha256.toLowerCase()) {
            throw new Error("attachment_content_integrity_failure");
        }
        const safeScope = {
            userId: scope.userId,
            vaultId: scope.vaultId,
            origin: normalizedOrigin(scope),
        };
        const key = storageKey(safeScope);
        const db = await database;
        const tx = db.transaction([
            EPOCHS_STORE,
            VAULTS_STORE,
            ATTACHMENT_VERSIONS_STORE,
            ATTACHMENT_CONTENT_STORE,
        ], "readwrite");
        const done = transactionDone(tx);
        void done.catch(() => undefined);
        const [epochValue, vaultValue, metadataValue] = await Promise.all([
            requestValue(tx.objectStore(EPOCHS_STORE).get(epochKey(safeScope))),
            requestValue(tx.objectStore(VAULTS_STORE).get(key)),
            requestValue(tx.objectStore(ATTACHMENT_VERSIONS_STORE).get(
                attachmentVersionKey(safeScope, version.attachmentId, version.contentVersion),
            )),
        ]);
        const metadata = metadataValue as StoredAttachmentRow | undefined;
        if (accountEpoch !== (epochValue ?? 0)
            || (vaultValue as StoredVaultRow | undefined)?.version !== expectedSnapshotVersion
            || !metadata
            || metadata.dekWrapped !== version.dekWrapped
            || metadata.sha256 !== version.sha256.toLowerCase()
            || metadata.bytes !== version.bytes) {
            tx.abort();
            throw new Error("attachment_snapshot_version_conflict");
        }
        tx.objectStore(ATTACHMENT_CONTENT_STORE).put({
            scopeKey: key,
            vaultId: safeScope.vaultId,
            attachmentId: version.attachmentId.toLowerCase(),
            contentVersion: version.contentVersion.toLowerCase(),
            cipherB64: bytesToBase64(cipher),
            updatedMs: Date.now(),
        } satisfies StoredAttachmentContentRow, attachmentVersionKey(
            safeScope,
            version.attachmentId,
            version.contentVersion,
        ));
        await done;
    }

    async function writeAttachmentLedger(
        input: Omit<StoredAttachmentLedger, "version">, expectedVersion: number | null,
    ): Promise<StoredAttachmentLedger> {
        if (closed) throw new Error("cache_closed");
        validateLedgerVersion(expectedVersion);
        const state = parseAttachmentLedger(input.state);
        if (!input.scope.userId || !input.scope.vaultId || input.scope.userId.includes("\u0000")
            || input.scope.vaultId.includes("\u0000") || !Number.isSafeInteger(input.accountEpoch)
            || input.accountEpoch < 0) throw new Error("attachment_policy_invalid_scope");
        const scope = { userId: input.scope.userId, vaultId: input.scope.vaultId,
            origin: normalizedOrigin(input.scope) };
        const db = await database;
        const tx = db.transaction([ATTACHMENT_POLICIES_STORE, EPOCHS_STORE], "readwrite");
        const done = transactionDone(tx);
        void done.catch(() => undefined);
        const policies = tx.objectStore(ATTACHMENT_POLICIES_STORE);
        const key = storageKey(scope);
        const [value, epochValue] = await Promise.all([
            requestValue(policies.get(key)),
            requestValue(tx.objectStore(EPOCHS_STORE).get(epochKey(scope))),
        ]);
        if (input.accountEpoch !== (epochValue ?? 0)) {
            tx.abort();
            throw new Error("account_epoch_mismatch");
        }
        const current = value === undefined ? null : ledgerFrom(value, scope);
        if ((current?.version ?? null) !== expectedVersion || current && current.accountEpoch !== input.accountEpoch) {
            tx.abort();
            throw new Error("attachment_policy_version_conflict");
        }
        const next = { scope, state, accountEpoch: input.accountEpoch, version: (expectedVersion ?? 0) + 1 };
        policies.put(next, key);
        await done;
        return next;
    }

    async function preserveAccount(userId: string): Promise<void> {
        if (closed) throw new Error("cache_closed");
        if (!userId || userId.includes("\u0000")) throw new Error("encrypted_cache_invalid_scope");
        const db = await database;
        const tx = db.transaction([
            SNAPSHOTS_STORE,
            EPOCHS_STORE,
            ATTACHMENT_POLICIES_STORE,
            VAULTS_STORE,
        ], "readwrite");
        const done = transactionDone(tx);
        void done.catch(() => undefined);
        const snapshots = tx.objectStore(SNAPSHOTS_STORE);
        const policies = tx.objectStore(ATTACHMENT_POLICIES_STORE);
        const vaults = tx.objectStore(VAULTS_STORE);
        const epochRequest = tx.objectStore(EPOCHS_STORE).get(userId);
        const updated = new Promise<void>((resolve, reject) => {
            epochRequest.onsuccess = () => {
                const currentEpoch = typeof epochRequest.result === "number" ? epochRequest.result : 0;
                if (!Number.isSafeInteger(currentEpoch) || currentEpoch >= Number.MAX_SAFE_INTEGER) {
                    tx.abort();
                    reject(new Error("account_epoch_exhausted"));
                    return;
                }
                const nextEpoch = currentEpoch + 1;
                tx.objectStore(EPOCHS_STORE).put(nextEpoch, userId);
                const scans = [
                    new Promise<void>((scanResolve, scanReject) => {
                        const request = snapshots.openCursor();
                        request.onsuccess = () => {
                            try {
                                const cursor = request.result;
                                if (!cursor) {
                                    scanResolve();
                                    return;
                                }
                                const record = cursor.value as Partial<EncryptedSnapshot>;
                                if (record.scope?.userId === userId) {
                                    const snapshot = snapshotFrom(record);
                                    if (snapshot.accountEpoch === currentEpoch) {
                                        cursor.update({ ...snapshot, accountEpoch: nextEpoch });
                                    }
                                }
                                cursor.continue();
                            } catch (error) {
                                scanReject(error);
                                tx.abort();
                            }
                        };
                        request.onerror = () => scanReject(request.error ?? new Error("indexeddb_cursor_failed"));
                    }),
                    new Promise<void>((scanResolve, scanReject) => {
                        const request = policies.openCursor();
                        request.onsuccess = () => {
                            try {
                                const cursor = request.result;
                                if (!cursor) {
                                    scanResolve();
                                    return;
                                }
                                const record = cursor.value as Partial<StoredAttachmentLedger>;
                                if (record.scope?.userId === userId) {
                                    const ledger = ledgerFrom(record, record.scope);
                                    if (ledger.accountEpoch === currentEpoch) {
                                        cursor.update({ ...ledger, accountEpoch: nextEpoch });
                                    }
                                }
                                cursor.continue();
                            } catch (error) {
                                scanReject(error);
                                tx.abort();
                            }
                        };
                        request.onerror = () => scanReject(request.error ?? new Error("indexeddb_cursor_failed"));
                    }),
                    new Promise<void>((scanResolve, scanReject) => {
                        const request = vaults.openCursor();
                        request.onsuccess = () => {
                            try {
                                const cursor = request.result;
                                if (!cursor) {
                                    scanResolve();
                                    return;
                                }
                                const record = cursor.value as Partial<StoredVaultRow>;
                                if (record.scope?.userId === userId) {
                                    const vault = parseStoredVault(record);
                                    if (vault.accountEpoch === currentEpoch) {
                                        cursor.update({ ...vault, accountEpoch: nextEpoch });
                                    }
                                }
                                cursor.continue();
                            } catch (error) {
                                scanReject(error);
                                tx.abort();
                            }
                        };
                        request.onerror = () => scanReject(request.error ?? new Error("indexeddb_cursor_failed"));
                    }),
                ];
                void Promise.all(scans).then(() => resolve(), reject);
            };
            epochRequest.onerror = () => reject(epochRequest.error ?? new Error("indexeddb_request_failed"));
        });
        try {
            await updated;
            await done;
        } catch (error) {
            tx.abort();
            throw error;
        }
    }

    async function removeAccount(userId: string): Promise<void> {
        if (closed) throw new Error("cache_closed");
        const db = await database;
        const tx = db.transaction([
            SNAPSHOTS_STORE,
            EPOCHS_STORE,
            ATTACHMENT_POLICIES_STORE,
            VAULTS_STORE,
            VAULT_ITEMS_STORE,
            VAULT_PROFILES_STORE,
            ATTACHMENTS_STORE,
            ATTACHMENT_VERSIONS_STORE,
            ATTACHMENT_CONTENT_STORE,
        ], "readwrite");
        const done = transactionDone(tx);
        void done.catch(() => undefined);
        const snapshots = tx.objectStore(SNAPSHOTS_STORE);
        const epochs = tx.objectStore(EPOCHS_STORE);
        const epochPrefix = userId;
        const epochRequest = epochs.get(epochPrefix);
        const snapshotRequest = snapshots.openCursor();
        const [epochValue] = await Promise.all([
            requestValue(epochRequest),
            new Promise<void>((resolve, reject) => {
                const request = tx.objectStore(ATTACHMENT_POLICIES_STORE).openCursor();
                request.onsuccess = () => {
                    const cursor = request.result;
                    if (!cursor) { resolve(); return; }
                    if ((cursor.value as StoredAttachmentLedger).scope?.userId === userId) cursor.delete();
                    cursor.continue();
                };
                request.onerror = () => reject(request.error ?? new Error("indexeddb_cursor_failed"));
            }),
            new Promise<void>((resolve, reject) => {
                snapshotRequest.onsuccess = () => {
                    const cursor = snapshotRequest.result;
                    if (!cursor) {
                        resolve();
                        return;
                    }
                    const record = cursor.value as Partial<EncryptedSnapshot>;
                    if (record.scope?.userId === userId) {
                        cursor.delete();
                    }
                    cursor.continue();
                };
                snapshotRequest.onerror = () => reject(snapshotRequest.error ?? new Error("indexeddb_cursor_failed"));
            }),
            ...[
                VAULTS_STORE,
                VAULT_ITEMS_STORE,
                VAULT_PROFILES_STORE,
                ATTACHMENTS_STORE,
                ATTACHMENT_VERSIONS_STORE,
                ATTACHMENT_CONTENT_STORE,
            ].map(storeName => new Promise<void>((resolve, reject) => {
                const request = tx.objectStore(storeName).openCursor();
                request.onsuccess = () => {
                    const cursor = request.result;
                    if (!cursor) {
                        resolve();
                        return;
                    }
                    const value = cursor.value as { scope?: CacheScope; scopeKey?: string };
                    if (value.scope?.userId === userId || value.scopeKey?.split("\u0000")[1] === userId) {
                        cursor.delete();
                    }
                    cursor.continue();
                };
                request.onerror = () => reject(request.error ?? new Error("indexeddb_cursor_failed"));
            })),
        ]);
        epochs.put((typeof epochValue === "number" ? epochValue : 0) + 1, epochPrefix);
        await done;
    }

    function close(): void {
        if (closed) return;
        closed = true;
        void database.then((db) => db.close()).catch(() => undefined);
    }

    return {
        read,
        commit,
        readAttachmentLedger,
        replaceAttachmentVersions,
        writeAttachmentContent,
        writeAttachmentLedger,
        preserveAccount,
        removeAccount,
        getEpoch,
        close,
    };
}

function requestValue<T>(request: IDBRequest<T>): Promise<T> {
    return new Promise((resolve, reject) => {
        request.onsuccess = () => resolve(request.result);
        request.onerror = () => reject(request.error ?? new Error("indexeddb_request_failed"));
    });
}

function deleteBusinessRowsForScope(tx: IDBTransaction, scope: CacheScope): Promise<void> {
    const scopeKey = storageKey(scope);
    const stores = [VAULT_ITEMS_STORE, VAULT_PROFILES_STORE];
    return Promise.all(stores.map(storeName => new Promise<void>((resolve, reject) => {
        const request = tx.objectStore(storeName).openCursor();
        request.onsuccess = () => {
            const cursor = request.result;
            if (!cursor) {
                resolve();
                return;
            }
            const record = cursor.value as Partial<StoredBusinessRow>;
            if (record.scopeKey === scopeKey) cursor.delete();
            cursor.continue();
        };
        request.onerror = () => reject(request.error ?? new Error("indexeddb_cursor_failed"));
    }))).then(() => undefined);
}

function clearStoreScope(tx: IDBTransaction, storeName: string, scopeKey: string): Promise<void> {
    return new Promise((resolve, reject) => {
        const request = tx.objectStore(storeName).openCursor();
        request.onsuccess = () => {
            const cursor = request.result;
            if (!cursor) {
                resolve();
                return;
            }
            if ((cursor.value as { scopeKey?: string }).scopeKey === scopeKey) cursor.delete();
            cursor.continue();
        };
        request.onerror = () => reject(request.error ?? new Error("indexeddb_cursor_failed"));
    });
}

function transactionDone(transaction: IDBTransaction): Promise<void> {
    return new Promise((resolve, reject) => {
        transaction.oncomplete = () => resolve();
        transaction.onabort = () => reject(transaction.error ?? new Error("indexeddb_transaction_aborted"));
        transaction.onerror = () => reject(transaction.error ?? new Error("indexeddb_transaction_failed"));
    });
}
