import type { ExtensionItem } from "./types.js";
import { VaultCryptoError } from "./vault-crypto.js";

const ATTACHMENT_ID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAX_PREVIEW_BYTES = 20 * 1024 * 1024;

export interface AttachmentReference {
    id: string | null;
    contentVersion: string | null;
    kind: "image" | "file";
    missing: boolean;
    base64?: string;
}

export interface InlineAttachment {
    id: string | null;
    contentVersion: string | null;
    kind: "image" | "file";
    name: string;
    state: "previewable" | "missing" | "empty" | "not_image" | "too_large";
    mimeType?: string;
    base64?: string;
}

function imageMimeType(bytes: Uint8Array): string | null {
    if (bytes.length >= 8 && bytes[0] === 0x89 && bytes[1] === 0x50
        && bytes[2] === 0x4e && bytes[3] === 0x47
        && bytes[4] === 0x0d && bytes[5] === 0x0a
        && bytes[6] === 0x1a && bytes[7] === 0x0a) return "image/png";
    if (bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) return "image/jpeg";
    if (bytes.length >= 6) {
        const signature = String.fromCharCode(...bytes.subarray(0, 6));
        if (signature === "GIF87a" || signature === "GIF89a") return "image/gif";
    }
    if (bytes.length >= 12 && String.fromCharCode(...bytes.subarray(0, 4)) === "RIFF"
        && String.fromCharCode(...bytes.subarray(8, 12)) === "WEBP") return "image/webp";
    if (bytes.length >= 2 && bytes[0] === 0x42 && bytes[1] === 0x4d) return "image/bmp";
    if (bytes.length >= 4 && bytes[0] === 0 && bytes[1] === 0
        && bytes[2] === 1 && bytes[3] === 0) return "image/x-icon";
    return null;
}

function decodeBase64Prefix(value: string): Uint8Array {
    const prefix = value.slice(0, 32);
    let binary: string;
    try {
        binary = atob(prefix);
    } catch {
        throw new VaultCryptoError("bad_attachment_data");
    }
    if (btoa(binary) !== prefix) throw new VaultCryptoError("bad_attachment_data");
    const bytes = new Uint8Array(binary.length);
    for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
    return bytes;
}

/** Validate and read attachment references from one decrypted card fragment. */
export function readAttachmentReferences(xml: string, cardID: string): AttachmentReference[] {
    if (/<!\s*(?:DOCTYPE|ENTITY)\b/i.test(xml)) throw new VaultCryptoError("bad_xml");
    if (typeof DOMParser === "undefined") throw new VaultCryptoError("dom_unavailable");
    const document = new DOMParser().parseFromString(xml, "application/xml");
    const root = document.documentElement;
    if (document.querySelector("parsererror") || !root || root.namespaceURI || root.tagName !== "card"
        || root.getAttribute("id")?.toLowerCase() !== cardID.toLowerCase()) {
        throw new VaultCryptoError("item_id_mismatch");
    }
    const seenIDs = new Set<string>();
    return Array.from(root.children)
        .filter((node) => !node.namespaceURI && (node.tagName === "image" || node.tagName === "file"))
        .map((node): AttachmentReference => {
            const id = node.getAttribute("id");
            const contentVersion = node.getAttribute("version");
            if (id !== null && (!ATTACHMENT_ID_PATTERN.test(id) || seenIDs.has(id.toLowerCase()))) {
                throw new VaultCryptoError("bad_attachment_identity");
            }
            if (id) seenIDs.add(id.toLowerCase());
            if (contentVersion !== null && !ATTACHMENT_ID_PATTERN.test(contentVersion)) {
                throw new VaultCryptoError("bad_attachment_version");
            }
            const encoded = (node.textContent ?? "").replace(/[\t\n\r ]/g, "");
            const missingMarker = node.getAttribute("missing");
            const emptyMarker = node.getAttribute("empty");
            if ((missingMarker !== null && !["true", "false"].includes(missingMarker))
                || (emptyMarker !== null && !["true", "false"].includes(emptyMarker))) {
                throw new VaultCryptoError("bad_attachment_data");
            }
            const missing = missingMarker === "true";
            const empty = emptyMarker === "true";
            if (missing && (!id || !contentVersion || empty || encoded)
                || empty && encoded) throw new VaultCryptoError("bad_attachment_data");
            if (encoded && (encoded.length % 4 !== 0
                || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(encoded))) {
                throw new VaultCryptoError("bad_attachment_data");
            }
            return {
                id: id?.toLowerCase() ?? null,
                contentVersion: contentVersion?.toLowerCase() ?? null,
                kind: node.tagName as AttachmentReference["kind"],
                missing,
                ...(encoded ? { base64: encoded } : {}),
            };
        });
}

/** Install authenticated bytes into the matching missing reference without changing its identity. */
export function installAttachmentBytes(
    xml: string,
    cardID: string,
    attachmentID: string,
    contentVersion: string,
    bytes: Uint8Array,
): string {
    if (typeof DOMParser === "undefined" || typeof XMLSerializer === "undefined") {
        throw new VaultCryptoError("dom_unavailable");
    }
    readAttachmentReferences(xml, cardID);
    const document = new DOMParser().parseFromString(xml, "application/xml");
    const root = document.documentElement;
    const node = Array.from(root.children).find((child) =>
        (child.tagName === "image" || child.tagName === "file")
        && child.getAttribute("id")?.toLowerCase() === attachmentID.toLowerCase()
        && child.getAttribute("version")?.toLowerCase() === contentVersion.toLowerCase());
    if (!node || node.getAttribute("missing") !== "true") {
        throw new VaultCryptoError("attachment_reference_changed");
    }
    let binary = "";
    const chunkSize = 0x8000;
    for (let offset = 0; offset < bytes.length; offset += chunkSize) {
        binary += String.fromCharCode(...bytes.subarray(offset, offset + chunkSize));
    }
    node.removeAttribute("missing");
    node.removeAttribute("empty");
    node.textContent = btoa(binary);
    return new XMLSerializer().serializeToString(root);
}

/** Discard an available exact-version cache without deleting or changing its remote reference. */
export function discardAttachmentBytes(
    xml: string, cardID: string, attachmentID: string, contentVersion: string,
): string {
    const reference = readAttachmentReferences(xml, cardID).find(entry =>
        entry.id === attachmentID.toLowerCase() && entry.contentVersion === contentVersion.toLowerCase());
    if (!reference || reference.missing) throw new VaultCryptoError("attachment_reference_changed");
    const document = new DOMParser().parseFromString(xml, "application/xml");
    const node = Array.from(document.documentElement.children).find(child =>
        (child.tagName === "image" || child.tagName === "file")
        && child.getAttribute("id")?.toLowerCase() === reference.id
        && child.getAttribute("version")?.toLowerCase() === reference.contentVersion);
    if (!node) throw new VaultCryptoError("attachment_reference_changed");
    node.textContent = "";
    node.removeAttribute("empty");
    node.setAttribute("missing", "true");
    return new XMLSerializer().serializeToString(document.documentElement);
}

/** Read cached attachment bytes from a validated card fragment for safe raster preview. */
export function readInlineAttachments(item: ExtensionItem): InlineAttachment[] {
    const xml = item.source?.xml;
    if (!xml) return [];
    if (/<!\s*(?:DOCTYPE|ENTITY)\b/i.test(xml)) throw new VaultCryptoError("bad_xml");
    if (typeof DOMParser === "undefined") throw new VaultCryptoError("dom_unavailable");

    const document = new DOMParser().parseFromString(xml, "application/xml");
    const root = document.documentElement;
    if (document.querySelector("parsererror") || !root || root.namespaceURI || root.tagName !== "card"
        || root.getAttribute("id")?.toLowerCase() !== item.id.toLowerCase()) {
        throw new VaultCryptoError("item_id_mismatch");
    }

    const seenIDs = new Set<string>();
    return Array.from(root.children)
        .filter((node) => !node.namespaceURI && (node.tagName === "image" || node.tagName === "file"))
        .map((node): InlineAttachment => {
            const id = node.getAttribute("id");
            const version = node.getAttribute("version");
            if (id !== null) {
                const normalizedID = id.toLowerCase();
                if (!ATTACHMENT_ID_PATTERN.test(id) || seenIDs.has(normalizedID)) {
                    throw new VaultCryptoError("bad_attachment_identity");
                }
                seenIDs.add(normalizedID);
            }
            if (version !== null && !ATTACHMENT_ID_PATTERN.test(version)) {
                throw new VaultCryptoError("bad_attachment_version");
            }

            const encoded = (node.textContent ?? "").replace(/[\t\n\r ]/g, "");
            const missingMarker = node.getAttribute("missing");
            const emptyMarker = node.getAttribute("empty");
            if ((missingMarker !== null && !["true", "false"].includes(missingMarker))
                || (emptyMarker !== null && !["true", "false"].includes(emptyMarker))) {
                throw new VaultCryptoError("bad_attachment_data");
            }
            const missing = missingMarker === "true";
            const empty = emptyMarker === "true";
            if (missing && (!id || !version || empty)) throw new VaultCryptoError("bad_attachment_data");
            if ((missing || empty) && encoded) throw new VaultCryptoError("bad_attachment_data");
            const attachment: InlineAttachment = {
                id,
                contentVersion: version,
                kind: node.tagName as InlineAttachment["kind"],
                name: node.getAttribute("name") ?? "",
                state: missing ? "missing" : empty || !encoded ? "empty" : "not_image",
            };
            if (missing || empty || !encoded) return attachment;
            if (encoded.length % 4 !== 0
                || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(encoded)) {
                throw new VaultCryptoError("bad_attachment_data");
            }
            const byteCount = encoded.length / 4 * 3 - (encoded.endsWith("==") ? 2 : encoded.endsWith("=") ? 1 : 0);
            if (byteCount > MAX_PREVIEW_BYTES) {
                attachment.state = "too_large";
                return attachment;
            }
            const bytes = decodeBase64Prefix(encoded);
            const mimeType = imageMimeType(bytes);
            bytes.fill(0);
            if (mimeType) {
                attachment.state = "previewable";
                attachment.mimeType = mimeType;
                attachment.base64 = encoded;
            }
            return attachment;
        });
}
