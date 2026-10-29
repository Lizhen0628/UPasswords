import { test } from "node:test";
import assert from "node:assert/strict";
import { IDBFactory } from "fake-indexeddb";
import { createLocalBackupStore } from "../dist/index.js";

const firstID = "123e4567-e89b-42d3-a456-426614174000";
const secondID = "123e4567-e89b-42d3-a456-426614174001";

function copy(id, createdAt, overrides = {}) {
    return {
        id,
        name: `Local copy ${createdAt}`,
        createdAt,
        itemCount: 3,
        attachmentVersionCount: 2,
        conflictCount: 1,
        issueCount: 0,
        isComplete: true,
        archive: new Blob([new Uint8Array([1, 2, 3])]),
        historyCipher: new Uint8Array(28).fill(7),
        ...overrides,
    };
}

test("local backup copies persist encrypted archives independently and expose metadata only in listings", async () => {
    const store = createLocalBackupStore(new IDBFactory());
    const first = await store.create(copy(firstID, 10));
    const second = await store.create(copy(secondID, 20));

    assert.equal(first.byteCount, 3);
    assert.deepEqual((await store.list()).map(entry => entry.id), [secondID, firstID]);
    assert.equal("archive" in (await store.list())[0], false);
    const restored = await store.read(firstID);
    assert.equal(restored.name, "Local copy 10");
    assert.deepEqual(new Uint8Array(await restored.archive.arrayBuffer()), new Uint8Array([1, 2, 3]));
    assert.deepEqual(restored.historyCipher, new Uint8Array(28).fill(7));

    await store.remove(firstID);
    assert.equal(await store.read(firstID), null);
    assert.deepEqual((await store.list()).map(entry => entry.id), [secondID]);
    store.close();
});

test("local backup store rejects duplicate identities and malformed or oversized copies without replacement", async () => {
    const store = createLocalBackupStore(new IDBFactory());
    await store.create(copy(firstID, 10));
    await assert.rejects(store.create(copy(firstID, 20)));
    await assert.rejects(store.create(copy(secondID, 30, { name: "   " })), /local_backup_store_invalid_copy/);
    await assert.rejects(store.create(copy(secondID, 40, { historyCipher: new Uint8Array(2) })),
        /local_backup_store_invalid_copy/);

    const retained = await store.read(firstID);
    assert.equal(retained.name, "Local copy 10");
    assert.equal((await store.list()).length, 1);
    store.close();
});
