import { MAX_BACKUP_ARCHIVE_BYTES } from "../core/portable-backup-package.js";

export interface LocalBackupCopySummary {
    id: string;
    name: string;
    createdAt: number;
    itemCount: number;
    attachmentVersionCount: number;
    conflictCount: number;
    issueCount: number;
    isComplete: boolean;
    byteCount: number;
}

export interface LocalBackupCopy extends LocalBackupCopySummary {
    archive: Blob;
    historyCipher: Uint8Array;
}

export type LocalBackupCopyInput = Omit<LocalBackupCopy, "byteCount">;

export interface LocalBackupStore {
    /** Atomically create a new encrypted local copy without replacing an existing identity. */
    create(copy: LocalBackupCopyInput): Promise<LocalBackupCopySummary>;
    /** List non-sensitive copy metadata without reading encrypted archive payloads. */
    list(): Promise<LocalBackupCopySummary[]>;
    /** Read the selected encrypted archive and its new-VEK-protected recovery dependencies. */
    read(id: string): Promise<LocalBackupCopy | null>;
    /** Remove one copy only after the user explicitly requests deletion. */
    remove(id: string): Promise<void>;
    /** Close the IndexedDB connection and reject future operations. */
    close(): void;
}

const DATABASE_NAME = "upasswords-local-backup-copies";
const DATABASE_VERSION = 1;
const COPIES_STORE = "copies";
const MAX_NAME_LENGTH = 128;
const MAX_HISTORY_CIPHER_BYTES = 2_048;
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

type StoredLocalBackupCopy = LocalBackupCopy & { version: 1 };

function isNonNegativeInteger(value: unknown): value is number {
    return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
}

function validateCopyInput(copy: LocalBackupCopyInput): void {
    if (!UUID_PATTERN.test(copy.id) || typeof copy.name !== "string"
        || !copy.name.trim() || copy.name.trim().length > MAX_NAME_LENGTH
        || /[\u0000-\u001f\u007f]/.test(copy.name)
        || !isNonNegativeInteger(copy.createdAt)
        || !isNonNegativeInteger(copy.itemCount)
        || !isNonNegativeInteger(copy.attachmentVersionCount)
        || !isNonNegativeInteger(copy.conflictCount)
        || !isNonNegativeInteger(copy.issueCount)
        || typeof copy.isComplete !== "boolean"
        || !(copy.archive instanceof Blob) || copy.archive.size < 1
        || copy.archive.size > MAX_BACKUP_ARCHIVE_BYTES
        || !(copy.historyCipher instanceof Uint8Array) || copy.historyCipher.length < 28
        || copy.historyCipher.length > MAX_HISTORY_CIPHER_BYTES) {
        throw new Error("local_backup_store_invalid_copy");
    }
}

function storedCopyFrom(value: unknown): StoredLocalBackupCopy {
    if (typeof value !== "object" || value === null) throw new Error("local_backup_store_corrupt");
    const record = value as Record<string, unknown>;
    const keys = new Set([
        "version", "id", "name", "createdAt", "itemCount", "attachmentVersionCount", "conflictCount",
        "issueCount", "isComplete", "byteCount", "archive", "historyCipher",
    ]);
    if (Object.keys(record).some(key => !keys.has(key)) || record.version !== 1
        || !UUID_PATTERN.test(String(record.id)) || typeof record.name !== "string"
        || !record.name.trim() || record.name.trim().length > MAX_NAME_LENGTH
        || /[\u0000-\u001f\u007f]/.test(record.name)
        || !isNonNegativeInteger(record.createdAt) || !isNonNegativeInteger(record.itemCount)
        || !isNonNegativeInteger(record.attachmentVersionCount) || !isNonNegativeInteger(record.conflictCount)
        || !isNonNegativeInteger(record.issueCount) || typeof record.isComplete !== "boolean"
        || !isNonNegativeInteger(record.byteCount) || !(record.archive instanceof Blob)
        || record.archive.size !== record.byteCount || record.archive.size < 1
        || record.archive.size > MAX_BACKUP_ARCHIVE_BYTES || !(record.historyCipher instanceof Uint8Array)
        || record.historyCipher.length < 28 || record.historyCipher.length > MAX_HISTORY_CIPHER_BYTES) {
        throw new Error("local_backup_store_corrupt");
    }
    return value as StoredLocalBackupCopy;
}

function summary(copy: LocalBackupCopySummary): LocalBackupCopySummary {
    return {
        id: copy.id,
        name: copy.name,
        createdAt: copy.createdAt,
        itemCount: copy.itemCount,
        attachmentVersionCount: copy.attachmentVersionCount,
        conflictCount: copy.conflictCount,
        issueCount: copy.issueCount,
        isComplete: copy.isComplete,
        byteCount: copy.byteCount,
    };
}

function requestValue<T>(request: IDBRequest<T>): Promise<T> {
    return new Promise((resolve, reject) => {
        request.onsuccess = () => resolve(request.result);
        request.onerror = () => reject(request.error ?? new Error("local_backup_store_request_failed"));
    });
}

function transactionDone(transaction: IDBTransaction): Promise<void> {
    return new Promise((resolve, reject) => {
        transaction.oncomplete = () => resolve();
        transaction.onabort = () => reject(transaction.error ?? new Error("local_backup_store_transaction_aborted"));
        transaction.onerror = () => reject(transaction.error ?? new Error("local_backup_store_transaction_failed"));
    });
}

/** Create the extension-only IndexedDB store for encrypted, cloud-independent backup copies. */
export function createLocalBackupStore(factory: IDBFactory = indexedDB): LocalBackupStore {
    let closed = false;
    const database = new Promise<IDBDatabase>((resolve, reject) => {
        const request = factory.open(DATABASE_NAME, DATABASE_VERSION);
        request.onupgradeneeded = () => {
            if (!request.result.objectStoreNames.contains(COPIES_STORE)) {
                request.result.createObjectStore(COPIES_STORE, { keyPath: "id" });
            }
        };
        request.onsuccess = () => resolve(request.result);
        request.onerror = () => reject(request.error ?? new Error("local_backup_store_open_failed"));
        request.onblocked = () => reject(new Error("local_backup_store_open_blocked"));
    });

    function ensureOpen(): void {
        if (closed) throw new Error("local_backup_store_closed");
    }

    async function create(copy: LocalBackupCopyInput): Promise<LocalBackupCopySummary> {
        ensureOpen();
        validateCopyInput(copy);
        const record: StoredLocalBackupCopy = {
            ...copy,
            name: copy.name.trim(),
            byteCount: copy.archive.size,
            version: 1,
        };
        const db = await database;
        const transaction = db.transaction(COPIES_STORE, "readwrite");
        const done = transactionDone(transaction);
        void done.catch(() => undefined);
        try {
            transaction.objectStore(COPIES_STORE).add(record);
        } catch (error) {
            transaction.abort();
            throw error;
        }
        await done;
        return summary(record);
    }

    async function list(): Promise<LocalBackupCopySummary[]> {
        ensureOpen();
        const db = await database;
        const transaction = db.transaction(COPIES_STORE, "readonly");
        const done = transactionDone(transaction);
        const values = await requestValue(transaction.objectStore(COPIES_STORE).getAll());
        await done;
        return values.map(value => summary(storedCopyFrom(value)))
            .sort((left, right) => right.createdAt - left.createdAt || left.id.localeCompare(right.id));
    }

    async function read(id: string): Promise<LocalBackupCopy | null> {
        ensureOpen();
        if (!UUID_PATTERN.test(id)) throw new Error("local_backup_store_invalid_id");
        const db = await database;
        const transaction = db.transaction(COPIES_STORE, "readonly");
        const done = transactionDone(transaction);
        const value = await requestValue(transaction.objectStore(COPIES_STORE).get(id));
        await done;
        return value === undefined ? null : storedCopyFrom(value);
    }

    async function remove(id: string): Promise<void> {
        ensureOpen();
        if (!UUID_PATTERN.test(id)) throw new Error("local_backup_store_invalid_id");
        const db = await database;
        const transaction = db.transaction(COPIES_STORE, "readwrite");
        const done = transactionDone(transaction);
        void done.catch(() => undefined);
        transaction.objectStore(COPIES_STORE).delete(id);
        await done;
    }

    function close(): void {
        if (closed) return;
        closed = true;
        void database.then(db => db.close()).catch(() => undefined);
    }

    return { create, list, read, remove, close };
}
