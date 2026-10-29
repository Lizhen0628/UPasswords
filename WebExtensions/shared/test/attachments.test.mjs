import assert from "node:assert/strict";
import test from "node:test";
import { webcrypto } from "node:crypto";
import { JSDOM } from "jsdom";
import {
    decryptAttachmentVersion,
    hydrateMissingAttachments,
    installAttachmentBytes,
    readAttachmentReferences,
    readInlineAttachments,
    rewrapAttachmentDEK,
    VaultCryptoError,
} from "../dist/index.js";

const dom = new JSDOM("");
globalThis.DOMParser = dom.window.DOMParser;
globalThis.XMLSerializer = dom.window.XMLSerializer;
globalThis.crypto ??= webcrypto;
const itemID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
const imageID = "11111111-2222-4333-8444-555555555555";
const imageBytes = Uint8Array.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00]);
const imageBase64 = Buffer.from(imageBytes).toString("base64");

function item(xml) {
    return { id: itemID, source: { xml: `<card id="${itemID}">${xml}</card>`, revision: 1 } };
}

test("attachment projection recognizes cached PNGs and files without exposing non-image data", () => {
    const attachments = readInlineAttachments(item(`
        <image id="${imageID}" version="11111111-2222-4333-8444-555555555556" name="logo.png">${imageBase64}</image>
        <file id="11111111-2222-4333-8444-555555555557" version="11111111-2222-4333-8444-555555555558" name="notes.txt">AQID</file>
        <file id="11111111-2222-4333-8444-555555555559" version="11111111-2222-4333-8444-555555555560" name="remote.png" missing="true"/>
        <image name="empty.png" empty="true"/>
    `));

    assert.deepEqual(attachments.map(({ name, state }) => [name, state]), [
        ["logo.png", "previewable"],
        ["notes.txt", "not_image"],
        ["remote.png", "missing"],
        ["empty.png", "empty"],
    ]);
    assert.equal(attachments[0].mimeType, "image/png");
    assert.equal(attachments[0].base64, imageBase64);
    assert.equal("base64" in attachments[1], false);
});

test("ordinary file entries are previewable when their bytes are a supported raster image", () => {
    const [attachment] = readInlineAttachments(item(`<file name="photo.bin">${imageBase64}</file>`));
    assert.equal(attachment.kind, "file");
    assert.equal(attachment.state, "previewable");
    assert.equal(attachment.mimeType, "image/png");
});

test("attachment projection rejects mismatched items, unsafe XML, malformed IDs, and corrupt base64", () => {
    assert.throws(() => readInlineAttachments({ ...item(""), id: "bbbbbbbb-bbbb-4ccc-8ddd-eeeeeeeeeeee" }),
        (error) => error instanceof VaultCryptoError && error.message === "item_id_mismatch");
    assert.throws(() => readInlineAttachments({ id: itemID, source: { xml: `<!DOCTYPE card><card id="${itemID}"/>`, revision: 1 } }),
        (error) => error instanceof VaultCryptoError && error.message === "bad_xml");
    assert.throws(() => readInlineAttachments(item(`<image id="bad" name="x.png">${imageBase64}</image>`)),
        (error) => error instanceof VaultCryptoError && error.message === "bad_attachment_identity");
    assert.throws(() => readInlineAttachments(item(`<image id="${imageID}" version="bad" name="x.png">${imageBase64}</image>`)),
        (error) => error instanceof VaultCryptoError && error.message === "bad_attachment_version");
    assert.throws(() => readInlineAttachments(item(`<image id="${imageID}" version="${imageID}" missing="true" name="x.png">${imageBase64}</image>`)),
        (error) => error instanceof VaultCryptoError && error.message === "bad_attachment_data");
    assert.throws(() => readInlineAttachments(item("<image name=\"x.png\">not-base64!</image>")),
        (error) => error instanceof VaultCryptoError && error.message === "bad_attachment_data");
});

test("attachment download decrypts Swift-compatible wrapped DEK and hydrates the exact missing version", async () => {
    const key = new Uint8Array(32).fill(19);
    const dek = new Uint8Array(32).fill(37);
    const plaintext = imageBytes;
    const aad = new TextEncoder().encode(`UPW-ATTACHMENT-VERSION-V1:${imageID}:${itemID}`);
    const wrapAAD = new Uint8Array(aad.length + 4);
    wrapAAD.set(aad);
    wrapAAD.set(new TextEncoder().encode(":DEK"), aad.length);
    const vaultKey = await crypto.subtle.importKey("raw", key, "AES-GCM", false, ["encrypt"]);
    const dataKey = await crypto.subtle.importKey("raw", dek, "AES-GCM", false, ["encrypt"]);
    const wrapNonce = crypto.getRandomValues(new Uint8Array(12));
    const wrappedCipher = new Uint8Array(await crypto.subtle.encrypt(
        { name: "AES-GCM", iv: wrapNonce, additionalData: wrapAAD }, vaultKey, dek,
    ));
    const dekWrapped = new Uint8Array(wrapNonce.length + wrappedCipher.length);
    dekWrapped.set(wrapNonce);
    dekWrapped.set(wrappedCipher, wrapNonce.length);
    const cipherNonce = crypto.getRandomValues(new Uint8Array(12));
    const contentCipher = new Uint8Array(await crypto.subtle.encrypt(
        { name: "AES-GCM", iv: cipherNonce, additionalData: aad }, dataKey, plaintext,
    ));
    const cipher = new Uint8Array(cipherNonce.length + contentCipher.length);
    cipher.set(cipherNonce);
    cipher.set(contentCipher, cipherNonce.length);

    const xml = `<card id="${itemID}"><image id="${imageID}" version="${itemID}" name="image.png" missing="true"/></card>`;
    assert.deepEqual(
        [...await decryptAttachmentVersion(cipher, dekWrapped, key, imageID, itemID)],
        [...plaintext],
    );
    await assert.rejects(
        () => decryptAttachmentVersion(cipher, dekWrapped, key, imageID, imageID.replace(/e$/, "f")),
        (error) => error instanceof VaultCryptoError && error.message === "attachment_decrypt_failed",
    );
    const destinationKey = new Uint8Array(32).fill(73);
    const rewrappedDEK = await rewrapAttachmentDEK(dekWrapped, key, destinationKey, imageID, itemID);
    assert.deepEqual(
        [...await decryptAttachmentVersion(cipher, rewrappedDEK, destinationKey, imageID, itemID)],
        [...plaintext],
    );
    await assert.rejects(
        () => rewrapAttachmentDEK(dekWrapped, destinationKey, key, imageID, itemID),
        (error) => error instanceof VaultCryptoError && error.message === "attachment_decrypt_failed",
    );
    const hydrated = installAttachmentBytes(xml, itemID, imageID, itemID, plaintext);
    const [reference] = readAttachmentReferences(hydrated, itemID);
    assert.equal(reference.missing, false);
    assert.equal(reference.base64, Buffer.from(plaintext).toString("base64"));
    assert.equal(readInlineAttachments({ id: itemID, source: { xml: hydrated, revision: 1 } })[0].state, "previewable");
});

test("attachment hydration downloads only the referenced current version and returns encrypted row bytes", async () => {
    const attachmentVersion = "11111111-2222-4333-8444-555555555556";
    const cipher = Uint8Array.from([8, 7, 6, 5]);
    const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", cipher));
    const sha256 = [...digest].map(byte => byte.toString(16).padStart(2, "0")).join("");
    const requests = [];
    globalThis.fetch = async input => {
        const url = new URL(String(input));
        requests.push(url.pathname + url.search);
        if (url.pathname.endsWith("/attachment-versions")) {
            return new Response(JSON.stringify({ versions: [{
                attachmentId: imageID, cardUuid: itemID, createdMs: 1, contentVersion: attachmentVersion,
                dekWrapped: Buffer.alloc(32).toString("base64"), sha256, bytes: cipher.length, isCurrent: false,
            }], nextOffset: 1, hasMore: false }));
        }
        return new Response(cipher);
    };
    const originalXML = `<card id="${itemID}"><image id="${imageID}" version="${attachmentVersion}" name="logo.png" missing="true"/></card>`;
    const row = { uuid: itemID, kind: 1, revision: 2, bodyB64: "old-cipher", modifiedMs: 2 };
    const hydrated = await hydrateMissingAttachments("token", "vault", [row], [], async () => {}, {
        decryptRow: async candidate => candidate.bodyB64 === "old-cipher"
            ? originalXML : Buffer.from(candidate.bodyB64, "base64").toString("utf8"),
        encryptRow: async (_candidate, xml) => Buffer.from(xml).toString("base64"),
        decryptAttachment: async (received, version) => {
            assert.equal(version.contentVersion, attachmentVersion);
            assert.deepEqual([...received], [...cipher]);
            return Uint8Array.from([1, 2, 3]);
        },
    });
    assert.equal(requests.length, 2);
    assert.match(requests[0], /attachment-versions/);
    assert.match(requests[1], new RegExp(`attachments/${imageID}\\?version=${attachmentVersion}`));
    const [reference] = readAttachmentReferences(
        Buffer.from(hydrated[0].bodyB64, "base64").toString("utf8"), itemID,
    );
    assert.equal(reference.missing, false);
    assert.equal(reference.base64, "AQID");
    assert.equal(hydrated[0].revision, row.revision);
});

test("attachment hydration accepts a retained exact version and normalizes reference casing", async () => {
    const attachmentVersion = "11111111-2222-4333-8444-555555555556";
    const cipher = Uint8Array.from([8, 7, 6]);
    const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", cipher));
    const sha256 = [...digest].map(byte => byte.toString(16).padStart(2, "0")).join("");
    globalThis.fetch = async input => {
        const url = new URL(String(input));
        if (url.pathname.endsWith("/attachment-versions")) {
            return new Response(JSON.stringify({ versions: [{
                attachmentId: imageID, cardUuid: itemID, createdMs: 1, contentVersion: attachmentVersion,
                dekWrapped: Buffer.alloc(32).toString("base64"), sha256, bytes: cipher.length, isCurrent: false,
            }], nextOffset: 1, hasMore: false }));
        }
        return new Response(cipher);
    };
    const xml = `<card id="${itemID}"><image id="${imageID.toUpperCase()}" version="${attachmentVersion.toUpperCase()}" missing="true"/></card>`;
    const row = { uuid: itemID, kind: 1, revision: 4, bodyB64: "old", modifiedMs: 4 };
    const [hydrated] = await hydrateMissingAttachments("token", "vault", [row], [], async () => {}, {
        decryptRow: async () => xml,
        encryptRow: async (_candidate, value) => Buffer.from(value).toString("base64"),
        decryptAttachment: async () => Uint8Array.from([1, 2, 3]),
    });
    const [reference] = readAttachmentReferences(Buffer.from(hydrated.bodyB64, "base64").toString(), itemID);
    assert.equal(reference.id, imageID);
    assert.equal(reference.contentVersion, attachmentVersion);
    assert.equal(reference.missing, false);
});

test('cancelling an attachment transfer aborts fetch and never returns partial bytes', async () => {
    const { getVaultAttachment } = await import('../dist/index.js');
    const controller = new AbortController();
    let started;
    const ready = new Promise(resolve => { started = resolve; });
    globalThis.fetch = async (_input, options) => new Promise((_resolve, reject) => {
        const abort = () => reject(options.signal.reason);
        if (options.signal.aborted) abort();
        else options.signal.addEventListener('abort', abort, { once: true });
        started();
    });
    const task = getVaultAttachment('token', 'vault', { attachmentId: imageID,
        cardUuid: itemID, contentVersion: itemID, bytes: 32, sha256: 'a'.repeat(64), dekWrapped: 'AQ==' }, controller.signal);
    await ready;
    controller.abort();
    await assert.rejects(task, error => error.name === 'AbortError');
});

test('cancellation during decryption does not install or encrypt a late version', async () => {
    const controller = new AbortController();
    const xml = `<card id="${itemID}"><file id="${imageID}" version="${itemID}" missing="true"/></card>`;
    const row = { uuid: itemID, kind: 1, revision: 1, modifiedMs: 1, bodyB64: 'AQ==' };
    const cipher = new Uint8Array([1, 2, 3]);
    const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', cipher));
    const sha256 = [...digest].map(byte => byte.toString(16).padStart(2, '0')).join('');
    const plaintext = new Uint8Array([4, 5, 6]);
    globalThis.fetch = async () => new Response(cipher);
    let encryptions = 0;
    await assert.rejects(hydrateMissingAttachments('token', 'vault', [row], [], async () => {}, {
        signal: controller.signal,
        decryptRow: async () => xml,
        encryptRow: async () => { encryptions += 1; return 'unused'; },
        listVersions: async () => [{ attachmentId: imageID, cardUuid: itemID, contentVersion: itemID,
            bytes: cipher.length, sha256, dekWrapped: Buffer.alloc(32).toString('base64'), isCurrent: true }],
        decryptAttachment: async () => { controller.abort(); return plaintext; },
    }), error => error.name === 'AbortError');
    assert.equal(encryptions, 0);
    assert.deepEqual([...plaintext], [0, 0, 0]);
    assert.equal(readAttachmentReferences(xml, itemID)[0].missing, true);
});
