import { test } from "node:test";
import assert from "node:assert/strict";
import { createHash, webcrypto } from "node:crypto";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";
import {
    captureBackupCloudHistory,
    createBackupArchive,
    inspectBackupArchive,
    sealBackupPayload,
} from "../dist/index.js";

globalThis.crypto ??= webcrypto;
globalThis.DOMParser ??= new JSDOM("").window.DOMParser;

const attachmentId = "00000000-0000-4000-8000-000000000011";
const cardUuid = "00000000-0000-4000-8000-000000000012";
const contentVersion = "00000000-0000-4000-8000-000000000013";
const conflictId = "a".repeat(32);
const candidateId = "b".repeat(32);
const candidateUuid = "00000000-0000-4000-8000-000000000014";
const attachmentCipher = Uint8Array.from([1, 2, 3, 4]);
const candidateCipher = Uint8Array.from([5, 6, 7, 8]);
const vaultFixture = JSON.parse(readFileSync(
    new URL("./fixtures/vault-vector.json", import.meta.url), "utf8",
));
const snapshotFixture = JSON.parse(readFileSync(
    new URL("../../../Contracts/test-vectors/browser-encrypted-snapshot.json", import.meta.url), "utf8",
));
const toBase64 = bytes => Buffer.from(bytes).toString("base64");
const sha256 = bytes => createHash("sha256").update(bytes).digest("hex");

function createClient({ changedOnFinalRead = false, missingAttachment = false, retainedHistory = [] } = {}) {
    let inventoryReads = 0;
    const version = {
        attachmentId,
        cardUuid,
        contentVersion,
        dekWrapped: toBase64(new Uint8Array(32).fill(9)),
        sha256: sha256(attachmentCipher),
        bytes: attachmentCipher.length,
        isCurrent: true,
    };
    const upsert = {
        candidateId,
        kind: 1,
        op: "upsert",
        revision: 3,
        modifiedMs: 1_700_000_000_000,
        committedMs: 1_700_000_000_001,
        deviceName: "Laptop",
        platform: "macOS",
        bodyB64: toBase64(candidateCipher),
        sha256: sha256(candidateCipher),
    };
    const deleted = {
        candidateId: "c".repeat(32),
        kind: 1,
        op: "delete",
        revision: 4,
        modifiedMs: 1_700_000_000_002,
        committedMs: 1_700_000_000_003,
        deviceName: "Phone",
        platform: "iOS",
    };
    const conflict = {
        conflictId,
        itemUuid: candidateUuid,
        baseRevision: 2,
        currentRevision: 4,
        currentDeletedSeq: 0,
        generation: 5,
        createdMs: 1_700_000_000_004,
        updatedMs: 1_700_000_000_005,
        candidates: [upsert, deleted],
    };
    return {
        getVaultSeq: async () => ({ headSeq: changedOnFinalRead && ++inventoryReads > 1 ? 12 : 11, passwordVersion: 2 }),
        listVaultAttachmentVersions: async () => missingAttachment ? [] : [version],
        listVaultConflicts: async () => [conflict],
        listVaultConflictHistory: async () => retainedHistory,
        getVaultAttachment: async () => new Uint8Array(attachmentCipher),
    };
}

function options(client, overrides = {}) {
    return {
        token: "token",
        vaultId: "vault",
        localCursor: 10,
        localPasswordVersion: 2,
        fragments: [{
            uuid: cardUuid,
            kind: 1,
            revision: 2,
            modifiedMs: 1,
            xml: `<card id="${cardUuid}"><file id="${attachmentId}" version="${contentVersion}" missing="true"/></card>`,
        }],
        validate: async () => {},
        verifyCandidate: async () => {},
        client,
        ...overrides,
    };
}

test("cloud backup capture includes verified attachment and unresolved candidate payloads", async () => {
    const client = createClient();
    const verifiedRows = [];
    const captured = await captureBackupCloudHistory(options(client, {
        verifyCandidate: async row => verifiedRows.push(row),
    }));

    assert.equal(captured.headSequence, 11);
    assert.equal(captured.attachments.length, 1);
    assert.equal(captured.attachments[0].attachmentID, attachmentId);
    assert.equal(captured.conflicts.length, 1);
    assert.equal(captured.conflicts[0].candidates.length, 2);
    assert.equal(captured.conflicts[0].candidates[0].modifiedAt, 1_700_000_000 - 978_307_200);
    assert.deepEqual(verifiedRows.map(row => row.uuid), [candidateUuid]);
    assert.deepEqual([...captured.payloadFiles.keys()].sort(), [
        `Attachments/${attachmentId}-${contentVersion}.cipher`,
        `Conflicts/${conflictId}/${candidateId}.cipher`,
    ]);
    assert.ok(captured.issues.some(issue => "localSnapshotBehindCloud" in issue));
    assert.equal(captured.issues.some(issue => "retainedConflictHistoryUnavailable" in issue), false);
    assert.equal(captured.issues.some(issue => "cloudInventoryChanged" in issue), false);
});

test("cloud backup capture includes a single retained historical candidate", async () => {
    const retainedConflictId = "d".repeat(32);
    const retainedCandidateId = "e".repeat(32);
    const retained = {
        conflictId: retainedConflictId,
        itemUuid: candidateUuid,
        baseRevision: 2,
        currentRevision: 4,
        currentDeletedSeq: 0,
        generation: 5,
        createdMs: 1_700_000_000_004,
        updatedMs: 1_700_000_000_005,
        resolvedMs: 1_700_000_000_006,
        expiresMs: 1_700_000_000_007,
        selectedCandidateId: "f".repeat(32),
        candidates: [{
            candidateId: retainedCandidateId,
            kind: 1,
            op: "upsert",
            revision: 4,
            modifiedMs: 1_700_000_000_002,
            committedMs: 1_700_000_000_003,
            deviceName: "Tablet",
            platform: "ios",
            bodyB64: toBase64(candidateCipher),
            sha256: sha256(candidateCipher),
        }],
    };
    const captured = await captureBackupCloudHistory(options(createClient({ retainedHistory: [retained] })));

    assert.equal(captured.conflicts.length, 2);
    const historical = captured.conflicts.find(conflict => conflict.conflictID === retainedConflictId);
    assert.ok(historical);
    assert.equal(historical.candidates.length, 1);
    assert.equal(historical.resolvedAt, 1_700_000_000_006 / 1000 - 978_307_200);
    assert.equal(historical.selectedCandidateID, "f".repeat(32));
    assert.ok(captured.payloadFiles.has(`Conflicts/${retainedConflictId}/${retainedCandidateId}.cipher`));
    assert.equal(captured.issues.some(issue => "retainedConflictHistoryUnavailable" in issue), false);
});

test("captured cloud history seals into a package accepted by the native-compatible inspector", async () => {
    const captured = await captureBackupCloudHistory(options(createClient()));
    const envelope = Uint8Array.from(Buffer.from(vaultFixture.envelope, "base64"));
    const vaultKey = Uint8Array.from(Buffer.from(vaultFixture.vek, "base64"));
    const sealed = await sealBackupPayload(snapshotFixture.xml, envelope, {
        createdAt: new Date("2026-10-27T00:00:00.000Z"),
        headSequence: captured.headSequence,
        attachments: captured.attachments,
        conflicts: captured.conflicts,
        issues: captured.issues,
    }, vaultKey);
    const archive = createBackupArchive(sealed, envelope, captured.payloadFiles);
    const inspected = await inspectBackupArchive(archive, vaultFixture.password);

    assert.equal(inspected.info.isComplete, false);
    assert.equal(inspected.manifest.attachments.length, 1);
    assert.equal(inspected.manifest.conflicts.length, 1);
    assert.equal(inspected.manifest.conflicts[0].candidates.length, 2);
    assert.equal(inspected.manifest.headSequence, 11);
    assert.equal(inspected.xml, snapshotFixture.xml);
});

test("cloud backup capture retains unverifiable ciphertext but marks the package incomplete", async () => {
    const client = createClient();
    const captured = await captureBackupCloudHistory(options(client, {
        verifyCandidate: async () => { throw new Error("candidate_authentication_failed"); },
    }));

    assert.ok(captured.payloadFiles.has(`Conflicts/${conflictId}/${candidateId}.cipher`));
    assert.ok(captured.issues.some(issue => "conflictCandidateUnavailable" in issue));
});

test("cloud backup capture marks a missing referenced version and inventory changes", async () => {
    const missing = await captureBackupCloudHistory(options(createClient({ missingAttachment: true })));
    assert.ok(missing.issues.some(issue => "attachmentVersionUnavailable" in issue));

    const changed = await captureBackupCloudHistory(options(createClient({ changedOnFinalRead: true })));
    assert.ok(changed.issues.some(issue => "cloudInventoryChanged" in issue));
});

test("cloud backup capture degrades to explicit issues when cloud inventory is unavailable", async () => {
    const client = createClient();
    client.listVaultConflictHistory = async () => { throw new Error("offline"); };
    const captured = await captureBackupCloudHistory(options(client));
    assert.ok(captured.issues.some(issue => "retainedConflictHistoryUnavailable" in issue));
    assert.equal(captured.issues.some(issue => "cloudInventoryUnavailable" in issue), false);
    assert.equal(captured.attachments.length, 1);
    assert.equal(captured.conflicts.length, 1);
    assert.equal(captured.payloadFiles.size, 2);
});

test("cloud backup capture aborts instead of publishing after session validation fails", async () => {
    let validations = 0;
    await assert.rejects(
        () => captureBackupCloudHistory(options(createClient(), {
            validate: async () => {
                validations += 1;
                if (validations === 3) throw new Error("session_changed");
            },
        })),
        /session_changed/,
    );
});
