import { readFileSync } from "node:fs";
import { test } from "node:test";
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";
import {
    createPortableBackupArchive,
    PortableBackupArchiveError,
    readPortableBackupArchive,
    createBackupArchive,
    decryptAttachmentVersion,
    decryptItemBody,
    encryptItemBody,
    inspectBackupArchive,
    openBackupRestoreDependencies,
    prepareBackupRestore,
    sealBackupPayload,
    unwrapEnvelope,
} from "../dist/index.js";

const requiredFiles = new Map([
    ["Info.json", new TextEncoder().encode("{}")],
    ["Manifest.sealed", new Uint8Array([1, 2, 3])],
    ["Snapshot.upw", new Uint8Array([4, 5, 6, 7])],
    ["Snapshot.upwkey", new Uint8Array([8])],
]);
const vaultFixture = JSON.parse(readFileSync(
    new URL("./fixtures/vault-vector.json", import.meta.url), "utf8",
));
const snapshotFixture = JSON.parse(readFileSync(
    new URL("../../../Contracts/test-vectors/browser-encrypted-snapshot.json", import.meta.url), "utf8",
));
globalThis.DOMParser ??= new JSDOM().window.DOMParser;

async function sha256Hex(bytes) {
    const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
    return [...digest].map(byte => byte.toString(16).padStart(2, "0")).join("");
}

async function encryptAttachment(vaultKey, attachmentID, contentVersion, plaintext) {
    const dek = crypto.getRandomValues(new Uint8Array(32));
    const aad = new TextEncoder().encode(
        `UPW-ATTACHMENT-VERSION-V1:${attachmentID}:${contentVersion}`,
    );
    const wrapAAD = new Uint8Array(aad.length + 4);
    wrapAAD.set(aad);
    wrapAAD.set(new TextEncoder().encode(":DEK"), aad.length);
    const key = await crypto.subtle.importKey("raw", vaultKey, "AES-GCM", false, ["encrypt"]);
    const dataKey = await crypto.subtle.importKey("raw", dek, "AES-GCM", false, ["encrypt"]);
    const wrapNonce = crypto.getRandomValues(new Uint8Array(12));
    const wrappedCipher = new Uint8Array(await crypto.subtle.encrypt(
        { name: "AES-GCM", iv: wrapNonce, additionalData: wrapAAD }, key, dek,
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
    dek.fill(0);
    wrapAAD.fill(0);
    aad.fill(0);
    return { cipher, dekWrapped };
}

test("portable backup archive round-trips supported files and stable paths", async () => {
    const files = new Map(requiredFiles);
    files.set("Attachments/123e4567-e89b-12d3-a456-426614174000-123e4567-e89b-12d3-a456-426614174001.cipher", new Uint8Array([9, 10]));
    files.set(`Conflicts/${"a".repeat(32)}/${"b".repeat(32)}.cipher`, new Blob([new Uint8Array([11])]));

    const archive = createPortableBackupArchive(files);
    const restored = await readPortableBackupArchive(archive);
    assert.deepEqual([...restored.keys()], [...files.keys()].sort());
    for (const [path, contents] of files) {
        const actual = new Uint8Array(await restored.get(path).arrayBuffer());
        const expected = contents instanceof Blob ? new Uint8Array(await contents.arrayBuffer()) : contents;
        assert.deepEqual(actual, expected);
    }
});

test("native-compatible backup package seals Codable metadata and assesses with its source password", async () => {
    const envelope = Uint8Array.from(atob(vaultFixture.envelope), character => character.charCodeAt(0));
    const vaultKey = Uint8Array.from(atob(vaultFixture.vek), character => character.charCodeAt(0));
    const sealed = await sealBackupPayload(snapshotFixture.xml, envelope, {
        createdAt: new Date("2001-01-01T00:00:00.000Z"),
        headSequence: 0,
        attachments: [],
        conflicts: [],
        issues: [{ retainedConflictHistoryUnavailable: {} }],
    }, vaultKey);
    const archive = createBackupArchive(sealed, envelope);
    const assessment = await inspectBackupArchive(archive, vaultFixture.password);

    assert.equal(assessment.info.isComplete, false);
    assert.equal(assessment.info.issueCount, 1);
    assert.deepEqual(assessment.manifest.issues, [{ retainedConflictHistoryUnavailable: {} }]);
    assert.equal(assessment.xml, snapshotFixture.xml);
});

test("backup inspection reports missing or damaged payloads and quarantines unverified bytes", async () => {
    const envelope = Uint8Array.from(atob(vaultFixture.envelope), character => character.charCodeAt(0));
    const vaultKey = Uint8Array.from(atob(vaultFixture.vek), character => character.charCodeAt(0));
    const attachmentID = "123e4567-e89b-12d3-a456-426614174000";
    const contentVersion = "123e4567-e89b-12d3-a456-426614174001";
    const path = `Attachments/${attachmentID}-${contentVersion}.cipher`;
    const sealed = await sealBackupPayload(snapshotFixture.xml, envelope, {
        createdAt: new Date("2026-10-27T00:00:00.000Z"),
        attachments: [{
            attachmentID,
            cardID: "123e4567-e89b-12d3-a456-426614174002",
            contentVersion,
            isLegacyVersion: false,
            dekWrapped: Buffer.from(new Uint8Array(32)).toString("base64"),
            sha256: "a".repeat(64),
            bytes: 1,
            isCurrent: true,
            fileName: `${attachmentID}-${contentVersion}.cipher`,
        }],
        conflicts: [],
        issues: [],
    }, vaultKey);

    for (const payloadFiles of [
        new Map(),
        new Map([[path, new Uint8Array([9])]]),
    ]) {
        const archive = createBackupArchive(sealed, envelope, payloadFiles);
        const assessment = await inspectBackupArchive(archive, vaultFixture.password);

        assert.equal(assessment.info.isComplete, true);
        assert.equal(assessment.isComplete, false);
        assert.deepEqual(assessment.issues, [{ attachmentVersionUnavailable: { attachmentID, contentVersion } }]);
        assert.equal(assessment.payloadFiles.size, 0);
        assert.equal(assessment.quarantinedPayloadFiles.size, payloadFiles.size);
        if (payloadFiles.size > 0) {
            assert.deepEqual(
                new Uint8Array(await assessment.quarantinedPayloadFiles.get(path).arrayBuffer()),
                new Uint8Array([9]),
            );
        }
    }
});

test("backup restore rekeys the snapshot, attachment DEKs, and authenticated candidates", async () => {
    const sourceEnvelope = Uint8Array.from(atob(vaultFixture.envelope), character => character.charCodeAt(0));
    const sourceKey = Uint8Array.from(atob(vaultFixture.vek), character => character.charCodeAt(0));
    const cardID = "123e4567-e89b-12d3-a456-426614174010";
    const attachmentID = "123e4567-e89b-12d3-a456-426614174011";
    const contentVersion = "123e4567-e89b-12d3-a456-426614174012";
    const candidateUUID = "123e4567-e89b-12d3-a456-426614174013";
    const conflictID = "c".repeat(32);
    const candidateID = "d".repeat(32);
    const attachmentBytes = new Uint8Array([1, 2, 3, 4, 5]);
    const candidateXML = `<card id="${candidateUUID}" title="Recovered"/>`;
    const attachment = await encryptAttachment(sourceKey, attachmentID, contentVersion, attachmentBytes);
    const originalDekWrapped = Buffer.from(attachment.dekWrapped).toString("base64");
    const candidateCipher = await encryptItemBody(candidateXML, sourceKey, candidateUUID);
    const attachmentPath = `Attachments/${attachmentID}-${contentVersion}.cipher`;
    const candidatePath = `Conflicts/${conflictID}/${candidateID}.cipher`;
    const sealed = await sealBackupPayload(
        `<database><card id="${cardID}"><file id="${attachmentID}" version="${contentVersion}" missing="true"/></card></database>`,
        sourceEnvelope,
        {
            createdAt: new Date("2026-10-27T00:00:00.000Z"),
            attachments: [{
                attachmentID,
                cardID,
                contentVersion,
                isLegacyVersion: false,
                dekWrapped: originalDekWrapped,
                sha256: await sha256Hex(attachment.cipher),
                bytes: attachment.cipher.length,
                isCurrent: true,
                fileName: `${attachmentID}-${contentVersion}.cipher`,
            }],
            conflicts: [{
                conflictID,
                itemUUID: candidateUUID,
                baseRevision: 1,
                currentRevision: 2,
                currentDeletedSequence: 0,
                generation: 1,
                createdAt: 0,
                updatedAt: 1,
                candidates: [{
                    candidateID,
                    kind: 1,
                    isDelete: false,
                    revision: 2,
                    modifiedAt: 0,
                    committedAt: 1,
                    deviceName: "Test",
                    platform: "web",
                    sha256: await sha256Hex(candidateCipher),
                    fileName: `${candidateID}.cipher`,
                }],
            }],
            issues: [],
        },
        sourceKey,
    );
    const sourceArchive = createBackupArchive(sealed, sourceEnvelope, new Map([
        [attachmentPath, attachment.cipher],
        [candidatePath, candidateCipher],
    ]));
    const review = await inspectBackupArchive(sourceArchive, vaultFixture.password);
    const restored = await prepareBackupRestore(sourceArchive, {
        sourcePassword: vaultFixture.password,
        destinationPassword: "new-local-copy-password",
        expectedVerificationToken: review.verificationToken,
        allowIncomplete: false,
    });

    assert.equal(restored.isComplete, true);
    const restoredInspection = await inspectBackupArchive(restored.archive, "new-local-copy-password");
    assert.equal(restoredInspection.isComplete, true);
    assert.notEqual(restoredInspection.manifest.attachments[0].dekWrapped, originalDekWrapped);
    const restoredFiles = await readPortableBackupArchive(restored.archive);
    const restoredEnvelope = new Uint8Array(await restoredFiles.get("Snapshot.upwkey").arrayBuffer());
    const restoredKey = await unwrapEnvelope(restoredEnvelope, "new-local-copy-password");
    assert.deepEqual(await openBackupRestoreDependencies(restored.historyCipher, restoredKey), sourceEnvelope);
    const restoredAttachmentCipher = new Uint8Array(await restoredFiles.get(attachmentPath).arrayBuffer());
    const restoredDekWrapped = Uint8Array.from(
        Buffer.from(restoredInspection.manifest.attachments[0].dekWrapped, "base64"),
    );
    const restoredAttachmentBytes = await decryptAttachmentVersion(
        restoredAttachmentCipher,
        restoredDekWrapped,
        restoredKey,
        attachmentID,
        contentVersion,
    );
    assert.deepEqual(restoredAttachmentBytes, attachmentBytes);
    const restoredCandidateCipher = new Uint8Array(await restoredFiles.get(candidatePath).arrayBuffer());
    assert.notDeepEqual(restoredCandidateCipher, candidateCipher);
    assert.equal(await decryptItemBody(restoredCandidateCipher, restoredKey, candidateUUID), candidateXML);
    restoredKey.fill(0);
    restoredAttachmentBytes.fill(0);

    await assert.rejects(
        () => prepareBackupRestore(sourceArchive, {
            sourcePassword: vaultFixture.password,
            destinationPassword: "new-local-copy-password",
            expectedVerificationToken: "stale-review",
            allowIncomplete: true,
        }),
        /backup_package_changed/,
    );
});

test("portable backup inspection rejects malformed descriptors and unlisted payloads", async () => {
    const envelope = Uint8Array.from(atob(vaultFixture.envelope), character => character.charCodeAt(0));
    const vaultKey = Uint8Array.from(atob(vaultFixture.vek), character => character.charCodeAt(0));
    const metadata = {
        createdAt: new Date("2001-01-01T00:00:00.000Z"),
        attachments: [{}],
        conflicts: [],
        issues: [],
    };
    await assert.rejects(
        () => sealBackupPayload(snapshotFixture.xml, envelope, metadata, vaultKey),
        /backup_invalid_metadata/,
    );

    const sealed = await sealBackupPayload(snapshotFixture.xml, envelope, {
        ...metadata,
        attachments: [],
        issues: [{ cloudInventoryUnavailable: {} }],
    }, vaultKey);
    const extra = new Map([
        ["Attachments/123e4567-e89b-12d3-a456-426614174000-123e4567-e89b-12d3-a456-426614174001.cipher", new Uint8Array([1])],
    ]);
    const archive = createBackupArchive(sealed, envelope, extra);
    await assert.rejects(() => inspectBackupArchive(archive, vaultFixture.password), /backup_unlisted_payload/);
});

test("extension USTAR output matches the shared native-reader fixture", async () => {
    const emptyPackage = new Map([...requiredFiles.keys()].map(path => [path, new Uint8Array()]));
    const archive = new Uint8Array(await createPortableBackupArchive(emptyPackage).arrayBuffer());
    const encoded = readFileSync(
        new URL("../../../Contracts/test-vectors/browser-empty-backup.ustar.b64", import.meta.url),
        "utf8",
    ).replace(/\s/g, "");
    const fixture = Uint8Array.from(atob(encoded), character => character.charCodeAt(0));
    assert.deepEqual(archive, fixture);
});

test("portable backup archive requires all package roots and rejects unsupported paths", () => {
    assert.throws(
        () => createPortableBackupArchive(new Map([["Info.json", new Uint8Array()]])),
        error => error instanceof PortableBackupArchiveError && error.message === "invalid_package",
    );
    const files = new Map(requiredFiles);
    files.set("../Snapshot.upw", new Uint8Array());
    assert.throws(
        () => createPortableBackupArchive(files),
        error => error instanceof PortableBackupArchiveError && error.message === "unsupported_path",
    );
});

test("portable backup archive rejects checksum damage, truncation, and non-zero trailing data", async () => {
    const bytes = new Uint8Array(await createPortableBackupArchive(requiredFiles).arrayBuffer());
    const badHeader = bytes.slice();
    badHeader[0] ^= 1;
    await assert.rejects(() => readPortableBackupArchive(new Blob([badHeader])), PortableBackupArchiveError);
    await assert.rejects(() => readPortableBackupArchive(new Blob([bytes.slice(0, -1)])), PortableBackupArchiveError);

    const badTrailing = bytes.slice();
    badTrailing[badTrailing.length - 1] = 1;
    await assert.rejects(() => readPortableBackupArchive(new Blob([badTrailing])), PortableBackupArchiveError);
});

test("portable backup archive rejects non-zero member padding", async () => {
    const files = new Map(requiredFiles);
    files.set("Info.json", new Uint8Array([1]));
    const bytes = new Uint8Array(await createPortableBackupArchive(files).arrayBuffer());
    const infoPayloadOffset = 512;
    bytes[infoPayloadOffset + 1] = 1;
    await assert.rejects(() => readPortableBackupArchive(new Blob([bytes])), PortableBackupArchiveError);
});
