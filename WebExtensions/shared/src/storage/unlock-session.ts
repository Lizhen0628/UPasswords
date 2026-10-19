import { decryptItemBodyWithKey, importVaultDecryptKey } from "../core/vault-crypto.js";
import type { ExtensionItem } from "../core/types.js";
import type { VaultSessionRequest, VaultSessionResponse } from "../messaging/protocol.js";

export const UNLOCK_SESSION_TTL_MS = 15 * 60 * 1000;
const SESSION_KEY = "upw.unlockSession";
const SESSION_KEYS = [SESSION_KEY];
const LEGACY_KEYS = ["vault.items", "vault.updatedAt"];
const LOCAL_SESSION_KEY = "relay.session";
const LOCAL_VAULT_KEY = "relay.vault";

type StorageArea = {
    get(keys: string[]): Promise<Record<string, unknown>>;
    set(values: Record<string, unknown>): Promise<void>;
    remove?(keys: string[]): Promise<void>;
};

type SessionRecord = {
    generation: string;
    ticket: string | null;
    expiresAt: number;
    context: SessionContext;
    items: ExtensionItem[] | null;
    vaultKey?: number[];
    passwordVersion?: number;
    snapshotVersion?: number;
};

type SessionContext = { token: string; vaultId: string; userId?: string };
type UnlockRequest = VaultSessionRequest;
type SessionResponse = VaultSessionResponse;

export interface UnlockSessionOptions {
    local: StorageArea;
    session?: StorageArea | null;
    now?: () => number;
    makeId?: () => string;
    log?: (event: string, details: Record<string, number | boolean>) => void;
    idleMs?: number;
    configureSessionStorage?: () => Promise<void>;
}

/** Owns plaintext snapshots only in restricted session storage or background memory. */
export function createUnlockSession(options: UnlockSessionOptions) {
    const now = options.now ?? Date.now;
    const makeId = options.makeId ?? (() => crypto.randomUUID());
    const idleMs = options.idleMs ?? UNLOCK_SESSION_TTL_MS;
    let memoryRecord: SessionRecord | null = null;
    let loadedRecord: SessionRecord | null = null;
    let sessionArea = options.session ?? null;
    let persistent = sessionArea != null;
    let queue = Promise.resolve();
    let configuration: Promise<void> | null = null;
    // Changed synchronously, before queued cleanup: in-flight operations must not return old plaintext.
    let invalidationEpoch = 0;

    function serialize<T>(operation: () => Promise<T>): Promise<T> {
        const result = queue.then(operation, operation);
        queue = result.then(() => undefined, () => undefined);
        return result;
    }

    function log(event: string, count = 0): void {
        options.log?.(event, { count, persistent });
    }

    async function configureSessionStorage(): Promise<void> {
        if (configuration) return configuration;
        configuration = (async () => {
            try {
                await options.configureSessionStorage?.();
            } catch {
                sessionArea = null;
                persistent = false;
                options.log?.("session-storage-fallback", { count: 0, persistent: false });
            }
        })();
        return configuration;
    }

    async function readRecord(): Promise<SessionRecord | null> {
        if (!sessionArea) return memoryRecord;
        const bag = await sessionArea.get(SESSION_KEYS);
        const value = bag[SESSION_KEY];
        loadedRecord = value && typeof value === "object" ? value as SessionRecord : null;
        return loadedRecord;
    }

    async function writeRecord(record: SessionRecord | null): Promise<void> {
        if (loadedRecord?.vaultKey !== record?.vaultKey) loadedRecord?.vaultKey?.fill(0);
        if (memoryRecord?.vaultKey !== record?.vaultKey) memoryRecord?.vaultKey?.fill(0);
        loadedRecord = record;
        if (!sessionArea) {
            memoryRecord = record;
            return;
        }
        if (record) await sessionArea.set({ [SESSION_KEY]: record });
        else if (sessionArea.remove) await sessionArea.remove(SESSION_KEYS);
        else await sessionArea.set({ [SESSION_KEY]: null });
    }

    async function idleTimeout(): Promise<number> {
        const bag = await options.local.get(["extension.lockMinutes"]);
        const minutes = bag["extension.lockMinutes"];
        const allowed = [5, 15, 30, 60];
        return typeof minutes === "number" && allowed.includes(minutes) ? minutes * 60_000 : idleMs;
    }

    async function contextFromLocal(): Promise<SessionContext | null> {
        const bag = await options.local.get([LOCAL_SESSION_KEY, LOCAL_VAULT_KEY]);
        const session = bag[LOCAL_SESSION_KEY] as { token?: unknown; expiresAt?: unknown; userId?: unknown } | undefined;
        const vault = bag[LOCAL_VAULT_KEY] as { id?: unknown } | undefined;
        if (typeof session?.token !== "string" || !session.token
            || typeof vault?.id !== "string" || !vault.id) return null;
        // A real account binding permits offline unlock after the cloud token expires.
        if (typeof session.userId === "string" && session.userId) {
            return { token: session.token, vaultId: vault.id, userId: session.userId };
        }
        // Preserve legacy token-only callers' expiration semantics.
        if (typeof session.expiresAt !== "number" || session.expiresAt <= now()) return null;
        return { token: session.token, vaultId: vault.id };
    }

    function sameContext(left: SessionContext, right: SessionContext): boolean {
        return left.token === right.token && left.vaultId === right.vaultId
            && left.userId === right.userId;
    }

    async function clear(): Promise<void> {
        await writeRecord(null);
        await options.local.set({ "vault.items": null, "vault.updatedAt": 0 });
    }

    async function currentRecord(context: SessionContext): Promise<SessionRecord | null> {
        const record = await readRecord();
        if (!record) return null;
        if (record.expiresAt <= now() || !sameContext(record.context, context)) {
            await writeRecord(null);
            return null;
        }
        return record;
    }

    function locked(code = "session_locked"): SessionResponse {
        return { type: "vault-session", unlocked: false, persistent, code };
    }

    function versions(record: SessionRecord) {
        return {
            ...(record.snapshotVersion === undefined ? {} : { snapshotVersion: record.snapshotVersion }),
            ...(record.passwordVersion === undefined ? {} : { passwordVersion: record.passwordVersion }),
        };
    }

    function validVersion(value: unknown): value is number {
        return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
    }

    function validKey(value: unknown): value is number[] {
        return Array.isArray(value) && value.length === 32
            && Array.from(value).every(byte => Number.isInteger(byte) && byte >= 0 && byte <= 255);
    }

    /** Recheck after storage awaits; queued invalidation must take effect before any plaintext response. */
    async function stillCurrent(
        record: SessionRecord,
        epoch: number,
        previousExpiresAt = record.expiresAt,
    ): Promise<boolean> {
        const context = await contextFromLocal();
        if (epoch === invalidationEpoch && record.expiresAt > now() && previousExpiresAt > now()
            && context && sameContext(record.context, context)) return true;
        await clear();
        log("stale-operation");
        return false;
    }

    function validSource(item: ExtensionItem): boolean {
        return typeof item.source?.xml === "string" && Number.isSafeInteger(item.source.revision)
            && item.source.revision > 0;
    }

    async function handle(request: UnlockRequest): Promise<SessionResponse> {
        // A stale conditional lock must not invalidate a newly unlocked generation.
        const immediateLock = request.action === "lock"
            && (request.generation === undefined || request.generation === loadedRecord?.generation);
        if (immediateLock) {
            invalidationEpoch += 1;
            loadedRecord?.vaultKey?.fill(0);
            memoryRecord?.vaultKey?.fill(0);
        }
        const epoch = invalidationEpoch;
        return serialize(async () => {
            await configureSessionStorage();
            if (epoch !== invalidationEpoch) return locked();
            const localContext = await contextFromLocal();
            if (request.action === "lock") {
                if (request.generation !== undefined) {
                    const record = await readRecord();
                    if (!record || record.generation !== request.generation) {
                        log("lock-skipped-generation");
                        return locked("session_generation_mismatch");
                    }
                    if (!immediateLock) invalidationEpoch += 1;
                }
                await clear();
                log("lock");
                return locked();
            }
            if (!localContext) {
                await clear();
                log("invalid-context");
                return locked();
            }
            const requestedContext = request.context;
            if (!requestedContext || typeof requestedContext.token !== "string"
                || typeof requestedContext.vaultId !== "string"
                || !sameContext(localContext, requestedContext)) {
                await currentRecord(localContext);
                return locked("session_context_mismatch");
            }
            if (request.action === "begin") {
                await options.local.set({ [LEGACY_KEYS[0]]: null, [LEGACY_KEYS[1]]: 0 });
                const generation = makeId();
                const timeoutMs = await idleTimeout();
                const record: SessionRecord = {
                    generation,
                    ticket: generation,
                    expiresAt: now() + timeoutMs,
                    context: localContext,
                    items: null,
                };
                await writeRecord(record);
                if (!await stillCurrent(record, epoch)) return locked();
                log("begin");
                return {
                    type: "vault-session", unlocked: false, generation,
                    expiresAt: record.expiresAt, persistent,
                };
            }
            const record = await currentRecord(localContext);
            if (!record || !await stillCurrent(record, epoch)) return locked();
            if (request.action !== "commit" && request.generation !== undefined
                && request.generation !== record.generation) return locked("session_generation_mismatch");
            if (request.action === "commit") {
                if (!request.generation || request.generation !== record.ticket
                    || !Array.isArray(request.items)) return locked();
                if ((request.vaultKey !== undefined && !validKey(request.vaultKey))
                    || (request.passwordVersion !== undefined && !validVersion(request.passwordVersion))
                    || (request.snapshotVersion !== undefined && !validVersion(request.snapshotVersion))) {
                    return locked("invalid_session_commit");
                }
                const committed: SessionRecord = {
                    ...record,
                    ticket: null,
                    items: structuredClone(request.items),
                    ...(request.vaultKey === undefined ? {} : { vaultKey: [...request.vaultKey] }),
                    ...(request.passwordVersion === undefined ? {} : { passwordVersion: request.passwordVersion }),
                    ...(request.snapshotVersion === undefined ? {} : { snapshotVersion: request.snapshotVersion }),
                    expiresAt: now() + await idleTimeout(),
                };
                await writeRecord(committed);
                if (!await stillCurrent(committed, epoch, record.expiresAt)) return locked();
                log("commit", request.items.length);
                return {
                    type: "vault-session", unlocked: true, generation: committed.generation,
                    expiresAt: committed.expiresAt, persistent, ...versions(committed),
                };
            }
            if (request.action === "decrypt" || request.action === "refresh") {
                if (record.items === null || record.ticket !== null
                    || request.generation !== record.generation) return locked("session_generation_mismatch");
                if (request.action === "decrypt") {
                    if (!validKey(record.vaultKey)) return locked("session_key_missing");
                    if (!Array.isArray(request.rows)) return locked("invalid_session_rows");
                    const rawKey = Uint8Array.from(record.vaultKey);
                    try {
                        const key = await importVaultDecryptKey(rawKey);
                        rawKey.fill(0);
                        if (!await stillCurrent(record, epoch)) return locked();
                        const fragments = [];
                        const seen = new Set<string>();
                        for (const row of request.rows) {
                            if (!row || typeof row.uuid !== "string"
                                || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(row.uuid)
                                || seen.has(row.uuid.toLowerCase()) || typeof row.bodyB64 !== "string"
                                || !validVersion(row.revision) || row.revision === 0
                                || (row.kind !== 1 && row.kind !== 2)
                                || !validVersion(row.modifiedMs)) return locked("invalid_session_rows");
                            seen.add(row.uuid.toLowerCase());
                            const body = Uint8Array.from(atob(row.bodyB64), char => char.charCodeAt(0));
                            const xml = await decryptItemBodyWithKey(body, key, row.uuid);
                            if (!await stillCurrent(record, epoch)) return locked();
                            fragments.push({ uuid: row.uuid, xml, revision: row.revision,
                                kind: row.kind, modifiedMs: row.modifiedMs });
                        }
                        if (!await stillCurrent(record, epoch)) return locked();
                        log("decrypt", fragments.length);
                        return { type: "vault-session", unlocked: true, generation: record.generation,
                            fragments, ...versions(record) };
                    } catch {
                        log("decrypt-failed");
                        return locked("item_decrypt_failed");
                    } finally {
                        rawKey.fill(0);
                    }
                }
                if (!validVersion(request.expectedSnapshotVersion)
                    || request.expectedSnapshotVersion !== record.snapshotVersion) {
                    log("refresh-conflict");
                    return locked("session_snapshot_conflict");
                }
                if (!validVersion(request.snapshotVersion)
                    || request.snapshotVersion <= request.expectedSnapshotVersion
                    || !validVersion(request.passwordVersion) || !Array.isArray(request.items)) {
                    return locked("invalid_session_refresh");
                }
                if (record.passwordVersion !== undefined && request.passwordVersion !== record.passwordVersion) {
                    return locked("session_password_version_mismatch");
                }
                const refreshed: SessionRecord = { ...record, items: structuredClone(request.items),
                    snapshotVersion: request.snapshotVersion, passwordVersion: request.passwordVersion };
                await writeRecord(refreshed);
                if (!await stillCurrent(refreshed, epoch)) return locked();
                log("refresh", request.items.length);
                return { type: "vault-session", unlocked: true, generation: refreshed.generation,
                    expiresAt: refreshed.expiresAt, persistent, ...versions(refreshed) };
            }
            if (request.action === "replace") {
                const item = request.item;
                if (record.items === null || record.ticket !== null
                    || request.generation !== record.generation
                    || !item || typeof item.id !== "string" || !item.id
                    || !validSource(item)) return locked();
                const index = record.items.findIndex((entry) => entry.id === item.id);
                if (index < 0) return locked();
                const previous = record.items[index];
                if (!validSource(previous) || !previous.source || !item.source
                    || item.source.revision <= previous.source.revision) {
                    log("replace-rejected-revision");
                    return locked();
                }
                if (request.expectedSnapshotVersion !== undefined
                    && (!validVersion(request.expectedSnapshotVersion)
                        || request.expectedSnapshotVersion !== record.snapshotVersion)) {
                    log("replace-conflict");
                    return locked("session_snapshot_conflict");
                }
                if (request.snapshotVersion !== undefined
                    && (!validVersion(request.snapshotVersion)
                        || (record.snapshotVersion !== undefined && request.snapshotVersion <= record.snapshotVersion))) {
                    return locked("invalid_snapshot_version");
                }
                const snapshotVersion = request.snapshotVersion ?? (record.snapshotVersion === undefined
                    ? undefined : record.snapshotVersion + 1);
                if (snapshotVersion !== undefined && !validVersion(snapshotVersion)) {
                    return locked("invalid_snapshot_version");
                }
                const items = [...record.items];
                items[index] = structuredClone(item);
                const updated = { ...record, items, expiresAt: now() + await idleTimeout(),
                    ...(snapshotVersion === undefined ? {} : { snapshotVersion }) };
                await writeRecord(updated);
                if (!await stillCurrent(updated, epoch, record.expiresAt)) return locked();
                log("replace", 1);
                return {
                    type: "vault-session", unlocked: true, items,
                    generation: updated.generation, expiresAt: updated.expiresAt, persistent, ...versions(updated),
                };
            }
            if (request.action === "read") {
                if (record.items === null) return locked();
                return {
                    type: "vault-session", unlocked: true, items: record.items,
                    generation: record.generation, expiresAt: record.expiresAt, persistent, ...versions(record),
                };
            }
            if (request.action === "touch") {
                if (record.items === null) return locked();
                const previousExpiresAt = record.expiresAt;
                record.expiresAt = now() + await idleTimeout();
                await writeRecord(record);
                if (!await stillCurrent(record, epoch, previousExpiresAt)) return locked();
                log("touch");
                return {
                    type: "vault-session", unlocked: true, generation: record.generation,
                    expiresAt: record.expiresAt, persistent, ...versions(record),
                };
            }
            return locked();
        });
    }

    async function purge(): Promise<void> {
        await serialize(async () => {
            await configureSessionStorage();
            const record = await readRecord();
            if (record) {
                const context = await contextFromLocal();
                if (record.expiresAt <= now() || !context || !sameContext(record.context, context)) {
                    await clear();
                    log("purge");
                }
            }
            await options.local.set({ [LEGACY_KEYS[0]]: null, [LEGACY_KEYS[1]]: 0 });
        });
    }

    async function invalidate(): Promise<void> {
        invalidationEpoch += 1;
        loadedRecord?.vaultKey?.fill(0);
        memoryRecord?.vaultKey?.fill(0);
        await serialize(async () => {
            await configureSessionStorage();
            await clear();
            log("invalidate");
        });
    }

    /** Background-only read used to compute a count; never exposed through content messages. */
    async function inspect(): Promise<SessionResponse> {
        const epoch = invalidationEpoch;
        return serialize(async () => {
            await configureSessionStorage();
            if (epoch !== invalidationEpoch) return locked();
            const context = await contextFromLocal();
            if (!context) {
                await clear();
                return locked();
            }
            const record = await currentRecord(context);
            if (!record || record.items === null || !await stillCurrent(record, epoch)) return locked();
            return {
                type: "vault-session", unlocked: true, items: record.items,
                generation: record.generation, expiresAt: record.expiresAt, persistent, ...versions(record),
            };
        });
    }

    return { handle, purge, invalidate, inspect, get persistent() { return persistent; } };
}

/** Creates the browser-backed session; unsupported storage.session is never replaced with local storage. */
export function createBrowserUnlockSession(api: any) {
    const sessionArea = api.storage?.session ?? null;
    const configureSessionStorage = async () => {
        if (sessionArea && typeof sessionArea.setAccessLevel !== "function") {
            // Firefox documents session as extension-only by default. Prefer memory without
            // an explicit restriction capability rather than relying on browser detection.
            throw new Error("trusted_session_storage_unavailable");
        }
        if (sessionArea) await sessionArea.setAccessLevel({ accessLevel: "TRUSTED_CONTEXTS" });
    };
    return createUnlockSession({
        local: api.storage.local,
        session: sessionArea,
        configureSessionStorage,
        log: (event, details) => console.info("[upw] vault session", event, details),
    });
}

/** Registers strict popup-only message handling and extension lifecycle cleanup. */
export function installSessionBackground(api: any) {
    const session = createBrowserUnlockSession(api);
    const popupURL = api.runtime.getURL("src/popup.html");
    const authorized = (sender: any) => sender?.id === api.runtime.id
        && sender.url === popupURL && sender.tab == null;
    const cleanup = (operation: Promise<void>) => {
        void operation.catch(() => console.warn("[upw] vault session cleanup failed"));
    };

    api.runtime.onMessage.addListener((message: unknown, sender: any, sendResponse: (value: unknown) => void) => {
        const request = message as UnlockRequest | null;
        if (request?.type === "vault-session") {
            if (!authorized(sender)) {
                sendResponse({ type: "vault-session", unlocked: false, code: "session_sender_rejected" });
                console.warn("[upw] rejected vault session sender");
                return false;
            }
            void session.handle(request).then(sendResponse, () => {
                console.warn("[upw] vault session request failed");
                sendResponse({ type: "vault-session", unlocked: false, code: "session_operation_failed" });
            });
            return true;
        }
        if (request && ["query", "unlock", "fill"].includes((request as { type?: string }).type ?? "")) {
            if (!authorized(sender)) {
                sendResponse({ type: "locked" });
                return false;
            }
            if ((request as { type?: string }).type === "query") {
                sendResponse({ type: "locked" });
                return false;
            }
        }
        return false;
    });

    api.runtime.onStartup?.addListener(() => { cleanup(session.invalidate()); });
    api.runtime.onInstalled?.addListener(() => { cleanup(session.invalidate()); });
    api.alarms?.create("upw-session-purge", { periodInMinutes: 1 });
    api.alarms?.onAlarm?.addListener((alarm: { name?: string }) => {
        if (alarm?.name === "upw-session-purge") cleanup(session.purge());
    });
    api.storage.onChanged?.addListener((changes: Record<string, unknown>, areaName: string) => {
        if (areaName === "local" && (LOCAL_SESSION_KEY in changes || LOCAL_VAULT_KEY in changes)) {
            cleanup(session.invalidate());
        }
    });
    cleanup(session.purge());
    return session;
}
