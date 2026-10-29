import { test } from "node:test";
import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
import { JSDOM } from "jsdom";
import { copyConflictCandidateAttachments } from "../dist/index.js";

globalThis.crypto ??= webcrypto;
const { window } = new JSDOM("");
globalThis.DOMParser = window.DOMParser;
globalThis.XMLSerializer = window.XMLSerializer;

const sourceItemUUID = "00000000-0000-4000-8000-000000000001";
const destinationItemUUID = "00000000-0000-4000-8000-000000000002";
const sourceAttachmentID = "00000000-0000-4000-8000-000000000003";
const sourceContentVersion = "00000000-0000-4000-8000-000000000004";
const missingAttachmentID = "00000000-0000-4000-8000-000000000005";
const missingContentVersion = "00000000-0000-4000-8000-000000000006";
const sourceXML = `<card id="${sourceItemUUID}" title="Example" modified="1"><field id="00000000-0000-4000-8000-000000000007" name="Login">alice</field><image id="${sourceAttachmentID}" version="${sourceContentVersion}" name="inline.png">AQID</image><file id="${missingAttachmentID}" version="${missingContentVersion}" name="archive.bin" missing="true"/></card>`;

function makeOptions(overrides = {}) {
    const ids = [
        "00000000-0000-4000-8000-000000000011",
        "00000000-0000-4000-8000-000000000012",
        "00000000-0000-4000-8000-000000000013",
        "00000000-0000-4000-8000-000000000014",
    ];
    const calls = { downloaded: [], decrypted: [], encrypted: [], uploaded: [], deleted: [], validated: 0 };
    const options = {
        sourceItemUUID,
        destinationItemUUID,
        sourceXML,
        nowMs: 10,
        validate: async () => { calls.validated += 1; },
        listVersions: async () => [{
            attachmentId: missingAttachmentID,
            contentVersion: missingContentVersion,
            cardUuid: sourceItemUUID,
            dekWrapped: "AQ==",
            sha256: "a".repeat(64),
            bytes: 30,
            isCurrent: false,
        }],
        downloadCipher: async version => {
            calls.downloaded.push(version);
            return Uint8Array.of(21, 22, 23);
        },
        decryptAttachment: async (cipher, version) => {
            calls.decrypted.push({ bytes: [...cipher], version });
            return Uint8Array.of(7, 8, 9);
        },
        encryptAttachment: async (plaintext, attachmentID, contentVersion) => {
            calls.encrypted.push({ bytes: [...plaintext], attachmentID, contentVersion });
            return { cipher: Uint8Array.of(31, 32), dekWrapped: Uint8Array.of(41, 42) };
        },
        uploadAttachment: async (attachmentID, contentVersion, cardUUID, cipher, dekWrapped) => {
            calls.uploaded.push({ attachmentID, contentVersion, cardUUID, cipher: [...cipher], dekWrapped: [...dekWrapped] });
        },
        deleteAttachment: async attachmentID => { calls.deleted.push(attachmentID); },
        createUUID: () => ids.shift(),
        ...overrides,
    };
    return { options, calls };
}

test("conflict candidate copy re-identifies the card and uploads every attachment", async () => {
    const { options, calls } = makeOptions();
    const result = await copyConflictCandidateAttachments(options);
    const document = new DOMParser().parseFromString(result.xml, "application/xml");
    const card = document.documentElement;
    const attachments = Array.from(card.children).filter(element =>
        element.tagName === "image" || element.tagName === "file");

    assert.equal(card.getAttribute("id"), destinationItemUUID.toUpperCase());
    assert.equal(card.getAttribute("modified"), "10");
    assert.notEqual(card.querySelector("field")?.getAttribute("id"), "00000000-0000-4000-8000-000000000007");
    assert.deepEqual(attachments.map(element => element.getAttribute("id")), [
        "00000000-0000-4000-8000-000000000011",
        "00000000-0000-4000-8000-000000000013",
    ]);
    assert.deepEqual(attachments.map(element => element.getAttribute("version")), [
        "00000000-0000-4000-8000-000000000012",
        "00000000-0000-4000-8000-000000000014",
    ]);
    assert.deepEqual(attachments.map(element => element.textContent), ["AQID", "BwgJ"]);
    assert.ok(attachments.every(element => element.getAttribute("missing") === null));
    assert.deepEqual(result.attachmentRefs, [
        { attachmentId: "00000000-0000-4000-8000-000000000011", contentVersion: "00000000-0000-4000-8000-000000000012" },
        { attachmentId: "00000000-0000-4000-8000-000000000013", contentVersion: "00000000-0000-4000-8000-000000000014" },
    ]);
    assert.deepEqual(calls.encrypted.map(entry => entry.bytes), [[1, 2, 3], [7, 8, 9]]);
    assert.equal(calls.downloaded.length, 1);
    assert.equal(calls.decrypted.length, 1);
    assert.equal(calls.uploaded.length, 2);
    assert.deepEqual(calls.deleted, []);
    assert.ok(calls.validated >= 5);
});

test("conflict candidate copy stops when an exact source attachment version is absent", async () => {
    const { options, calls } = makeOptions({ listVersions: async () => [] });
    await assert.rejects(() => copyConflictCandidateAttachments(options), /attachment_version_missing/);
    assert.equal(calls.uploaded.length, 1, "the inline attachment may be staged before later metadata is checked");
    assert.deepEqual(calls.deleted, ["00000000-0000-4000-8000-000000000011"]);
});

test("conflict candidate copy removes prior uploads when a later attachment upload fails", async () => {
    const { options, calls } = makeOptions({
        uploadAttachment: async (attachmentID, contentVersion, cardUUID, cipher, dekWrapped) => {
            calls.uploaded.push({ attachmentID, contentVersion, cardUUID, cipher: [...cipher], dekWrapped: [...dekWrapped] });
            if (calls.uploaded.length === 2) throw new Error("upload_failed");
        },
    });
    await assert.rejects(() => copyConflictCandidateAttachments(options), /upload_failed/);
    assert.deepEqual(calls.deleted, [
        "00000000-0000-4000-8000-000000000013",
        "00000000-0000-4000-8000-000000000011",
    ]);
});

test("conflict candidate copy removes staged attachments when its final candidate checkpoint fails", async () => {
    const { options, calls } = makeOptions({
        checkpoint: async () => { throw new Error("conflict_candidates_changed"); },
    });
    await assert.rejects(() => copyConflictCandidateAttachments(options), /conflict_candidates_changed/);
    assert.equal(calls.uploaded.length, 2);
    assert.deepEqual(calls.deleted, [
        "00000000-0000-4000-8000-000000000013",
        "00000000-0000-4000-8000-000000000011",
    ]);
});

test("conflict candidate copy fails closed for attachment references without bytes", async () => {
    const { options, calls } = makeOptions({
        sourceXML: `<card id="${sourceItemUUID}"><file id="${sourceAttachmentID}" version="${sourceContentVersion}" empty="true"/></card>`,
    });
    await assert.rejects(() => copyConflictCandidateAttachments(options), /attachment_content_unavailable/);
    assert.equal(calls.uploaded.length, 0);
});
