import {
    base64ToBytes,
    getVaultAttachment,
    listVaultAttachmentVersions,
    RelayApiError,
    type RelayAttachmentVersion,
    type RelayItemRow,
} from "../api/relay.js";
import { installAttachmentBytes, readAttachmentReferences } from "./attachments.js";

export interface AttachmentHydrationCrypto {
    signal?: AbortSignal;
    decryptRow: (row: RelayItemRow) => Promise<string>;
    encryptRow: (row: RelayItemRow, xml: string) => Promise<string>;
    decryptAttachment: (cipher: Uint8Array, version: RelayAttachmentVersion) => Promise<Uint8Array>;
    storeAttachment?: (version: RelayAttachmentVersion, cipher: Uint8Array) => Promise<void>;
    listVersions?: () => Promise<RelayAttachmentVersion[]>;
}

/** Download missing active-card attachment versions and keep only re-encrypted row content. */
export async function hydrateMissingAttachments(
    token: string,
    vaultId: string,
    rows: RelayItemRow[],
    previousRows: RelayItemRow[],
    validate: () => Promise<void>,
    crypto: AttachmentHydrationCrypto,
    attachmentIDs?: string[],
): Promise<RelayItemRow[]> {
    const previousByID = new Map(previousRows.map(row => [row.uuid.toLowerCase(), row]));
    let versions: RelayAttachmentVersion[] | undefined;
    let changedCount = 0;
    const result: RelayItemRow[] = [];

    for (const row of rows) {
        if (row.kind !== 1) {
            result.push(row);
            continue;
        }
        await validate();
        crypto.signal?.throwIfAborted();
        let xml = await crypto.decryptRow(row);
        const references = readAttachmentReferences(xml, row.uuid);
        const targetIDs = attachmentIDs ? new Set(attachmentIDs.map(id => id.toLowerCase())) : null;
        const missing = references.filter(reference => reference.missing
            && (!targetIDs || reference.id !== null && targetIDs.has(reference.id.toLowerCase())));
        if (missing.length === 0) {
            result.push(row);
            continue;
        }

        const previous = previousByID.get(row.uuid.toLowerCase());
        const previousContent = new Map<string, string>();
        if (previous?.kind === 1) {
            const previousXML = await crypto.decryptRow(previous);
            for (const reference of readAttachmentReferences(previousXML, previous.uuid)) {
                if (reference.id && reference.contentVersion && !reference.missing && reference.base64 !== undefined) {
                    previousContent.set(`${reference.id}:${reference.contentVersion}`, reference.base64);
                }
            }
        }

        for (const reference of missing) {
            if (!reference.id || !reference.contentVersion) throw new Error("bad_attachment_identity");
            const cacheKey = `${reference.id}:${reference.contentVersion}`;
            const cachedBase64 = previousContent.get(cacheKey);
            let plaintext: Uint8Array;
            if (cachedBase64 !== undefined) {
                plaintext = base64ToBytes(cachedBase64);
            } else {
                versions ??= await (crypto.listVersions?.()
                    ?? listVaultAttachmentVersions(token, vaultId));
                const matches = versions.filter(version =>
                    version.attachmentId === reference.id
                    && version.contentVersion === reference.contentVersion
                    && version.cardUuid === row.uuid.toLowerCase());
                if (matches.length !== 1) throw new RelayApiError(404, "attachment_version_missing");
                const version = matches[0];
                await validate();
                const cipher = await getVaultAttachment(token, vaultId, version, crypto.signal);
                try {
                    await crypto.storeAttachment?.(version, cipher);
                    plaintext = await crypto.decryptAttachment(cipher, version);
                } finally {
                    cipher.fill(0);
                }
            }
            try {
                crypto.signal?.throwIfAborted();
                xml = installAttachmentBytes(
                    xml, row.uuid, reference.id, reference.contentVersion, plaintext,
                );
            } finally {
                plaintext.fill(0);
            }
            await validate();
        }
        crypto.signal?.throwIfAborted();
        const body = await crypto.encryptRow(row, xml);
        crypto.signal?.throwIfAborted();
        result.push({ ...row, bodyB64: body });
        changedCount += 1;
    }
    if (changedCount) console.info(`[upw] attachment hydration completed items=${changedCount}`);
    return result;
}
