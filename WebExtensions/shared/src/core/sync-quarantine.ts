import { base64ToBytes, bytesToBase64, isValidRelayItemRow, type RelayItemRow } from "../api/relay.js";

export type SyncQuarantineSource = "change" | "snapshot";
export type SyncQuarantineReason = "authenticationFailed" | "unsupportedFormat";

export interface SyncQuarantineIdentity {
    id: string;
    uuid: string;
    revision: number;
    source: SyncQuarantineSource;
    sequence: number | null;
    reason: SyncQuarantineReason;
    capturedAt: number;
}

export interface EncryptedSyncQuarantineItem extends SyncQuarantineIdentity {
    encryptedPayloadB64: string;
}

const QUARANTINE_AAD_PREFIX = "UPW-SYNC-QUARANTINE-V1\0";
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAX_QUARANTINE_ITEMS = 10_000;
const MAX_QUARANTINE_CIPHER_B64_LENGTH = 45_000_000;
const MAX_QUARANTINE_PAYLOAD_BYTES = 32 * 1024 * 1024;

/** Validates non-secret identity metadata before storage or cryptographic use. */
export function isValidSyncQuarantineIdentity(value: unknown): value is SyncQuarantineIdentity {
    if (typeof value !== "object" || value === null) return false;
    const item = value as Record<string, unknown>;
    if (Object.keys(item).some(key => ![
        "id", "uuid", "revision", "source", "sequence", "reason", "capturedAt",
    ].includes(key)) || typeof item.uuid !== "string" || !UUID_PATTERN.test(item.uuid)
        || !Number.isSafeInteger(item.revision) || (item.revision as number) < 1
        || (item.source !== "change" && item.source !== "snapshot")
        || (item.reason !== "authenticationFailed" && item.reason !== "unsupportedFormat")
        || !Number.isSafeInteger(item.capturedAt) || (item.capturedAt as number) < 0) return false;

    if (item.source === "change") {
        return Number.isSafeInteger(item.sequence) && (item.sequence as number) > 0
            && item.id === `change:${item.sequence}`;
    }
    return item.sequence === null
        && item.id === `snapshot:${item.uuid.toLowerCase()}:${item.revision}`;
}

/** Validates a persisted encrypted quarantine envelope without opening its payload. */
export function isValidEncryptedSyncQuarantineItem(
    value: unknown,
): value is EncryptedSyncQuarantineItem {
    if (typeof value !== "object" || value === null) return false;
    const record = value as Record<string, unknown>;
    if (Object.keys(record).some(key => ![
        "id", "uuid", "revision", "source", "sequence", "reason", "capturedAt", "encryptedPayloadB64",
    ].includes(key)) || !isValidSyncQuarantineIdentity({
        id: record.id,
        uuid: record.uuid,
        revision: record.revision,
        source: record.source,
        sequence: record.sequence,
        reason: record.reason,
        capturedAt: record.capturedAt,
    }) || typeof record.encryptedPayloadB64 !== "string"
        || record.encryptedPayloadB64.length < 40
        || record.encryptedPayloadB64.length > MAX_QUARANTINE_CIPHER_B64_LENGTH
        || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(record.encryptedPayloadB64)) {
        return false;
    }
    return true;
}

/** Validates and normalizes an encrypted quarantine collection. */
export function parseEncryptedSyncQuarantineItems(value: unknown): EncryptedSyncQuarantineItem[] {
    if (!Array.isArray(value) || value.length > MAX_QUARANTINE_ITEMS) {
        throw new Error("sync_quarantine_invalid_collection");
    }
    const seen = new Set<string>();
    return value.map(item => {
        if (!isValidEncryptedSyncQuarantineItem(item) || seen.has(item.id)) {
            throw new Error("sync_quarantine_invalid_item");
        }
        seen.add(item.id);
        return { ...item };
    });
}

/** VEK-encrypts one authenticated server row with quarantine-specific AAD. */
export async function encryptSyncQuarantinePayload(
    row: RelayItemRow,
    vaultKey: Uint8Array,
    identity: SyncQuarantineIdentity,
): Promise<string> {
    if (!isValidSyncQuarantineIdentity(identity) || !isValidRelayItemRow(row)
        || row.uuid.toLowerCase() !== identity.uuid.toLowerCase()
        || row.revision !== identity.revision || vaultKey.length !== 32) {
        throw new Error("sync_quarantine_invalid_payload");
    }
    const plaintext = new TextEncoder().encode(JSON.stringify({ version: 1, row }));
    if (plaintext.length > MAX_QUARANTINE_PAYLOAD_BYTES) {
        plaintext.fill(0);
        throw new Error("sync_quarantine_payload_too_large");
    }
    try {
        const key = await crypto.subtle.importKey("raw", vaultKey as BufferSource, "AES-GCM", false, ["encrypt"]);
        const nonce = crypto.getRandomValues(new Uint8Array(12));
        const sealed = new Uint8Array(await crypto.subtle.encrypt(
            { name: "AES-GCM", iv: nonce as BufferSource,
                additionalData: quarantineAAD(identity) as BufferSource }, key, plaintext as BufferSource,
        ));
        const combined = new Uint8Array(nonce.length + sealed.length);
        combined.set(nonce);
        combined.set(sealed, nonce.length);
        sealed.fill(0);
        const encoded = bytesToBase64(combined);
        combined.fill(0);
        return encoded;
    } catch {
        throw new Error("sync_quarantine_encrypt_failed");
    } finally {
        plaintext.fill(0);
    }
}

/** Opens a quarantine payload and checks its row identity against the authenticated metadata. */
export async function decryptSyncQuarantinePayload(
    item: EncryptedSyncQuarantineItem,
    vaultKey: Uint8Array,
): Promise<RelayItemRow> {
    if (!isValidEncryptedSyncQuarantineItem(item) || vaultKey.length !== 32) {
        throw new Error("quarantine_decrypt_failed");
    }
    const combined = base64ToBytes(item.encryptedPayloadB64);
    if (combined.length < 28) throw new Error("quarantine_decrypt_failed");
    let plaintext: Uint8Array | undefined;
    try {
        const key = await crypto.subtle.importKey("raw", vaultKey as BufferSource, "AES-GCM", false, ["decrypt"]);
        plaintext = new Uint8Array(await crypto.subtle.decrypt(
            {
                name: "AES-GCM",
                iv: combined.slice(0, 12) as BufferSource,
                additionalData: quarantineAAD(item) as BufferSource,
            },
            key,
            combined.slice(12) as BufferSource,
        ));
        if (plaintext.length > MAX_QUARANTINE_PAYLOAD_BYTES) throw new Error("quarantine_decrypt_failed");
        const decoded: unknown = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(plaintext));
        if (typeof decoded !== "object" || decoded === null
            || Object.keys(decoded).length !== 2
            || !Object.hasOwn(decoded, "version") || !Object.hasOwn(decoded, "row")) {
            throw new Error("quarantine_decrypt_failed");
        }
        const payload = decoded as { version?: unknown; row?: unknown };
        if (payload.version !== 1 || !isValidRelayItemRow(payload.row)
            || payload.row.uuid.toLowerCase() !== item.uuid.toLowerCase()
            || payload.row.revision !== item.revision) {
            throw new Error("quarantine_decrypt_failed");
        }
        return { ...payload.row };
    } catch {
        throw new Error("quarantine_decrypt_failed");
    } finally {
        combined.fill(0);
        plaintext?.fill(0);
    }
}

function quarantineAAD(identity: SyncQuarantineIdentity): Uint8Array {
    return new TextEncoder().encode([
        QUARANTINE_AAD_PREFIX,
        identity.id,
        identity.uuid.toLowerCase(),
        identity.revision,
        identity.source,
        identity.sequence ?? "",
        identity.reason,
        identity.capturedAt,
    ].join("\0"));
}
