import {
    base64ToBytes,
    type RelayAttachmentVersion,
} from "../api/relay.js";
import {
    installAttachmentBytes,
    readAttachmentReferences,
} from "./attachments.js";
import {
    copyCardXmlForNewIdentity,
    type AttachmentIdentityRemap,
} from "./item-editor.js";

export interface ConflictCandidateAttachmentCopyOptions {
    sourceItemUUID: string;
    destinationItemUUID: string;
    sourceXML: string;
    nowMs: number;
    validate: () => Promise<void>;
    listVersions: () => Promise<RelayAttachmentVersion[]>;
    downloadCipher: (version: RelayAttachmentVersion) => Promise<Uint8Array>;
    decryptAttachment: (cipher: Uint8Array, version: RelayAttachmentVersion) => Promise<Uint8Array>;
    encryptAttachment: (
        plaintext: Uint8Array,
        attachmentID: string,
        contentVersion: string,
    ) => Promise<{ cipher: Uint8Array; dekWrapped: Uint8Array }>;
    uploadAttachment: (
        attachmentID: string,
        contentVersion: string,
        cardUUID: string,
        cipher: Uint8Array,
        dekWrapped: Uint8Array,
    ) => Promise<void>;
    deleteAttachment: (attachmentID: string) => Promise<void>;
    checkpoint?: () => Promise<void>;
    createUUID?: () => string;
}

export interface ConflictCandidateAttachmentCopy {
    xml: string;
    attachmentRefs: Array<{ attachmentId: string; contentVersion: string }>;
    uploadedAttachmentIDs: string[];
}

/** Copies all candidate attachments to fresh identities before a new card can reference them. */
export async function copyConflictCandidateAttachments(
    options: ConflictCandidateAttachmentCopyOptions,
): Promise<ConflictCandidateAttachmentCopy> {
    const {
        sourceItemUUID,
        destinationItemUUID,
        sourceXML,
        nowMs,
        validate,
        listVersions,
        downloadCipher,
        decryptAttachment,
        encryptAttachment,
        uploadAttachment,
        deleteAttachment,
    } = options;
    const createUUID = options.createUUID ?? (() => crypto.randomUUID());
    const references = readAttachmentReferences(sourceXML, sourceItemUUID);
    const remaps: AttachmentIdentityRemap[] = [];
    const attachmentRefs: ConflictCandidateAttachmentCopy["attachmentRefs"] = [];
    const uploadedAttachmentIDs: string[] = [];
    let hydratedXML = sourceXML;

    try {
        let versions: RelayAttachmentVersion[] | undefined;
        for (const reference of references) {
            await validate();
            if (!reference.id || !reference.contentVersion) {
                throw new Error("bad_attachment_identity");
            }

            let plaintext: Uint8Array;
            if (reference.base64 !== undefined) {
                plaintext = base64ToBytes(reference.base64);
            } else if (reference.missing) {
                versions ??= await listVersions();
                const matches = versions.filter(version =>
                    version.attachmentId === reference.id
                    && version.contentVersion === reference.contentVersion
                    && version.cardUuid === sourceItemUUID.toLowerCase());
                if (matches.length !== 1) throw new Error("attachment_version_missing");
                const sourceVersion = matches[0];
                await validate();
                const cipher = await downloadCipher(sourceVersion);
                try {
                    plaintext = await decryptAttachment(cipher, sourceVersion);
                } finally {
                    cipher.fill(0);
                }
            } else {
                throw new Error("attachment_content_unavailable");
            }

            const attachmentID = createUUID();
            const contentVersion = createUUID();
            if (attachmentID === contentVersion
                || remaps.some(entry => entry.attachmentID === attachmentID
                    || entry.contentVersion === contentVersion)) {
                plaintext.fill(0);
                throw new Error("duplicate_attachment_identity");
            }
            let encrypted: { cipher: Uint8Array; dekWrapped: Uint8Array } | undefined;
            try {
                if (reference.missing) {
                    hydratedXML = installAttachmentBytes(
                        hydratedXML,
                        sourceItemUUID,
                        reference.id,
                        reference.contentVersion,
                        plaintext,
                    );
                }
                encrypted = await encryptAttachment(plaintext, attachmentID, contentVersion);
            } finally {
                plaintext.fill(0);
            }

            try {
                await validate();
                uploadedAttachmentIDs.push(attachmentID);
                await uploadAttachment(
                    attachmentID,
                    contentVersion,
                    destinationItemUUID,
                    encrypted.cipher,
                    encrypted.dekWrapped,
                );
            } finally {
                encrypted.cipher.fill(0);
                encrypted.dekWrapped.fill(0);
            }
            remaps.push({
                sourceID: reference.id,
                sourceVersion: reference.contentVersion,
                attachmentID,
                contentVersion,
            });
            attachmentRefs.push({ attachmentId: attachmentID, contentVersion });
        }

        await (options.checkpoint ?? validate)();
        const xml = copyCardXmlForNewIdentity(
            hydratedXML,
            sourceItemUUID,
            destinationItemUUID,
            remaps,
            nowMs,
        );
        const copiedReferences = readAttachmentReferences(xml, destinationItemUUID);
        if (copiedReferences.length !== attachmentRefs.length
            || copiedReferences.some(reference => reference.missing || reference.base64 === undefined)) {
            throw new Error("attachment_copy_incomplete");
        }
        return { xml, attachmentRefs, uploadedAttachmentIDs };
    } catch (error) {
        for (const attachmentID of uploadedAttachmentIDs.reverse()) {
            try {
                await deleteAttachment(attachmentID);
            } catch {
                console.warn("[upw] orphan conflict attachment cleanup failed");
            }
        }
        throw error;
    }
}
