import { test } from "node:test";
import assert from "node:assert/strict";
import {
    decryptSyncQuarantinePayload,
    encryptSyncQuarantinePayload,
    isValidEncryptedSyncQuarantineItem,
    retryQuarantinedRows,
} from "../dist/index.js";

const UUID_A = "123e4567-e89b-42d3-a456-426614174000";
const UUID_B = "123e4567-e89b-42d3-a456-426614174001";
const row = (uuid = UUID_A, revision = 2, bodyB64 = btoa(`cipher-${revision}`)) => ({
    uuid,
    kind: 1,
    revision,
    bodyB64,
    modifiedMs: revision,
});
const identity = (overrides = {}) => ({
    id: "change:42",
    uuid: UUID_A,
    revision: 2,
    source: "change",
    sequence: 42,
    reason: "authenticationFailed",
    capturedAt: 1_700_000_000_000,
    ...overrides,
});

test("quarantine payload is VEK-encrypted and authenticated with quarantine metadata", async () => {
    const key = new Uint8Array(32).fill(19);
    const original = row();
    const encryptedPayloadB64 = await encryptSyncQuarantinePayload(original, key, identity());
    const item = { ...identity(), encryptedPayloadB64 };

    assert.equal(isValidEncryptedSyncQuarantineItem(item), true);
    assert.deepEqual(await decryptSyncQuarantinePayload(item, key), original);
    await assert.rejects(() => decryptSyncQuarantinePayload({
        ...item,
        reason: "unsupportedFormat",
    }, key), /quarantine_decrypt_failed/);
    await assert.rejects(() => decryptSyncQuarantinePayload(item, new Uint8Array(32).fill(20)),
        /quarantine_decrypt_failed/);
});

test("quarantine retry restores readable rows without rolling back newer cached revisions", async () => {
    const older = { ...identity(), encryptedPayloadB64: btoa("x".repeat(48)) };
    const recoverable = {
        ...identity({
            id: "change:43",
            uuid: UUID_B,
            revision: 2,
            sequence: 43,
            reason: "unsupportedFormat",
        }),
        encryptedPayloadB64: btoa("y".repeat(48)),
    };
    const current = row(UUID_A, 3);
    const recovered = row(UUID_B, 2);
    const result = await retryQuarantinedRows({
        quarantinedItems: [older, recoverable],
        rows: [current],
        openQuarantine: async item => item.id === older.id ? row(UUID_A, 2) : recovered,
        verifyRows: async rows => rows[0].uuid === UUID_A
            ? [{ uuid: UUID_A, reason: "authenticationFailed" }] : [],
    });

    assert.equal(result.recoveredCount, 1);
    assert.deepEqual(result.rows.map(value => [value.uuid, value.revision]), [
        [UUID_A, 3],
        [UUID_B, 2],
    ]);
    assert.deepEqual(result.restoredRows, [recovered]);
    assert.deepEqual(result.quarantinedItems, [older]);
});
