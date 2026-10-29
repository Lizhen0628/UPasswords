import {
    decryptAttachmentVersion,
    decryptBody,
    decryptItemBody,
    encryptBody,
    encryptItemBody,
    envelopeChangedAt,
    rewrapAttachmentDEK,
    unwrapEnvelope,
    wrapEnvelope,
    VaultCryptoError,
} from "./vault-crypto.js";
import {
    createPortableBackupArchive,
    readPortableBackupArchive,
} from "./portable-backup-archive.js";

const MANIFEST_AAD = new TextEncoder().encode("UPW-BACKUP-MANIFEST-V1");
const RESTORE_DEPENDENCIES_AAD = new TextEncoder().encode("UPW-BACKUP-RESTORE-DEPENDENCIES-V1");
const REFERENCE_DATE_UNIX_SECONDS = 978_307_200;
export const MAX_BACKUP_SNAPSHOT_BYTES = 16 * 1024 * 1024;
export const MAX_BACKUP_ARCHIVE_BYTES = 512 * 1024 * 1024;
export const MAX_BACKUP_MEMBER_BYTES = 128 * 1024 * 1024;

export type BackupIssue =
    | { cloudInventoryUnavailable: Record<string, never> }
    | { cloudInventoryChanged: Record<string, never> }
    | { retainedConflictHistoryUnavailable: Record<string, never> }
    | { localSnapshotBehindCloud: { localCursor: number; cloudHead: number } }
    | { localConflictUnavailable: { itemID: string } }
    | { attachmentIdentityUnavailable: { cardID: string } }
    | { attachmentVersionUnavailable: { attachmentID: string; contentVersion: string } }
    | { conflictCandidateUnavailable: { conflictID: string; candidateID: string } };

export interface BackupAttachmentDescriptor {
    attachmentID: string;
    cardID: string;
    contentVersion: string;
    isLegacyVersion: boolean;
    dekWrapped: string;
    sha256: string;
    bytes: number;
    isCurrent: boolean;
    fileName: string;
}

export interface BackupCandidateDescriptor {
    candidateID: string;
    kind: number;
    isDelete: boolean;
    revision: number;
    modifiedAt: number;
    committedAt: number;
    deviceName: string;
    platform: string;
    sha256?: string;
    fileName?: string;
}

export interface BackupConflictDescriptor {
    conflictID: string;
    itemUUID: string;
    baseRevision: number;
    currentRevision: number;
    currentDeletedSequence: number;
    generation: number;
    createdAt: number;
    updatedAt: number;
    resolvedAt?: number;
    expiresAt?: number;
    selectedCandidateID?: string;
    candidates: BackupCandidateDescriptor[];
}

export interface BackupInfo {
    version: 1;
    createdAt: number;
    isComplete: boolean;
    attachmentVersionCount: number;
    conflictCount: number;
    conflictCandidateCount: number;
    issueCount: number;
}

export interface BackupManifest {
    version: 1;
    createdAt: number;
    bodyDigest: string;
    envelopeDigest: string;
    headSequence?: number;
    attachments: BackupAttachmentDescriptor[];
    conflicts: BackupConflictDescriptor[];
    issues: BackupIssue[];
}

export interface BackupPayloadMetadata {
    createdAt: Date;
    headSequence?: number;
    attachments: BackupAttachmentDescriptor[];
    conflicts: BackupConflictDescriptor[];
    issues: BackupIssue[];
}

export interface BackupInspection {
    info: BackupInfo;
    manifest: BackupManifest;
    xml: string;
    payloadFiles: ReadonlyMap<string, Blob>;
    quarantinedPayloadFiles: ReadonlyMap<string, Blob>;
    issues: BackupIssue[];
    isComplete: boolean;
    verificationToken: string;
}

export interface BackupRestoreOptions {
    sourcePassword: string;
    destinationPassword: string;
    expectedVerificationToken: string;
    allowIncomplete: boolean;
}

export interface PreparedBackupRestore {
    archive: Blob;
    historyCipher: Uint8Array;
    info: BackupInfo;
    issues: BackupIssue[];
    isComplete: boolean;
}

interface LoadedBackup extends BackupInspection {
    sourceEnvelope: Uint8Array;
    vaultKey: Uint8Array;
}

export interface SealedBackupPayload {
    body: Uint8Array;
    manifest: Uint8Array;
    info: BackupInfo;
}

/** Encrypt the native snapshot and Codable-compatible manifest while the key remains in the caller's trusted context. */
export async function sealBackupPayload(
    xml: string,
    envelope: Uint8Array,
    metadata: BackupPayloadMetadata,
    vaultKey: Uint8Array,
): Promise<SealedBackupPayload> {
    if (vaultKey.length !== 32 || envelope.length > 1_024 || envelopeChangedAt(envelope) === null
        || !Number.isFinite(metadata.createdAt.getTime())) {
        throw new Error("backup_invalid_payload");
    }
    validateMetadata(metadata);
    const snapshotBytes = new TextEncoder().encode(xml);
    if (snapshotBytes.length > MAX_BACKUP_SNAPSHOT_BYTES) {
        snapshotBytes.fill(0);
        throw new Error("backup_snapshot_too_large");
    }
    snapshotBytes.fill(0);
    validateSnapshotXML(xml);
    const body = await encryptBody(xml, vaultKey);
    const manifestObject = {
        version: 1,
        createdAt: dateToReferenceSeconds(metadata.createdAt),
        bodyDigest: await digestBase64(body),
        envelopeDigest: await digestBase64(envelope),
        ...(metadata.headSequence === undefined ? {} : { headSequence: metadata.headSequence }),
        attachments: metadata.attachments,
        conflicts: metadata.conflicts,
        issues: metadata.issues,
    };
    const encodedManifest = new TextEncoder().encode(JSON.stringify(manifestObject));
    try {
        const key = await crypto.subtle.importKey("raw", vaultKey as BufferSource, "AES-GCM", false, ["encrypt"]);
        const nonce = crypto.getRandomValues(new Uint8Array(12));
        const ciphertext = new Uint8Array(await crypto.subtle.encrypt(
            { name: "AES-GCM", iv: nonce, additionalData: MANIFEST_AAD },
            key,
            encodedManifest,
        ));
        const manifest = new Uint8Array(nonce.length + ciphertext.length);
        manifest.set(nonce, 0);
        manifest.set(ciphertext, nonce.length);
        return { body, manifest, info: createBackupInfo(metadata) };
    } finally {
        encodedManifest.fill(0);
    }
}

/** Authenticate and open the manifest with the native package AAD and combined AES-GCM layout. */
export async function openBackupManifest(
    sealed: Uint8Array,
    vaultKey: Uint8Array,
): Promise<BackupManifest> {
    if (vaultKey.length !== 32 || sealed.length < 28) throw new Error("backup_invalid_manifest");
    const key = await crypto.subtle.importKey("raw", vaultKey as BufferSource, "AES-GCM", false, ["decrypt"]);
    let plaintext: Uint8Array | undefined;
    try {
        plaintext = new Uint8Array(await crypto.subtle.decrypt(
            { name: "AES-GCM", iv: sealed.slice(0, 12), additionalData: MANIFEST_AAD },
            key,
            sealed.slice(12),
        ));
        const value: unknown = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(plaintext));
        return parseManifest(value);
    } catch {
        throw new Error("backup_manifest_authentication_failed");
    } finally {
        plaintext?.fill(0);
    }
}

/** Authenticate a package and expose only declared payloads that pass their stored digest checks. */
export async function inspectBackupArchive(archive: Blob, password: string): Promise<BackupInspection> {
    const loaded = await loadBackupArchive(archive, password);
    try {
        return {
            info: loaded.info,
            manifest: loaded.manifest,
            xml: loaded.xml,
            payloadFiles: loaded.payloadFiles,
            quarantinedPayloadFiles: loaded.quarantinedPayloadFiles,
            issues: loaded.issues,
            isComplete: loaded.isComplete,
            verificationToken: loaded.verificationToken,
        };
    } finally {
        loaded.vaultKey.fill(0);
        loaded.sourceEnvelope.fill(0);
    }
}

/** Re-encrypt a verified backup as a new-password local copy without mutating the source archive. */
export async function prepareBackupRestore(
    archive: Blob,
    options: BackupRestoreOptions,
): Promise<PreparedBackupRestore> {
    const source = await loadBackupArchive(archive, options.sourcePassword);
    let destinationKey: Uint8Array | undefined;
    let destinationEnvelope: Uint8Array | undefined;
    const issues = [...source.issues];
    const issueKeys = new Set(issues.map(issue => JSON.stringify(issue)));
    const restoredAttachments: BackupAttachmentDescriptor[] = [];
    const restoredConflicts: BackupConflictDescriptor[] = [];
    const payloadFiles = new Map<string, Blob | Uint8Array>();

    const addIssue = (issue: BackupIssue): void => {
        const key = JSON.stringify(issue);
        if (issueKeys.has(key)) return;
        issueKeys.add(key);
        issues.push(issue);
    };

    try {
        if (source.verificationToken !== options.expectedVerificationToken) {
            throw new Error("backup_package_changed");
        }
        if (!source.isComplete && !options.allowIncomplete) {
            throw new Error("backup_incomplete_confirmation_required");
        }
        if (!options.destinationPassword) throw new Error("backup_invalid_destination_password");

        const wrapped = await wrapEnvelope(options.destinationPassword);
        destinationKey = wrapped.vek;
        destinationEnvelope = wrapped.envelope;
        for (const attachment of source.manifest.attachments) {
            const path = `Attachments/${attachment.fileName}`;
            const file = source.payloadFiles.get(path) ?? source.quarantinedPayloadFiles.get(path);
            if (!file) {
                restoredAttachments.push(attachment);
                continue;
            }
            if (source.quarantinedPayloadFiles.has(path)) {
                restoredAttachments.push(attachment);
                payloadFiles.set(path, file);
                continue;
            }

            let cipher: Uint8Array | undefined;
            let wrappedDEK: Uint8Array | undefined;
            let plaintext: Uint8Array | undefined;
            let rewrappedDEK: Uint8Array | undefined;
            try {
                cipher = await readSmallBytes(file);
                wrappedDEK = decodeBase64(attachment.dekWrapped);
                plaintext = await decryptAttachmentVersion(
                    cipher,
                    wrappedDEK,
                    source.vaultKey,
                    attachment.attachmentID,
                    attachment.contentVersion,
                );
                rewrappedDEK = await rewrapAttachmentDEK(
                    wrappedDEK,
                    source.vaultKey,
                    destinationKey,
                    attachment.attachmentID,
                    attachment.contentVersion,
                );
                restoredAttachments.push({ ...attachment, dekWrapped: encodeBase64(rewrappedDEK) });
                payloadFiles.set(path, cipher);
                cipher = undefined;
            } catch (error) {
                if (!(error instanceof VaultCryptoError)
                    || error.message !== "attachment_decrypt_failed") throw error;
                addIssue({ attachmentVersionUnavailable: {
                    attachmentID: attachment.attachmentID,
                    contentVersion: attachment.contentVersion,
                } });
                restoredAttachments.push(attachment);
                if (cipher) payloadFiles.set(path, cipher);
                cipher = undefined;
            } finally {
                cipher?.fill(0);
                wrappedDEK?.fill(0);
                plaintext?.fill(0);
                rewrappedDEK?.fill(0);
            }
        }

        for (const conflict of source.manifest.conflicts) {
            const candidates: BackupCandidateDescriptor[] = [];
            for (const candidate of conflict.candidates) {
                if (!candidate.fileName) {
                    candidates.push(candidate);
                    continue;
                }
                const path = `Conflicts/${conflict.conflictID}/${candidate.fileName}`;
                const file = source.payloadFiles.get(path) ?? source.quarantinedPayloadFiles.get(path);
                if (!file || source.quarantinedPayloadFiles.has(path)) {
                    candidates.push(candidate);
                    if (file) payloadFiles.set(path, file);
                    continue;
                }
                let cipher: Uint8Array | undefined;
                let reencrypted: Uint8Array | undefined;
                try {
                    cipher = await readSmallBytes(file);
                    const xml = await decryptItemBody(cipher, source.vaultKey, conflict.itemUUID);
                    reencrypted = await encryptItemBody(xml, destinationKey, conflict.itemUUID);
                    const digest = await digestHex(reencrypted);
                    payloadFiles.set(path, reencrypted);
                    candidates.push({ ...candidate, sha256: digest });
                    reencrypted = undefined;
                } catch (error) {
                    if (!(error instanceof VaultCryptoError)
                        || !["item_decrypt_failed", "invalid_item_encoding"].includes(error.message)) throw error;
                    addIssue({ conflictCandidateUnavailable: {
                        conflictID: conflict.conflictID,
                        candidateID: candidate.candidateID,
                    } });
                    candidates.push(candidate);
                    if (cipher) payloadFiles.set(path, cipher);
                    cipher = undefined;
                } finally {
                    cipher?.fill(0);
                    reencrypted?.fill(0);
                }
            }
            restoredConflicts.push({ ...conflict, candidates });
        }

        const metadata: BackupPayloadMetadata = {
            createdAt: new Date((source.manifest.createdAt + REFERENCE_DATE_UNIX_SECONDS) * 1_000),
            ...(source.manifest.headSequence === undefined ? {} : { headSequence: source.manifest.headSequence }),
            attachments: restoredAttachments,
            conflicts: restoredConflicts,
            issues,
        };
        const sealed = await sealBackupPayload(source.xml, destinationEnvelope, metadata, destinationKey);
        return {
            archive: createBackupArchive(sealed, destinationEnvelope, payloadFiles),
            historyCipher: await sealBackupRestoreDependencies(source.sourceEnvelope, destinationKey),
            info: sealed.info,
            issues,
            isComplete: issues.length === 0,
        };
    } finally {
        source.vaultKey.fill(0);
        destinationKey?.fill(0);
        destinationEnvelope?.fill(0);
    }
}

/** Open preserved source-key dependencies only after unlocking the restored copy's VEK. */
export async function openBackupRestoreDependencies(
    sealed: Uint8Array,
    vaultKey: Uint8Array,
): Promise<Uint8Array> {
    if (vaultKey.length !== 32 || sealed.length < 28) {
        throw new Error("backup_restore_dependencies_invalid");
    }
    const key = await crypto.subtle.importKey("raw", vaultKey as BufferSource, "AES-GCM", false, ["decrypt"]);
    try {
        return new Uint8Array(await crypto.subtle.decrypt(
            {
                name: "AES-GCM",
                iv: sealed.slice(0, 12),
                additionalData: RESTORE_DEPENDENCIES_AAD,
            },
            key,
            sealed.slice(12),
        ));
    } catch {
        throw new Error("backup_restore_dependencies_authentication_failed");
    }
}

async function sealBackupRestoreDependencies(
    sourceEnvelope: Uint8Array,
    vaultKey: Uint8Array,
): Promise<Uint8Array> {
    const key = await crypto.subtle.importKey("raw", vaultKey as BufferSource, "AES-GCM", false, ["encrypt"]);
    const nonce = crypto.getRandomValues(new Uint8Array(12));
    const ciphertext = new Uint8Array(await crypto.subtle.encrypt(
        {
            name: "AES-GCM",
            iv: nonce,
            additionalData: RESTORE_DEPENDENCIES_AAD,
        },
        key,
        sourceEnvelope as BufferSource,
    ));
    const sealed = new Uint8Array(nonce.length + ciphertext.length);
    sealed.set(nonce);
    sealed.set(ciphertext, nonce.length);
    return sealed;
}

async function loadBackupArchive(archive: Blob, password: string): Promise<LoadedBackup> {
    if (archive.size > MAX_BACKUP_ARCHIVE_BYTES) throw new Error("backup_file_too_large");
    const files = await readPortableBackupArchive(archive);
    const info = parseInfo(JSON.parse(await readSmallText(files.get("Info.json"), 1_048_576)));
    const sourceEnvelope = await readSmallBytes(files.get("Snapshot.upwkey"), 1_024);
    const body = await readSmallBytes(files.get("Snapshot.upw"), MAX_BACKUP_SNAPSHOT_BYTES + 44);
    const sealedManifest = await readSmallBytes(files.get("Manifest.sealed"), 16 * 1024 * 1024);
    const vaultKey = await unwrapEnvelope(sourceEnvelope, password);
    try {
        const manifest = await openBackupManifest(sealedManifest, vaultKey);
        if (manifest.createdAt !== info.createdAt
            || manifest.bodyDigest !== await digestBase64(body)
            || manifest.envelopeDigest !== await digestBase64(sourceEnvelope)
            || info.isComplete !== (manifest.issues.length === 0)
            || info.attachmentVersionCount !== manifest.attachments.length
            || info.conflictCount !== manifest.conflicts.length
            || info.conflictCandidateCount !== manifest.conflicts.reduce(
                (count, conflict) => count + conflict.candidates.length, 0)
            || info.issueCount !== manifest.issues.length) {
            throw new Error("backup_package_integrity_failed");
        }
        const payloads = await validatePayloadFiles(files, manifest);
        const xml = await decryptBody(body, vaultKey);
        validateSnapshotXML(xml);
        const issues = [...manifest.issues];
        const issueKeys = new Set(issues.map(issue => JSON.stringify(issue)));
        for (const issue of payloads.issues) {
            const key = JSON.stringify(issue);
            if (issueKeys.has(key)) continue;
            issueKeys.add(key);
            issues.push(issue);
        }
        return {
            info,
            manifest,
            xml,
            sourceEnvelope,
            payloadFiles: payloads.verified,
            quarantinedPayloadFiles: payloads.quarantined,
            issues,
            isComplete: info.isComplete && payloads.issues.length === 0,
            verificationToken: await backupVerificationToken(info, manifest, payloads.fingerprints),
            vaultKey,
        };
    } catch (error) {
        vaultKey.fill(0);
        sourceEnvelope.fill(0);
        throw error;
    }
}

/** Assemble the four required root files and already verified encrypted payloads into `.upwbackup`. */
export function createBackupArchive(
    sealed: SealedBackupPayload,
    envelope: Uint8Array,
    payloadFiles: ReadonlyMap<string, Blob | Uint8Array> = new Map(),
): Blob {
    const files = new Map<string, Blob | Uint8Array>([
        ["Info.json", new TextEncoder().encode(JSON.stringify(sealed.info))],
        ["Manifest.sealed", sealed.manifest],
        ["Snapshot.upw", sealed.body],
        ["Snapshot.upwkey", envelope],
    ]);
    for (const [path, contents] of payloadFiles) {
        if (files.has(path)) throw new Error("backup_duplicate_path");
        files.set(path, contents);
    }
    return createPortableBackupArchive(files);
}

function parseInfo(value: unknown): BackupInfo {
    if (!isRecord(value) || Object.keys(value).some(key => ![
        "version", "createdAt", "isComplete", "attachmentVersionCount", "conflictCount",
        "conflictCandidateCount", "issueCount",
    ].includes(key)) || value.version !== 1 || typeof value.createdAt !== "number"
        || !Number.isFinite(value.createdAt) || typeof value.isComplete !== "boolean"
        || ![value.attachmentVersionCount, value.conflictCount, value.conflictCandidateCount, value.issueCount]
            .every(item => Number.isSafeInteger(item) && Number(item) >= 0)) {
        throw new Error("backup_invalid_info");
    }
    return value as unknown as BackupInfo;
}

function parseManifest(value: unknown): BackupManifest {
    if (!isRecord(value) || Object.keys(value).some(key => ![
        "version", "createdAt", "bodyDigest", "envelopeDigest", "headSequence",
        "attachments", "conflicts", "issues",
    ].includes(key)) || value.version !== 1 || typeof value.createdAt !== "number"
        || !Number.isFinite(value.createdAt) || !isSha256Base64(value.bodyDigest)
        || !isSha256Base64(value.envelopeDigest)
        || value.headSequence !== undefined
            && (!Number.isSafeInteger(value.headSequence) || Number(value.headSequence) < 0)
        || !Array.isArray(value.attachments) || value.attachments.some(item => !isAttachmentDescriptor(item))
        || !hasUniqueAttachmentDescriptors(value.attachments)
        || !Array.isArray(value.conflicts) || value.conflicts.some(item => !isConflictDescriptor(item))
        || !hasUniqueConflictDescriptors(value.conflicts)
        || !Array.isArray(value.issues) || value.issues.some(issue => !isBackupIssue(issue))) {
        throw new Error("backup_invalid_manifest");
    }
    return value as unknown as BackupManifest;
}

function isSha256Base64(value: unknown): value is string {
    if (typeof value !== "string" || !/^[A-Za-z0-9+/]{43}=$/.test(value)) return false;
    try {
        return atob(value).length === 32;
    } catch {
        return false;
    }
}

function isRecord(value: unknown): value is Record<string, unknown> {
    return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isAttachmentDescriptor(value: unknown): value is BackupAttachmentDescriptor {
    if (!isRecord(value) || Object.keys(value).some(key => ![
        "attachmentID", "cardID", "contentVersion", "isLegacyVersion", "dekWrapped", "sha256",
        "bytes", "isCurrent", "fileName",
    ].includes(key))) return false;
    return isUUID(value.attachmentID) && isUUID(value.cardID) && isUUID(value.contentVersion)
        && typeof value.isLegacyVersion === "boolean" && isBase64(value.dekWrapped)
        && atob(value.dekWrapped).length >= 28 && atob(value.dekWrapped).length <= 256
        && typeof value.sha256 === "string" && /^[0-9a-f]{64}$/.test(value.sha256)
        && Number.isSafeInteger(value.bytes) && Number(value.bytes) > 0
        && typeof value.isCurrent === "boolean"
        && (!value.isLegacyVersion || value.contentVersion === "00000000-0000-0000-0000-000000000000")
        && value.fileName === `${String(value.attachmentID).toLowerCase()}-${String(value.contentVersion).toLowerCase()}.cipher`;
}

function isConflictDescriptor(value: unknown): value is BackupConflictDescriptor {
    if (!isRecord(value) || Object.keys(value).some(key => ![
        "conflictID", "itemUUID", "baseRevision", "currentRevision", "currentDeletedSequence",
        "generation", "createdAt", "updatedAt", "resolvedAt", "expiresAt", "selectedCandidateID",
        "candidates",
    ].includes(key)) || !Array.isArray(value.candidates)
        || value.candidates.length < 1 || value.candidates.length > 32
        || value.candidates.some(candidate => !isCandidateDescriptor(candidate))) return false;
    const candidateIDs = value.candidates.map(candidate => (candidate as BackupCandidateDescriptor).candidateID);
    const validHistoryMetadata = value.resolvedAt === undefined && value.expiresAt === undefined
        && value.selectedCandidateID === undefined
        || Number.isFinite(value.resolvedAt) && Number.isFinite(value.expiresAt)
            && Number(value.expiresAt) > Number(value.resolvedAt)
            && (value.selectedCandidateID === undefined || isIdentifier(value.selectedCandidateID));
    return validHistoryMetadata && new Set(candidateIDs).size === candidateIDs.length
        && value.candidates.every(candidate => Number((candidate as BackupCandidateDescriptor).revision) <= Number(value.currentRevision))
        && isIdentifier(value.conflictID) && isUUID(value.itemUUID)
        && Number.isSafeInteger(value.baseRevision) && Number(value.baseRevision) >= 0
        && Number.isSafeInteger(value.currentRevision) && Number(value.currentRevision) > Number(value.baseRevision)
        && Number.isSafeInteger(value.currentDeletedSequence) && Number(value.currentDeletedSequence) >= 0
        && Number.isSafeInteger(value.generation) && Number(value.generation) > 0
        && Number.isFinite(value.createdAt) && Number.isFinite(value.updatedAt);
}

function isCandidateDescriptor(value: unknown): value is BackupCandidateDescriptor {
    if (!isRecord(value) || Object.keys(value).some(key => ![
        "candidateID", "kind", "isDelete", "revision", "modifiedAt", "committedAt", "deviceName",
        "platform", "sha256", "fileName",
    ].includes(key))) return false;
    if (!isIdentifier(value.candidateID) || ![1, 2, 3].includes(Number(value.kind))
        || typeof value.isDelete !== "boolean" || !Number.isSafeInteger(value.revision)
        || Number(value.revision) < 0 || !Number.isFinite(value.modifiedAt)
        || !Number.isFinite(value.committedAt) || typeof value.deviceName !== "string"
        || typeof value.platform !== "string") return false;
    if (value.isDelete) return value.sha256 === undefined && value.fileName === undefined;
    return typeof value.sha256 === "string" && /^[0-9a-f]{64}$/.test(value.sha256)
        && value.fileName === `${value.candidateID}.cipher`;
}

async function validatePayloadFiles(files: Map<string, Blob>, manifest: BackupManifest): Promise<{
    verified: Map<string, Blob>;
    quarantined: Map<string, Blob>;
    issues: BackupIssue[];
    fingerprints: { path: string; bytes: number | null; sha256: string | null }[];
}> {
    const expected = new Set(["Info.json", "Manifest.sealed", "Snapshot.upw", "Snapshot.upwkey"]);
    const verified = new Map<string, Blob>();
    const quarantined = new Map<string, Blob>();
    const issues: BackupIssue[] = [];
    const fingerprints: { path: string; bytes: number | null; sha256: string | null }[] = [];
    for (const attachment of manifest.attachments) {
        const path = `Attachments/${attachment.fileName}`;
        const file = files.get(path);
        const fileDigest = file ? await blobDigestHex(file) : null;
        fingerprints.push({ path, bytes: file?.size ?? null, sha256: fileDigest });
        if (file && file.size === attachment.bytes && fileDigest === attachment.sha256) {
            verified.set(path, file);
        } else {
            if (file) quarantined.set(path, file);
            issues.push({ attachmentVersionUnavailable: {
                attachmentID: attachment.attachmentID,
                contentVersion: attachment.contentVersion,
            } });
        }
        expected.add(path);
    }
    for (const conflict of manifest.conflicts) {
        for (const candidate of conflict.candidates) {
            if (!candidate.fileName) continue;
            const path = `Conflicts/${conflict.conflictID}/${candidate.fileName}`;
            const file = files.get(path);
            const fileDigest = file ? await blobDigestHex(file) : null;
            fingerprints.push({ path, bytes: file?.size ?? null, sha256: fileDigest });
            if (file && candidate.sha256 && fileDigest === candidate.sha256) {
                verified.set(path, file);
            } else {
                if (file) quarantined.set(path, file);
                issues.push({ conflictCandidateUnavailable: {
                    conflictID: conflict.conflictID,
                    candidateID: candidate.candidateID,
                } });
            }
            expected.add(path);
        }
    }
    if ([...files.keys()].some(path => !expected.has(path))) {
        throw new Error("backup_unlisted_payload");
    }
    return { verified, quarantined, issues, fingerprints };
}

async function backupVerificationToken(
    info: BackupInfo,
    manifest: BackupManifest,
    fingerprints: { path: string; bytes: number | null; sha256: string | null }[],
): Promise<string> {
    const payloads = [...fingerprints].sort((left, right) => left.path.localeCompare(right.path));
    const encoded = new TextEncoder().encode(JSON.stringify({ info, manifest, payloads }));
    try {
        return await digestHex(encoded);
    } finally {
        encoded.fill(0);
    }
}

async function blobDigestHex(file: Blob): Promise<string> {
    const bytes = new Uint8Array(await file.arrayBuffer());
    try {
        return await digestHex(bytes);
    } finally {
        bytes.fill(0);
    }
}

async function readSmallText(file: Blob | undefined, maximumSize: number): Promise<string> {
    if (!file || file.size > maximumSize) throw new Error("backup_file_too_large");
    return new TextDecoder("utf-8", { fatal: true }).decode(await file.arrayBuffer());
}

async function readSmallBytes(file: Blob | undefined, maximumSize = MAX_BACKUP_MEMBER_BYTES): Promise<Uint8Array> {
    if (!file) throw new Error("backup_file_missing");
    if (file.size > maximumSize) throw new Error("backup_file_too_large");
    return new Uint8Array(await file.arrayBuffer());
}

function validateSnapshotXML(xml: string): void {
    if (/<!\s*(?:DOCTYPE|ENTITY)\b/i.test(xml) || typeof DOMParser === "undefined") {
        throw new Error("backup_snapshot_invalid");
    }
    const document = new DOMParser().parseFromString(xml, "application/xml");
    if (document.querySelector("parsererror") || document.documentElement.tagName !== "database"
        || document.documentElement.namespaceURI) {
        throw new Error("backup_snapshot_invalid");
    }
}

function createBackupInfo(metadata: BackupPayloadMetadata): BackupInfo {
    return {
        version: 1,
        createdAt: dateToReferenceSeconds(metadata.createdAt),
        isComplete: metadata.issues.length === 0,
        attachmentVersionCount: metadata.attachments.length,
        conflictCount: metadata.conflicts.length,
        conflictCandidateCount: metadata.conflicts.reduce((count, conflict) => count + conflict.candidates.length, 0),
        issueCount: metadata.issues.length,
    };
}

function validateMetadata(metadata: BackupPayloadMetadata): void {
    if (!Array.isArray(metadata.issues) || !Array.isArray(metadata.attachments)
        || !Array.isArray(metadata.conflicts)
        || metadata.headSequence !== undefined
            && (!Number.isSafeInteger(metadata.headSequence) || metadata.headSequence < 0)) {
        throw new Error("backup_invalid_metadata");
    }
    if (metadata.attachments.some(item => !isAttachmentDescriptor(item))
        || !hasUniqueAttachmentDescriptors(metadata.attachments)
        || metadata.conflicts.some(item => !isConflictDescriptor(item))
        || !hasUniqueConflictDescriptors(metadata.conflicts)) {
        throw new Error("backup_invalid_metadata");
    }
    if (metadata.issues.some(issue => !isBackupIssue(issue))) throw new Error("backup_invalid_issue");
}

function hasUniqueAttachmentDescriptors(values: unknown[]): boolean {
    const identities = new Set<string>();
    const currentIDs = new Set<string>();
    for (const value of values) {
        if (!isAttachmentDescriptor(value)) return false;
        const identity = `${value.attachmentID.toLowerCase()}:${value.contentVersion.toLowerCase()}`;
        if (!identities.add(identity)) return false;
        if (value.isCurrent && !currentIDs.add(value.attachmentID.toLowerCase())) return false;
    }
    return true;
}

function hasUniqueConflictDescriptors(values: unknown[]): boolean {
    const conflictIDs = new Set<string>();
    for (const value of values) {
        if (!isConflictDescriptor(value) || !conflictIDs.add(value.conflictID)) return false;
    }
    return true;
}

function isBackupIssue(value: unknown): value is BackupIssue {
    if (typeof value !== "object" || value === null || Array.isArray(value)) return false;
    const entries = Object.entries(value);
    if (entries.length !== 1) return false;
    const [name, details] = entries[0];
    if (typeof details !== "object" || details === null || Array.isArray(details)) return false;
    const fields = Object.keys(details);
    const expectedFields: Record<string, string[]> = {
        cloudInventoryUnavailable: [],
        cloudInventoryChanged: [],
        retainedConflictHistoryUnavailable: [],
        localSnapshotBehindCloud: ["cloudHead", "localCursor"],
        localConflictUnavailable: ["itemID"],
        attachmentIdentityUnavailable: ["cardID"],
        attachmentVersionUnavailable: ["attachmentID", "contentVersion"],
        conflictCandidateUnavailable: ["candidateID", "conflictID"],
    };
    const expected = expectedFields[name];
    if (!expected || fields.length !== expected.length || fields.some(field => !expected.includes(field))) return false;
    if (name === "localSnapshotBehindCloud") {
        const record = details as Record<string, unknown>;
        return [record.localCursor, record.cloudHead].every(item => Number.isSafeInteger(item) && Number(item) >= 0);
    }
    const record = details as Record<string, unknown>;
    if (name === "localConflictUnavailable") return isUUID(record.itemID);
    if (name === "attachmentIdentityUnavailable") return isUUID(record.cardID);
    if (name === "attachmentVersionUnavailable") {
        return isUUID(record.attachmentID) && isUUID(record.contentVersion);
    }
    if (name === "conflictCandidateUnavailable") {
        return isIdentifier(record.conflictID) && isIdentifier(record.candidateID);
    }
    return fields.length === 0;
}

function dateToReferenceSeconds(date: Date): number {
    const value = date.getTime() / 1000 - REFERENCE_DATE_UNIX_SECONDS;
    if (!Number.isFinite(value)) throw new Error("backup_invalid_date");
    return value;
}

async function digestBase64(value: Uint8Array): Promise<string> {
    const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", value as BufferSource));
    return encodeBase64(digest);
}

function isUUID(value: unknown): value is string {
    return typeof value === "string"
        && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
}

function isIdentifier(value: unknown): value is string {
    return typeof value === "string" && /^[0-9a-f]{32}$/.test(value);
}

function isBase64(value: unknown): value is string {
    return typeof value === "string" && value.length > 0 && value.length % 4 === 0
        && /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value);
}

async function digestHex(bytes: Uint8Array): Promise<string> {
    const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes as BufferSource));
    return Array.from(digest, byte => byte.toString(16).padStart(2, "0")).join("");
}

function encodeBase64(bytes: Uint8Array): string {
    let binary = "";
    for (let offset = 0; offset < bytes.length; offset += 32_768) {
        const chunk = bytes.subarray(offset, Math.min(offset + 32_768, bytes.length));
        binary += String.fromCharCode(...chunk);
    }
    return btoa(binary);
}

function decodeBase64(value: string): Uint8Array {
    const binary = atob(value);
    const bytes = new Uint8Array(binary.length);
    for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
    return bytes;
}
