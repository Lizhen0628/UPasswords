import type { RelayAttachmentVersion, RelayItemRow } from "../api/relay.js";
import { discardAttachmentBytes, readAttachmentReferences } from "./attachments.js";
import {
    ATTACHMENT_CACHE_BUDGET_BYTES,
    AttachmentDownloadLedger,
    attachmentVersionKey,
    type AttachmentVersionReference,
} from "./attachment-download-policy.js";

/** Decrypted fragments stay in the trusted unlocked session and are never persisted directly. */
export interface AttachmentCacheFragment {
    row: RelayItemRow;
    xml: string;
}

export interface AttachmentCachePlan {
    fragments: AttachmentCacheFragment[];
    ledger: AttachmentDownloadLedger;
    evictedVersions: string[];
    cachedBytes: number;
    hasCapacity: boolean;
}

export function attachmentReferencesIn(fragments: AttachmentCacheFragment[]): AttachmentVersionReference[] {
    return fragments.filter(fragment => fragment.row.kind === 1).flatMap(fragment =>
        readAttachmentReferences(fragment.xml, fragment.row.uuid).map(reference => ({
            cardID: fragment.row.uuid.toLowerCase(), ...reference,
        })));
}

export function attachmentByteCount(base64: string | undefined): number {
    if (!base64) return 0;
    return base64.length / 4 * 3 - (base64.endsWith("==") ? 2 : base64.endsWith("=") ? 1 : 0);
}

/**
 * Plan LRU eviction from confirmed encrypted-cache rows, requiring exact remote availability.
 * Drafts must be excluded by the caller; conflict parents and explicitly used versions are protected.
 * If the budget cannot be met, return all original inputs unchanged, including suppression policy.
 */
export function planAttachmentCache(options: {
    fragments: AttachmentCacheFragment[];
    ledger: AttachmentDownloadLedger;
    remoteVersions: RelayAttachmentVersion[];
    conflictCardIDs: Set<string>;
    protectedCardIDs?: Set<string>;
    budgetBytes?: number;
    incomingBytes?: number;
}): AttachmentCachePlan {
    const { fragments, ledger, remoteVersions, conflictCardIDs } = options;
    const budget = options.budgetBytes ?? ATTACHMENT_CACHE_BUDGET_BYTES;
    const incoming = options.incomingBytes ?? 0;
    if (!Number.isSafeInteger(budget) || budget < 0 || !Number.isSafeInteger(incoming) || incoming < 0) {
        throw new Error("attachment_cache_invalid_budget");
    }
    const remote = new Set(remoteVersions.filter(version => version.contentVersion !== null)
        .map(version => `${version.cardUuid}/${version.attachmentId}/${version.contentVersion}`.toLowerCase()));
    const candidates: { key: string; cardID: string; id: string; version: string; bytes: number; access: number }[] = [];
    let cachedBytes = 0;
    for (const fragment of fragments) {
        if (fragment.row.kind !== 1) continue;
        const cardID = fragment.row.uuid.toLowerCase();
        for (const reference of readAttachmentReferences(fragment.xml, cardID)) {
            if (reference.missing) continue;
            const bytes = attachmentByteCount(reference.base64);
            cachedBytes += bytes;
            if (!Number.isSafeInteger(cachedBytes)) throw new Error("attachment_cache_invalid_size");
            const key = attachmentVersionKey({ cardID, ...reference });
            if (!key || !reference.id || !reference.contentVersion || bytes === 0 || fragment.row.revision < 1
                || !remote.has(key) || conflictCardIDs.has(cardID) || options.protectedCardIDs?.has(cardID)
                || ledger.isKeptOffline(key) || ledger.isBatchProtected(key)) continue;
            candidates.push({ key, cardID, id: reference.id, version: reference.contentVersion,
                bytes, access: ledger.record(key)?.lastAccess ?? 0 });
        }
    }
    const originalBytes = cachedBytes;
    const target = Math.max(0, budget - incoming);
    const evicted: typeof candidates = [];
    for (const candidate of candidates.sort((left, right) => left.access - right.access
        || (left.key < right.key ? -1 : left.key > right.key ? 1 : 0))) {
        if (cachedBytes <= target) break;
        evicted.push(candidate);
        cachedBytes -= candidate.bytes;
    }
    if (incoming > budget || cachedBytes > target) {
        return { fragments, ledger, evictedVersions: [], cachedBytes: originalBytes, hasCapacity: false };
    }
    const nextLedger = new AttachmentDownloadLedger(ledger.toJSON());
    const nextFragments = fragments.map(fragment => {
        let xml = fragment.xml;
        for (const candidate of evicted.filter(entry => entry.cardID === fragment.row.uuid.toLowerCase())) {
            xml = discardAttachmentBytes(xml, fragment.row.uuid, candidate.id, candidate.version);
            nextLedger.evict(candidate.key);
        }
        return { row: fragment.row, xml };
    });
    return { fragments: nextFragments, ledger: nextLedger,
        evictedVersions: evicted.map(entry => entry.key), cachedBytes, hasCapacity: true };
}
