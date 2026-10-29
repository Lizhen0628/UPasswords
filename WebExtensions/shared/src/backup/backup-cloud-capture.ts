import {
    getVaultAttachment,
    getVaultSeq,
    listVaultAttachmentVersions,
    listVaultConflictHistory,
    listVaultConflicts,
    type RelayAttachmentVersion,
    type RelayConflict,
    type RelayItemRow,
    type RelayRetainedConflict,
} from "../api/relay.js";
import { readAttachmentReferences, type AttachmentReference } from "../core/attachments.js";
import {
    MAX_BACKUP_ARCHIVE_BYTES,
    MAX_BACKUP_MEMBER_BYTES,
    type BackupAttachmentDescriptor,
    type BackupConflictDescriptor,
    type BackupIssue,
} from "../core/portable-backup-package.js";

const LEGACY_CONTENT_VERSION = "00000000-0000-0000-0000-000000000000";
const REFERENCE_DATE_UNIX_SECONDS = 978_307_200;

export interface BackupCloudFragment {
    uuid: string;
    xml: string;
    kind: number;
    revision: number;
    modifiedMs: number;
}

export interface BackupCloudCaptureClient {
    getVaultSeq(token: string, vaultId: string): Promise<{ headSeq: number; passwordVersion: number }>;
    listVaultAttachmentVersions(token: string, vaultId: string): Promise<RelayAttachmentVersion[]>;
    listVaultConflicts(token: string, vaultId: string): Promise<RelayConflict[]>;
    listVaultConflictHistory(token: string, vaultId: string): Promise<RelayRetainedConflict[]>;
    getVaultAttachment(
        token: string, vaultId: string, version: RelayAttachmentVersion,
    ): Promise<Uint8Array>;
}

export interface BackupCloudCaptureOptions {
    token: string;
    vaultId: string;
    localCursor: number;
    localPasswordVersion: number;
    fragments: readonly BackupCloudFragment[];
    validate: () => Promise<void>;
    verifyCandidate: (row: RelayItemRow) => Promise<void>;
    onProgress?: (phase: "attachments" | "conflicts", completed: number, total: number) => void;
    client?: BackupCloudCaptureClient;
}

export interface BackupCloudCapture {
    headSequence?: number;
    attachments: BackupAttachmentDescriptor[];
    conflicts: BackupConflictDescriptor[];
    issues: BackupIssue[];
    payloadFiles: Map<string, Uint8Array>;
}

const defaultClient: BackupCloudCaptureClient = {
    getVaultSeq,
    listVaultAttachmentVersions,
    listVaultConflicts,
    listVaultConflictHistory,
    getVaultAttachment,
};

/** Capture cloud history into the native-compatible encrypted backup package. */
export async function captureBackupCloudHistory(
    options: BackupCloudCaptureOptions,
): Promise<BackupCloudCapture> {
    const client = options.client ?? defaultClient;
    const result: BackupCloudCapture = {
        attachments: [],
        conflicts: [],
        issues: [],
        payloadFiles: new Map(),
    };
    let inventory: BackupInventory;

    await options.validate();
    try {
        inventory = await readInventory(client, options.token, options.vaultId);
    } catch {
        result.issues.push({ cloudInventoryUnavailable: {} });
        result.issues.push({ retainedConflictHistoryUnavailable: {} });
        return result;
    }

    result.headSequence = inventory.headSequence;
    if (options.localCursor !== inventory.headSequence) {
        result.issues.push({
            localSnapshotBehindCloud: {
                localCursor: options.localCursor,
                cloudHead: inventory.headSequence,
            },
        });
    }
    if (options.localPasswordVersion !== inventory.passwordVersion) {
        result.issues.push({ cloudInventoryUnavailable: {} });
    }
    if (!inventory.retainedHistoryAvailable) {
        result.issues.push({ retainedConflictHistoryUnavailable: {} });
    }

    const attachmentReferences = readMissingAttachmentReferences(options.fragments, result.issues);
    const capturedAttachmentIDs = new Set<string>();
    let payloadBytes = 0;

    for (let index = 0; index < inventory.attachmentVersions.length; index += 1) {
        await options.validate();
        const version = inventory.attachmentVersions[index];
        options.onProgress?.("attachments", index, inventory.attachmentVersions.length);
        const identity = attachmentVersionIdentity(version.attachmentId, version.contentVersion);
        if (version.bytes > MAX_BACKUP_MEMBER_BYTES) {
            throw new Error("backup_payload_too_large");
        }

        let dekWrapped: Uint8Array;
        try {
            dekWrapped = decodeBase64(version.dekWrapped);
        } catch {
            result.issues.push(unavailableAttachment(version));
            continue;
        }
        const validWrappedKey = dekWrapped.length >= 28 && dekWrapped.length <= 256;
        dekWrapped.fill(0);
        if (!validWrappedKey) {
            result.issues.push(unavailableAttachment(version));
            continue;
        }

        let cipher: Uint8Array;
        try {
            cipher = await client.getVaultAttachment(options.token, options.vaultId, version);
        } catch {
            result.issues.push(unavailableAttachment(version));
            continue;
        }
        await options.validate();
        if (cipher.length !== version.bytes || await sha256Hex(cipher) !== version.sha256) {
            cipher.fill(0);
            result.issues.push(unavailableAttachment(version));
            continue;
        }
        payloadBytes += cipher.length;
        if (payloadBytes > MAX_BACKUP_ARCHIVE_BYTES) {
            cipher.fill(0);
            throw new Error("backup_file_too_large");
        }
        const contentVersion = version.contentVersion.toLowerCase();
        const attachmentID = version.attachmentId.toLowerCase();
        const fileName = `${attachmentID}-${contentVersion}.cipher`;
        result.payloadFiles.set(`Attachments/${fileName}`, cipher);
        result.attachments.push({
            attachmentID,
            cardID: version.cardUuid.toLowerCase(),
            contentVersion,
            isLegacyVersion: contentVersion === LEGACY_CONTENT_VERSION,
            dekWrapped: version.dekWrapped,
            sha256: version.sha256.toLowerCase(),
            bytes: version.bytes,
            isCurrent: version.isCurrent,
            fileName,
        });
        capturedAttachmentIDs.add(identity);
    }
    options.onProgress?.("attachments", inventory.attachmentVersions.length, inventory.attachmentVersions.length);

    appendMissingAttachmentIssues(attachmentReferences, inventory.attachmentVersions, capturedAttachmentIDs, result.issues);

    const allConflicts: Array<RelayConflict | RelayRetainedConflict> = [
        ...inventory.conflicts,
        ...inventory.retainedConflicts,
    ];
    for (let conflictIndex = 0; conflictIndex < allConflicts.length; conflictIndex += 1) {
        await options.validate();
        const conflict = allConflicts[conflictIndex];
        options.onProgress?.("conflicts", conflictIndex, allConflicts.length);
        const candidates = [];

        for (const candidate of conflict.candidates) {
            await options.validate();
            const fileName = candidate.op === "upsert" ? `${candidate.candidateId}.cipher` : undefined;
            let digest: string | undefined;
            if (candidate.op === "upsert") {
                const cipher = decodeBase64(candidate.bodyB64 ?? "");
                if (cipher.length > MAX_BACKUP_MEMBER_BYTES) throw new Error("backup_payload_too_large");
                digest = await sha256Hex(cipher);
                if (candidate.sha256 !== digest) {
                    result.issues.push(unavailableCandidate(conflict.conflictId, candidate.candidateId));
                } else {
                    try {
                        await options.verifyCandidate({
                            uuid: conflict.itemUuid,
                            kind: candidate.kind,
                            revision: candidate.revision,
                            bodyB64: candidate.bodyB64 ?? "",
                            modifiedMs: candidate.modifiedMs,
                        });
                    } catch {
                        result.issues.push(unavailableCandidate(conflict.conflictId, candidate.candidateId));
                    }
                    await options.validate();
                }
                payloadBytes += cipher.length;
                if (payloadBytes > MAX_BACKUP_ARCHIVE_BYTES) {
                    cipher.fill(0);
                    throw new Error("backup_file_too_large");
                }
                result.payloadFiles.set(`Conflicts/${conflict.conflictId}/${fileName}`, cipher);
            }
            candidates.push({
                candidateID: candidate.candidateId,
                kind: candidate.kind,
                isDelete: candidate.op === "delete",
                revision: candidate.revision,
                modifiedAt: dateToReferenceSeconds(candidate.modifiedMs),
                committedAt: dateToReferenceSeconds(candidate.committedMs),
                deviceName: candidate.deviceName,
                platform: candidate.platform,
                ...(digest === undefined ? {} : { sha256: digest }),
                ...(fileName === undefined ? {} : { fileName }),
            });
        }

        result.conflicts.push({
            conflictID: conflict.conflictId,
            itemUUID: conflict.itemUuid,
            baseRevision: conflict.baseRevision,
            currentRevision: conflict.currentRevision,
            currentDeletedSequence: conflict.currentDeletedSeq,
            generation: conflict.generation,
            createdAt: dateToReferenceSeconds(conflict.createdMs),
            updatedAt: dateToReferenceSeconds(conflict.updatedMs),
            ...( "resolvedMs" in conflict ? {
                resolvedAt: dateToReferenceSeconds(conflict.resolvedMs),
                expiresAt: dateToReferenceSeconds(conflict.expiresMs),
                ...(conflict.selectedCandidateId === undefined ? {} : {
                    selectedCandidateID: conflict.selectedCandidateId,
                }),
            } : {}),
            candidates,
        });
    }
    options.onProgress?.("conflicts", allConflicts.length, allConflicts.length);

    await options.validate();
    try {
        const finalInventory = await readInventory(client, options.token, options.vaultId);
        if (finalInventory.fingerprint !== inventory.fingerprint) {
            result.issues.push({ cloudInventoryChanged: {} });
        }
    } catch {
        result.issues.push({ cloudInventoryChanged: {} });
    }
    return { ...result, issues: uniqueIssues(result.issues) };
}

interface BackupInventory {
    headSequence: number;
    passwordVersion: number;
    attachmentVersions: RelayAttachmentVersion[];
    conflicts: RelayConflict[];
    retainedConflicts: RelayRetainedConflict[];
    retainedHistoryAvailable: boolean;
    fingerprint: string;
}

async function readInventory(
    client: BackupCloudCaptureClient,
    token: string,
    vaultId: string,
): Promise<BackupInventory> {
    const [sequence, attachmentVersions, conflicts, historyResult] = await Promise.all([
        client.getVaultSeq(token, vaultId),
        client.listVaultAttachmentVersions(token, vaultId),
        client.listVaultConflicts(token, vaultId),
        client.listVaultConflictHistory(token, vaultId).then(
            retainedConflicts => ({ retainedConflicts, available: true }),
            () => ({ retainedConflicts: [], available: false }),
        ),
    ]);
    const { retainedConflicts } = historyResult;
    const attachmentIdentities = new Set<string>();
    const currentAttachmentIDs = new Set<string>();
    for (const version of attachmentVersions) {
        const identity = attachmentVersionIdentity(version.attachmentId, version.contentVersion);
        const attachmentID = version.attachmentId.toLowerCase();
        if (attachmentIdentities.has(identity)
            || version.isCurrent && currentAttachmentIDs.has(attachmentID)) {
            throw new Error("backup_invalid_inventory");
        }
        attachmentIdentities.add(identity);
        if (version.isCurrent) currentAttachmentIDs.add(attachmentID);
    }
    const conflictIDs = new Set<string>();
    for (const conflict of [...conflicts, ...retainedConflicts]) {
        if (conflictIDs.has(conflict.conflictId)) throw new Error("backup_invalid_inventory");
        conflictIDs.add(conflict.conflictId);
    }
    return {
        headSequence: sequence.headSeq,
        passwordVersion: sequence.passwordVersion,
        attachmentVersions,
        conflicts,
        retainedConflicts,
        retainedHistoryAvailable: historyResult.available,
        fingerprint: await inventoryFingerprint(
            sequence,
            attachmentVersions,
            conflicts,
            retainedConflicts,
            historyResult.available),
    };
}

async function inventoryFingerprint(
    sequence: { headSeq: number; passwordVersion: number },
    attachmentVersions: RelayAttachmentVersion[],
    conflicts: RelayConflict[],
    retainedConflicts: RelayRetainedConflict[],
    retainedHistoryAvailable: boolean,
): Promise<string> {
    const attachments = await Promise.all(attachmentVersions.map(async version => ({
        attachmentId: version.attachmentId.toLowerCase(),
        cardUuid: version.cardUuid.toLowerCase(),
        contentVersion: version.contentVersion.toLowerCase(),
        dekWrappedDigest: await digestString(version.dekWrapped),
        sha256: version.sha256.toLowerCase(),
        bytes: version.bytes,
        isCurrent: version.isCurrent,
    })));
    attachments.sort((left, right) => attachmentVersionIdentity(left.attachmentId, left.contentVersion)
        .localeCompare(attachmentVersionIdentity(right.attachmentId, right.contentVersion)));

    const conflictEntries = await Promise.all(conflicts.map(async conflict => ({
        state: "open",
        conflictId: conflict.conflictId,
        itemUuid: conflict.itemUuid.toLowerCase(),
        baseRevision: conflict.baseRevision,
        currentRevision: conflict.currentRevision,
        currentDeletedSeq: conflict.currentDeletedSeq,
        generation: conflict.generation,
        createdMs: conflict.createdMs,
        updatedMs: conflict.updatedMs,
        candidates: await Promise.all(conflict.candidates.map(async candidate => ({
            candidateId: candidate.candidateId,
            kind: candidate.kind,
            op: candidate.op,
            revision: candidate.revision,
            modifiedMs: candidate.modifiedMs,
            committedMs: candidate.committedMs,
            deviceName: candidate.deviceName,
            platform: candidate.platform,
            sourceSessionId: candidate.sourceSessionId ?? null,
            bodyDigest: candidate.bodyB64 === undefined ? null : await digestBase64(candidate.bodyB64),
            declaredDigest: candidate.sha256 ?? null,
        }))).then(entries => entries.sort((left, right) => left.candidateId.localeCompare(right.candidateId))),
    })));
    const retainedConflictEntries = await Promise.all(retainedConflicts.map(async conflict => ({
        state: "retained",
        conflictId: conflict.conflictId,
        itemUuid: conflict.itemUuid.toLowerCase(),
        baseRevision: conflict.baseRevision,
        currentRevision: conflict.currentRevision,
        currentDeletedSeq: conflict.currentDeletedSeq,
        generation: conflict.generation,
        createdMs: conflict.createdMs,
        updatedMs: conflict.updatedMs,
        resolvedMs: conflict.resolvedMs,
        expiresMs: conflict.expiresMs,
        selectedCandidateId: conflict.selectedCandidateId ?? null,
        candidates: await Promise.all(conflict.candidates.map(async candidate => ({
            candidateId: candidate.candidateId,
            kind: candidate.kind,
            op: candidate.op,
            revision: candidate.revision,
            modifiedMs: candidate.modifiedMs,
            committedMs: candidate.committedMs,
            deviceName: candidate.deviceName,
            platform: candidate.platform,
            sourceSessionId: candidate.sourceSessionId ?? null,
            bodyDigest: candidate.bodyB64 === undefined ? null : await digestBase64(candidate.bodyB64),
            declaredDigest: candidate.sha256 ?? null,
        }))).then(entries => entries.sort((left, right) => left.candidateId.localeCompare(right.candidateId))),
    })));
    const allConflictEntries = [...conflictEntries, ...retainedConflictEntries]
        .sort((left, right) => left.conflictId.localeCompare(right.conflictId));

    return digestString(JSON.stringify({
        headSequence: sequence.headSeq,
        passwordVersion: sequence.passwordVersion,
        attachments,
        conflicts: allConflictEntries,
        retainedHistoryAvailable,
    }));
}

function readMissingAttachmentReferences(
    fragments: readonly BackupCloudFragment[],
    issues: BackupIssue[],
): { cardID: string; reference: AttachmentReference }[] {
    const references: { cardID: string; reference: AttachmentReference }[] = [];
    for (const fragment of fragments) {
        if (fragment.kind !== 1) continue;
        try {
            for (const reference of readAttachmentReferences(fragment.xml, fragment.uuid)) {
                if (reference.missing) references.push({ cardID: fragment.uuid.toLowerCase(), reference });
            }
        } catch {
            issues.push({ attachmentIdentityUnavailable: { cardID: fragment.uuid.toLowerCase() } });
        }
    }
    return references;
}

function appendMissingAttachmentIssues(
    references: { cardID: string; reference: AttachmentReference }[],
    versions: RelayAttachmentVersion[],
    captured: Set<string>,
    issues: BackupIssue[],
): void {
    const byIdentity = new Map(versions.map(version => [
        attachmentVersionIdentity(version.attachmentId, version.contentVersion), version,
    ]));
    for (const { cardID, reference } of references) {
        if (!reference.id || !reference.contentVersion) {
            issues.push({ attachmentIdentityUnavailable: { cardID } });
            continue;
        }
        const key = attachmentVersionIdentity(reference.id, reference.contentVersion);
        const version = byIdentity.get(key);
        if (!version || version.cardUuid.toLowerCase() !== cardID || !captured.has(key)) {
            issues.push({
                attachmentVersionUnavailable: {
                    attachmentID: reference.id,
                    contentVersion: reference.contentVersion,
                },
            });
        }
    }
}

function unavailableAttachment(version: RelayAttachmentVersion): BackupIssue {
    return {
        attachmentVersionUnavailable: {
            attachmentID: version.attachmentId.toLowerCase(),
            contentVersion: version.contentVersion.toLowerCase(),
        },
    };
}

function unavailableCandidate(conflictID: string, candidateID: string): BackupIssue {
    return { conflictCandidateUnavailable: { conflictID, candidateID } };
}

function attachmentVersionIdentity(attachmentID: string, contentVersion: string): string {
    return `${attachmentID.toLowerCase()}:${contentVersion.toLowerCase()}`;
}

function dateToReferenceSeconds(milliseconds: number): number {
    return milliseconds / 1_000 - REFERENCE_DATE_UNIX_SECONDS;
}

function decodeBase64(value: string): Uint8Array {
    if (!value || value.length % 4 !== 0
        || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value)) {
        throw new Error("backup_invalid_payload");
    }
    const binary = atob(value);
    if (btoa(binary) !== value) throw new Error("backup_invalid_payload");
    const bytes = new Uint8Array(binary.length);
    for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
    return bytes;
}

async function digestBase64(value: string): Promise<string> {
    const bytes = decodeBase64(value);
    try {
        return await sha256Hex(bytes);
    } finally {
        bytes.fill(0);
    }
}

async function digestString(value: string): Promise<string> {
    return sha256Hex(new TextEncoder().encode(value));
}

async function sha256Hex(bytes: Uint8Array): Promise<string> {
    const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes as BufferSource));
    return Array.from(digest, byte => byte.toString(16).padStart(2, "0")).join("");
}

function uniqueIssues(issues: BackupIssue[]): BackupIssue[] {
    const unique = new Map(issues.map(issue => [JSON.stringify(issue), issue]));
    return [...unique.entries()].sort(([left], [right]) => left.localeCompare(right)).map(([, issue]) => issue);
}
