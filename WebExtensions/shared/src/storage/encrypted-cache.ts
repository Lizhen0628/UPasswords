import { RELAY_BASE_URL, isValidRelayItemRow, type RelayItemRow } from "../api/relay.js";

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
}

/** 原子密文快照存储；version 防止并发覆盖，accountEpoch 防止登出后旧任务复写。 */
export interface EncryptedCache {
    /** 读取并验证快照；损坏记录应拒绝，不能当作合法空库。 */
    read(scope: CacheScope): Promise<EncryptedSnapshot | null>;
    /** 在同一 IndexedDB 事务内检查预期版本和账户 epoch 后替换整份快照。 */
    commit(
        snapshot: Omit<EncryptedSnapshot, "version">,
        expectedVersion: number | null,
    ): Promise<EncryptedSnapshot>;
    /** 删除该账户快照并推进 epoch，使先前在途任务无法提交。 */
    removeAccount(userId: string): Promise<void>;
    /** 获取账户失效代次；应在发起网络工作前捕获。 */
    getEpoch(scope: CacheScope): Promise<number>;
    /** 关闭连接并使此实例停止接受后续数据库工作。 */
    close(): void;
}

const DATABASE_NAME = "upasswords-encrypted-vault-cache";
const DATABASE_VERSION = 1;
const SNAPSHOTS_STORE = "snapshots";
const EPOCHS_STORE = "accountEpochs";

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

function snapshotFrom(value: unknown): EncryptedSnapshot {
    if (typeof value !== "object" || value === null) throw new Error("encrypted_cache_corrupt");
    const record = value as Record<string, unknown>;
    const allowedKeys = new Set(["scope", "envelope", "passwordVersion", "cursor", "version", "accountEpoch", "rows"]);
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
    };
}

/** IndexedDB cache containing only encrypted row payloads and relay metadata. */
export function createEncryptedCache(factory: IDBFactory = indexedDB): EncryptedCache {
    let closed = false;
    const database = new Promise<IDBDatabase>((resolve, reject) => {
        const request = factory.open(DATABASE_NAME, DATABASE_VERSION);
        request.onupgradeneeded = () => {
            const db = request.result;
            if (!db.objectStoreNames.contains(SNAPSHOTS_STORE)) db.createObjectStore(SNAPSHOTS_STORE);
            if (!db.objectStoreNames.contains(EPOCHS_STORE)) db.createObjectStore(EPOCHS_STORE);
        };
        request.onsuccess = () => resolve(request.result);
        request.onerror = () => reject(request.error ?? new Error("indexeddb_open_failed"));
        request.onblocked = () => reject(new Error("indexeddb_open_blocked"));
    });
    // Observe eager-open failure even before the first cache consumer; operations still reject.
    void database.catch(() => undefined);

    async function read(scope: CacheScope): Promise<EncryptedSnapshot | null> {
        if (closed) throw new Error("cache_closed");
        const db = await database;
        const tx = db.transaction([SNAPSHOTS_STORE, EPOCHS_STORE], "readonly");
        const done = transactionDone(tx);
        const snapshotRequest = tx.objectStore(SNAPSHOTS_STORE).get(storageKey(scope));
        const epochRequest = tx.objectStore(EPOCHS_STORE).get(epochKey(scope));
        const [stored, epochValue] = await Promise.all([
            requestValue(snapshotRequest),
            requestValue(epochRequest),
        ]);
        await done;
        if (stored === undefined) return null;
        const snapshot = snapshotFrom(stored);
        if (snapshot.scope.userId !== scope.userId || snapshot.scope.vaultId !== scope.vaultId
            || normalizedOrigin(snapshot.scope) !== normalizedOrigin(scope)) {
            throw new Error("encrypted_cache_corrupt");
        }
        const epoch = typeof epochValue === "number" ? epochValue : 0;
        if (snapshot.accountEpoch !== epoch) return null;
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
        input: Omit<EncryptedSnapshot, "version">,
        expectedVersion: number | null,
    ): Promise<EncryptedSnapshot> {
        if (closed) throw new Error("cache_closed");
        if (typeof input.scope.userId !== "string" || !input.scope.userId
            || typeof input.scope.vaultId !== "string" || !input.scope.vaultId
            || typeof input.envelope !== "string" || !input.envelope
            || !Number.isSafeInteger(input.passwordVersion) || input.passwordVersion < 0
            || !Number.isSafeInteger(input.cursor) || input.cursor < 0
            || !Number.isSafeInteger(input.accountEpoch) || input.accountEpoch < 0
            || !Array.isArray(input.rows) || (expectedVersion !== null
                && (!Number.isSafeInteger(expectedVersion) || expectedVersion < 1
                    || expectedVersion >= Number.MAX_SAFE_INTEGER))
            || input.scope.userId.includes("\u0000") || input.scope.vaultId.includes("\u0000")) {
            throw new Error("encrypted_cache_invalid_snapshot");
        }
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
        const db = await database;
        const tx = db.transaction([SNAPSHOTS_STORE, EPOCHS_STORE], "readwrite");
        const done = transactionDone(tx);
        void done.catch(() => undefined);
        const snapshots = tx.objectStore(SNAPSHOTS_STORE);
        const epochs = tx.objectStore(EPOCHS_STORE);
        const key = storageKey(safeScope);
        const eKey = epochKey(safeScope);
        const [currentValue, currentEpochValue] = await Promise.all([
            requestValue(snapshots.get(key)),
            requestValue(epochs.get(eKey)),
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
        const next: EncryptedSnapshot = {
            scope: safeScope,
            envelope: input.envelope,
            passwordVersion: input.passwordVersion,
            cursor: input.cursor,
            accountEpoch: input.accountEpoch,
            rows,
            version: expectedVersion === null ? 1 : expectedVersion + 1,
        };
        snapshots.put(next, key);
        await done;
        return next;
    }

    async function removeAccount(userId: string): Promise<void> {
        if (closed) throw new Error("cache_closed");
        const db = await database;
        const tx = db.transaction([SNAPSHOTS_STORE, EPOCHS_STORE], "readwrite");
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
        ]);
        epochs.put((typeof epochValue === "number" ? epochValue : 0) + 1, epochPrefix);
        await done;
    }

    function close(): void {
        if (closed) return;
        closed = true;
        void database.then((db) => db.close()).catch(() => undefined);
    }

    return { read, commit, removeAccount, getEpoch, close };
}

function requestValue<T>(request: IDBRequest<T>): Promise<T> {
    return new Promise((resolve, reject) => {
        request.onsuccess = () => resolve(request.result);
        request.onerror = () => reject(request.error ?? new Error("indexeddb_request_failed"));
    });
}

function transactionDone(transaction: IDBTransaction): Promise<void> {
    return new Promise((resolve, reject) => {
        transaction.oncomplete = () => resolve();
        transaction.onabort = () => reject(transaction.error ?? new Error("indexeddb_transaction_aborted"));
        transaction.onerror = () => reject(transaction.error ?? new Error("indexeddb_transaction_failed"));
    });
}
