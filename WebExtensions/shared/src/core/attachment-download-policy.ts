import { RelayApiError } from "../api/relay.js";

export type AttachmentFailure = "transient" | "authorization" | "integrity" | "unavailable" | "storage" | "permanent";
export interface AttachmentRetryRecord {
    failure?: AttachmentFailure;
    failureCount: number;
    retryAt?: number;
    evicted: boolean;
    lastAccess?: number;
}

/** Local policy contains stable identities and timing only, never plaintext or account tokens. */
export interface AttachmentLedgerState {
    formatVersion: 1;
    records: Record<string, AttachmentRetryRecord>;
    offlineAttachments: string[];
    downloadAllVersions: string[];
    authorizationFingerprint?: string;
}

export interface AttachmentVersionReference {
    cardID: string;
    id: string | null;
    contentVersion: string | null;
    missing: boolean;
}

const UUID = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
const IDENTITY_PATTERN = new RegExp(`^${UUID}/${UUID}$`);
const VERSION_PATTERN = new RegExp(`^${UUID}/${UUID}/${UUID}$`);
const FAILURES = new Set(["transient", "authorization", "integrity", "unavailable", "storage", "permanent"]);
export const ATTACHMENT_RETRY_DELAYS_MS = [2_000, 5_000, 15_000, 30_000, 60_000] as const;
export const ATTACHMENT_CACHE_BUDGET_BYTES = 256 * 1024 * 1024;

function corrupt(): never { throw new Error("attachment_policy_corrupt"); }
function plainObject(value: unknown): value is Record<string, unknown> {
    return typeof value === "object" && value !== null && !Array.isArray(value);
}
function finiteTime(value: unknown): boolean {
    return value === undefined || typeof value === "number" && Number.isFinite(value) && value >= 0;
}
function exactKeys(value: object, allowed: string[]): boolean {
    return Object.keys(value).every(key => allowed.includes(key));
}

/** Validate persisted state without silently resetting a corrupt retry limit. */
export function parseAttachmentLedger(value: unknown): AttachmentLedgerState {
    if (!plainObject(value) || value.formatVersion !== 1
        || !exactKeys(value, ["formatVersion", "records", "offlineAttachments", "downloadAllVersions", "authorizationFingerprint"])
        || !plainObject(value.records) || !Array.isArray(value.offlineAttachments)
        || !Array.isArray(value.downloadAllVersions)
        || value.authorizationFingerprint !== undefined && (typeof value.authorizationFingerprint !== "string"
            || !/^[0-9a-f]{64}$/.test(value.authorizationFingerprint))) corrupt();
    const records: Record<string, AttachmentRetryRecord> = {};
    for (const [key, record] of Object.entries(value.records)) {
        if (!VERSION_PATTERN.test(key) || !plainObject(record)
            || !exactKeys(record, ["failure", "failureCount", "retryAt", "evicted", "lastAccess"])
            || !Number.isInteger(record.failureCount) || (record.failureCount as number) < 0
            || (record.failureCount as number) > ATTACHMENT_RETRY_DELAYS_MS.length + 1
            || typeof record.evicted !== "boolean" || !finiteTime(record.retryAt) || !finiteTime(record.lastAccess)
            || record.failure !== undefined && !FAILURES.has(record.failure as string)
            || (record.failure === undefined) !== (record.failureCount === 0)
            || (record.retryAt !== undefined) !== (record.failure === "transient"
                && (record.failureCount as number) >= 1 && (record.failureCount as number) <= ATTACHMENT_RETRY_DELAYS_MS.length)) corrupt();
        records[key] = { ...record } as unknown as AttachmentRetryRecord;
    }
    function keys(array: unknown[], pattern: RegExp): string[] {
        if (array.some(entry => typeof entry !== "string" || !pattern.test(entry))
            || new Set(array).size !== array.length) corrupt();
        return [...array] as string[];
    }
    return { formatVersion: 1, records,
        offlineAttachments: keys(value.offlineAttachments, IDENTITY_PATTERN),
        downloadAllVersions: keys(value.downloadAllVersions, VERSION_PATTERN),
        ...(value.authorizationFingerprint ? { authorizationFingerprint: value.authorizationFingerprint as string } : {}),
    };
}

export function attachmentVersionKey(reference: AttachmentVersionReference): string | null {
    if (!reference.id || !reference.contentVersion) return null;
    const key = `${reference.cardID}/${reference.id}/${reference.contentVersion}`.toLowerCase();
    return VERSION_PATTERN.test(key) ? key : null;
}

export function attachmentIdentityKey(version: string): string {
    if (!VERSION_PATTERN.test(version)) throw new Error("bad_attachment_identity");
    return version.slice(0, version.lastIndexOf("/"));
}

/** Durable exact-version retry and local cache state for one account/vault scope. */
export class AttachmentDownloadLedger {
    private state: AttachmentLedgerState;

    constructor(value?: unknown) {
        this.state = value === undefined
            ? { formatVersion: 1, records: {}, offlineAttachments: [], downloadAllVersions: [] }
            : parseAttachmentLedger(value);
    }

    toJSON(): AttachmentLedgerState { return parseAttachmentLedger(this.state); }
    record(version: string): AttachmentRetryRecord | undefined {
        const record = this.state.records[version];
        return record ? { ...record } : undefined;
    }
    get downloadingAll(): boolean { return this.state.downloadAllVersions.length > 0; }
    isKeptOffline(version: string): boolean {
        return this.state.offlineAttachments.includes(attachmentIdentityKey(version));
    }
    isBatchProtected(version: string): boolean { return this.state.downloadAllVersions.includes(version); }
    isReady(version: string, now = Date.now()): boolean {
        const record = this.state.records[version];
        if (!record) return true;
        if (record.evicted) return false;
        return record.failure === undefined || record.failure === "transient"
            && record.retryAt !== undefined && record.retryAt <= now;
    }
    request(version: string, resetFailures = false): void {
        attachmentIdentityKey(version);
        const record = this.state.records[version] ?? { failureCount: 0, evicted: false };
        record.evicted = false;
        if (resetFailures) {
            delete record.failure;
            delete record.retryAt;
            record.failureCount = 0;
        }
        this.state.records[version] = record;
    }
    access(version: string, now = Date.now()): void {
        attachmentIdentityKey(version);
        (this.state.records[version] ??= { failureCount: 0, evicted: false }).lastAccess = now;
    }
    fail(version: string, failure: AttachmentFailure, now = Date.now(), minimumDelay = 0): void {
        attachmentIdentityKey(version);
        const record = this.state.records[version] ?? { failureCount: 0, evicted: false };
        record.failure = failure;
        record.failureCount = Math.min(record.failureCount + 1, ATTACHMENT_RETRY_DELAYS_MS.length + 1);
        delete record.retryAt;
        if (failure === "transient" && record.failureCount <= ATTACHMENT_RETRY_DELAYS_MS.length) {
            const serverDelay = Number.isFinite(minimumDelay) ? Math.max(0, minimumDelay) : 0;
            record.retryAt = now + Math.max(ATTACHMENT_RETRY_DELAYS_MS[record.failureCount - 1], serverDelay);
        }
        this.state.records[version] = record;
    }
    succeed(version: string, now = Date.now()): void {
        attachmentIdentityKey(version);
        this.state.records[version] = { failureCount: 0, evicted: false, lastAccess: now };
    }
    evict(version: string): void {
        attachmentIdentityKey(version);
        (this.state.records[version] ??= { failureCount: 0, evicted: false }).evicted = true;
    }
    setKeptOffline(version: string, retained: boolean): void {
        const identity = attachmentIdentityKey(version);
        this.state.offlineAttachments = this.state.offlineAttachments.filter(key => key !== identity);
        if (retained) this.state.offlineAttachments.push(identity);
    }
    requestAll(references: AttachmentVersionReference[]): void {
        this.state.downloadAllVersions = [...new Set(references.map(attachmentVersionKey).filter((key): key is string => key !== null))];
        for (const reference of references) {
            const key = attachmentVersionKey(reference);
            if (key && reference.missing) this.request(key, true);
        }
        this.reconcile(references);
    }
    cancelAll(): void { this.state.downloadAllVersions = []; }
    reconcile(references: AttachmentVersionReference[]): void {
        const all = new Set(references.map(attachmentVersionKey).filter(key => key !== null));
        const missing = new Set(references.filter(reference => reference.missing).map(attachmentVersionKey));
        this.state.records = Object.fromEntries(Object.entries(this.state.records).filter(([key]) => all.has(key)));
        this.state.downloadAllVersions = this.state.downloadAllVersions.filter(key => all.has(key));
        if (!this.state.downloadAllVersions.some(key => missing.has(key))) this.cancelAll();
    }
    recoverNetwork(): void {
        for (const [key, record] of Object.entries(this.state.records)) {
            if (record.failure === "transient") this.request(key, true);
        }
    }
    authorize(fingerprint: string): void {
        if (!/^[0-9a-f]{64}$/.test(fingerprint)) throw new Error("bad_authorization_fingerprint");
        if (this.state.authorizationFingerprint === fingerprint) return;
        this.state.authorizationFingerprint = fingerprint;
        for (const [key, record] of Object.entries(this.state.records)) {
            if (record.failure === "authorization") this.request(key, true);
        }
    }
    nextRetry(references: AttachmentVersionReference[], now = Date.now()): number | null {
        const times = references.filter(reference => reference.missing).map(reference => {
            const key = attachmentVersionKey(reference);
            const record = key ? this.state.records[key] : undefined;
            return record && !record.evicted && record.failure === "transient" && record.retryAt !== undefined
                && record.retryAt > now ? record.retryAt : null;
        }).filter((time): time is number => time !== null);
        return times.length ? Math.min(...times) : null;
    }
}

/** Error text is never persisted; server Retry-After is measured in seconds. */
export function classifyAttachmentFailure(error: unknown): { failure: AttachmentFailure; minimumDelay: number } | null {
    const value = error as { name?: string; code?: string; status?: number; retryAfter?: number; message?: string } | null;
    const code = typeof value?.code === "string" ? value.code : value?.message;
    if (value?.name === "AbortError" || code === "session_changed" || code === "attachment_sync_deferred"
        || code === "attachment_policy_version_conflict" || code === "cache_version_conflict") return null;
    if (value?.name === "QuotaExceededError" || code === "attachment_cache_full") return { failure: "storage", minimumDelay: 0 };
    if (code?.includes("integrity") || code === "attachment_decrypt_failed" || code === "bad_attachment_data") {
        return { failure: "integrity", minimumDelay: 0 };
    }
    if (value?.status === 401) return { failure: "authorization", minimumDelay: 0 };
    if (value?.status === 404 || code === "attachment_version_missing" || code === "attachment_deleted") {
        return { failure: "unavailable", minimumDelay: 0 };
    }
    if (value?.name === "TimeoutError" || value?.status === 429 || value?.status !== undefined && value.status >= 500 && value.status <= 599
        || error instanceof TypeError || error instanceof RelayApiError && error.status === 0 && error.code === "network_error") {
        return { failure: "transient", minimumDelay: Number.isFinite(value?.retryAfter) ? Math.max(0, value?.retryAfter ?? 0) * 1000 : 0 };
    }
    return { failure: "permanent", minimumDelay: 0 };
}
