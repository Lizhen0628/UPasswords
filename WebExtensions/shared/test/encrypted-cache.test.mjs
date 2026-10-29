import { test } from "node:test";
import assert from "node:assert/strict";
import { IDBFactory } from "fake-indexeddb";
import { createEncryptedCache } from "../dist/index.js";

const scope = { userId: "user-a", vaultId: "vault-a", origin: "https://relay.example" };
const uuid = "123e4567-e89b-42d3-a456-426614174000";
const row = (overrides = {}) => ({
    uuid,
    kind: 1,
    revision: 1,
    bodyB64: Buffer.from("encrypted payload").toString("base64"),
    modifiedMs: 1,
    ...overrides,
});
const input = (cache, overrides = {}) => ({
    scope,
    envelope: "synthetic-envelope",
    passwordVersion: 1,
    cursor: 10,
    accountEpoch: 0,
    rows: [row()],
    ...overrides,
});

async function seed(cache, overrides = {}) {
    return cache.commit(input(cache, overrides), null);
}

async function expectedSha256(value) {
    const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)));
    return Array.from(digest, byte => byte.toString(16).padStart(2, "0")).join("");
}

function databaseFor(factory) {
    return new Promise((resolve, reject) => {
        const request = factory.open("upasswords-encrypted-vault-cache", 3);
        request.onsuccess = () => resolve(request.result);
        request.onerror = () => reject(request.error);
    });
}

async function installWriteTransactionHook(factory, hook) {
    const db = await databaseFor(factory);
    const databasePrototype = Object.getPrototypeOf(db);
    const originalTransaction = databasePrototype.transaction;
    databasePrototype.transaction = function (stores, mode, options) {
        const tx = originalTransaction.call(this, stores, mode, options);
        const storeNames = Array.isArray(stores) ? stores : [stores];
        if (mode === "readwrite" && storeNames.includes("snapshots")) hook(tx);
        return tx;
    };
    return () => {
        databasePrototype.transaction = originalTransaction;
        db.close();
    };
}

test("aborted cache commit rejects and preserves snapshot and cursor", async () => {
    const factory = new IDBFactory();
    const cache = createEncryptedCache(factory);
    await seed(cache);
    const restore = await installWriteTransactionHook(factory, tx => {
        const objectStore = tx.objectStore("snapshots");
        const originalPut = objectStore.put;
        objectStore.put = function (...args) {
            tx.abort();
            return originalPut.apply(this, args);
        };
    });
    try {
        await assert.rejects(cache.commit(input(cache, { cursor: 999 }), 1));
    } finally {
        restore();
    }
    const stored = await cache.read(scope);
    assert.equal(stored.cursor, 10);
    assert.equal(stored.version, 1);
    cache.close();
});

test("business rows preserve cloud byte length and ciphertext digest", async () => {
    const factory = new IDBFactory();
    const cache = createEncryptedCache(factory);
    await seed(cache);
    const db = await databaseFor(factory);
    const stored = await new Promise((resolve, reject) => {
        const key = `${scope.origin}\u0000${scope.userId}\u0000${scope.vaultId}\u0000${uuid}`;
        const request = db.transaction("vault_items", "readonly").objectStore("vault_items").get(key);
        request.onsuccess = () => resolve(request.result);
        request.onerror = () => reject(request.error);
    });
    db.close();
    cache.close();
    assert.equal(stored.bodyBytes, Buffer.from("encrypted payload").length);
    assert.equal(stored.bodySha256, await expectedSha256("encrypted payload"));
});

test("attachment metadata and verified ciphertext use cloud-aligned stores", async () => {
    const factory = new IDBFactory();
    const cache = createEncryptedCache(factory);
    const snapshot = await seed(cache);
    const cipher = Buffer.from("encrypted attachment");
    const version = {
        attachmentId: "11111111-2222-4333-8444-555555555555",
        cardUuid: uuid,
        createdMs: 2,
        contentVersion: "22222222-3333-4433-8544-555555555555",
        dekWrapped: Buffer.from("wrapped-key").toString("base64"),
        sha256: await expectedSha256("encrypted attachment"),
        bytes: cipher.length,
        isCurrent: true,
    };
    await cache.replaceAttachmentVersions(scope, snapshot.accountEpoch, snapshot.version, [version]);
    await cache.writeAttachmentContent(
        scope, snapshot.accountEpoch, snapshot.version, version, cipher,
    );
    const db = await databaseFor(factory);
    const storeValue = (store, key) => new Promise((resolve, reject) => {
        const request = db.transaction(store, "readonly").objectStore(store).get(key);
        request.onsuccess = () => resolve(request.result);
        request.onerror = () => reject(request.error);
    });
    const prefix = `${scope.origin}\u0000${scope.userId}\u0000${scope.vaultId}`;
    const attachment = await storeValue("attachments", `${prefix}\u0000${version.attachmentId}`);
    const attachmentVersion = await storeValue(
        "attachment_versions", `${prefix}\u0000${version.attachmentId}\u0000${version.contentVersion}`);
    const content = await storeValue(
        "attachmentContent", `${prefix}\u0000${version.attachmentId}\u0000${version.contentVersion}`);
    db.close();
    cache.close();
    assert.equal(attachment.createdMs, version.createdMs);
    assert.equal(attachmentVersion.dekWrapped, version.dekWrapped);
    assert.equal(content.cipherB64, cipher.toString("base64"));
});

test("QuotaExceededError during cache commit rejects and preserves snapshot and cursor", async () => {
    const factory = new IDBFactory();
    const cache = createEncryptedCache(factory);
    await seed(cache);
    const restore = await installWriteTransactionHook(factory, tx => {
        const objectStore = tx.objectStore("snapshots");
        const originalPut = objectStore.put;
        objectStore.put = function (...args) {
            Object.defineProperty(tx, "error", {
                configurable: true,
                get: () => new DOMException("quota", "QuotaExceededError"),
            });
            const request = originalPut.apply(this, args);
            tx.abort();
            return request;
        };
    });
    try {
        await assert.rejects(cache.commit(input(cache, { cursor: 999 }), 1), error =>
            error.name === "QuotaExceededError");
    } finally {
        restore();
    }
    const stored = await cache.read(scope);
    assert.equal(stored.cursor, 10);
    assert.equal(stored.version, 1);
    cache.close();
});

test("a restarted cache instance reads the committed snapshot", async () => {
    const factory = new IDBFactory();
    const first = createEncryptedCache(factory);
    const expected = await seed(first);
    first.close();
    const restarted = createEncryptedCache(factory);
    assert.deepEqual(await restarted.read(scope), expected);
    restarted.close();
});

test("legacy snapshots without quarantine metadata remain readable", async () => {
    const factory = new IDBFactory();
    const cache = createEncryptedCache(factory);
    const expected = await seed(cache);
    const db = await databaseFor(factory);
    const tx = db.transaction("snapshots", "readwrite");
    const request = tx.objectStore("snapshots").openCursor();
    request.onsuccess = () => {
        const cursor = request.result;
        if (!cursor) return;
        const { quarantinedItems: _removed, ...legacySnapshot } = cursor.value;
        cursor.update(legacySnapshot);
    };
    await new Promise((resolve, reject) => {
        tx.oncomplete = resolve;
        tx.onabort = () => reject(tx.error);
    });
    const restored = await cache.read(scope);
    assert.deepEqual(restored.rows, expected.rows);
    assert.deepEqual(restored.quarantinedItems, []);
    db.close();
    cache.close();
});

test("multiple cache instances use compare-and-swap versions", async () => {
    const factory = new IDBFactory();
    const first = createEncryptedCache(factory);
    const second = createEncryptedCache(factory);
    const original = await seed(first);
    const proposals = await Promise.allSettled([
        first.commit(input(first, { cursor: 11, accountEpoch: original.accountEpoch }), original.version),
        second.commit(input(second, { cursor: 12, accountEpoch: original.accountEpoch }), original.version),
    ]);
    assert.equal(proposals.filter(result => result.status === "fulfilled").length, 1);
    assert.equal(proposals.filter(result => result.status === "rejected").length, 1);
    assert.equal((await first.read(scope)).version, 2);
    first.close();
    second.close();
});

test("account, vault, and origin scopes are isolated", async () => {
    const cache = createEncryptedCache(new IDBFactory());
    await seed(cache);
    const otherScopes = [
        { ...scope, userId: "user-b" },
        { ...scope, vaultId: "vault-b" },
        { ...scope, origin: "https://other.example" },
    ];
    for (const other of otherScopes) assert.equal(await cache.read(other), null);
    await cache.commit(input(cache, { scope: otherScopes[2], cursor: 20 }), null);
    assert.equal((await cache.read(scope)).cursor, 10);
    assert.equal((await cache.read(otherScopes[2])).cursor, 20);
    cache.close();
});

test("preserveAccount advances the epoch while keeping snapshots and attachment policies readable", async () => {
    const cache = createEncryptedCache(new IDBFactory());
    const secondVaultScope = { ...scope, vaultId: "vault-b" };
    const otherAccountScope = { ...scope, userId: "user-b" };
    const ledger = {
        formatVersion: 1,
        records: {},
        offlineAttachments: [],
        downloadAllVersions: [],
    };
    const original = await cache.commit(input(cache), null, { state: ledger, expectedVersion: null });
    await cache.commit(input(cache, { scope: secondVaultScope, cursor: 20 }), null);
    await cache.commit(input(cache, { scope: otherAccountScope, cursor: 30 }), null);
    await cache.preserveAccount(scope.userId);

    const preserved = await cache.read(scope);
    assert.equal(await cache.getEpoch(scope), 1);
    assert.deepEqual({ ...preserved, accountEpoch: original.accountEpoch }, original);
    assert.equal((await cache.read(secondVaultScope)).accountEpoch, 1);
    assert.equal((await cache.read(otherAccountScope)).accountEpoch, 0);
    assert.equal(await cache.getEpoch(otherAccountScope), 0);
    const storedPolicy = await cache.readAttachmentLedger(scope);
    assert.equal(storedPolicy.accountEpoch, 1);
    assert.deepEqual(storedPolicy.state, ledger);
    assert.equal(storedPolicy.version, 1);

    await assert.rejects(
        cache.commit(input(cache, { accountEpoch: original.accountEpoch }), original.version),
        /account_epoch_mismatch/,
    );
    await assert.rejects(
        cache.writeAttachmentLedger({ scope, state: ledger, accountEpoch: original.accountEpoch }, storedPolicy.version),
        /account_epoch_mismatch/,
    );
    const next = await cache.commit(
        input(cache, { accountEpoch: preserved.accountEpoch, cursor: 11 }),
        preserved.version,
    );
    assert.equal(next.cursor, 11);
    cache.close();
});

test("preserveAccount does not revive snapshots and policies from an older epoch", async () => {
    const factory = new IDBFactory();
    const cache = createEncryptedCache(factory);
    const ledger = { formatVersion: 1, records: {}, offlineAttachments: [], downloadAllVersions: [] };
    await cache.commit(input(cache), null, { state: ledger, expectedVersion: null });
    await cache.preserveAccount(scope.userId);

    const db = await databaseFor(factory);
    const key = `${scope.origin}\u0000${scope.userId}\u0000${scope.vaultId}`;
    const tx = db.transaction(["snapshots", "attachmentPolicies"], "readwrite");
    for (const storeName of ["snapshots", "attachmentPolicies"]) {
        const store = tx.objectStore(storeName);
        const request = store.get(key);
        request.onsuccess = () => store.put({ ...request.result, accountEpoch: 0 }, key);
    }
    await new Promise((resolve, reject) => {
        tx.oncomplete = resolve;
        tx.onabort = () => reject(tx.error);
        tx.onerror = () => reject(tx.error);
    });
    await cache.preserveAccount(scope.userId);

    assert.equal(await cache.getEpoch(scope), 2);
    assert.equal(await cache.read(scope), null);
    assert.equal(await cache.readAttachmentLedger(scope), null);
    const inspect = db.transaction(["snapshots", "attachmentPolicies"], "readonly");
    const [storedSnapshot, storedPolicy] = await Promise.all([
        new Promise(resolve => { const request = inspect.objectStore("snapshots").get(key); request.onsuccess = () => resolve(request.result); }),
        new Promise(resolve => { const request = inspect.objectStore("attachmentPolicies").get(key); request.onsuccess = () => resolve(request.result); }),
    ]);
    assert.equal(storedSnapshot.accountEpoch, 0);
    assert.equal(storedPolicy.accountEpoch, 0);
    db.close();
    cache.close();
});

test("removeAccount clears matching records across origins and rejects commits using the old epoch", async () => {
    const cache = createEncryptedCache(new IDBFactory());
    const original = await seed(cache);
    const otherOriginScope = { ...scope, origin: "https://other.example" };
    await cache.commit(input(cache, { scope: otherOriginScope }), null);
    const pending = cache.commit(input(cache, { cursor: 30, accountEpoch: original.accountEpoch }), original.version);
    await cache.removeAccount(scope.userId);
    const pendingResult = await Promise.allSettled([pending]);
    assert.ok(["fulfilled", "rejected"].includes(pendingResult[0].status));
    assert.equal(await cache.read(scope), null);
    assert.equal(await cache.read(otherOriginScope), null);
    assert.equal(await cache.getEpoch(scope), 1);
    await assert.rejects(
        cache.commit(input(cache, { cursor: 40, accountEpoch: original.accountEpoch }), original.version),
        /account_epoch_mismatch|cache_version_conflict/,
    );
    assert.equal(await cache.read(scope), null);
    cache.close();
});

test("only allowlisted encrypted row metadata and XML-like payload data are persisted", async () => {
    const factory = new IDBFactory();
    const cache = createEncryptedCache(factory);
    const extraRow = { ...row(), xml: "<card>plaintext</card>", key: "secret-key" };
    await cache.commit(input(cache, { rows: [extraRow] }), null);
    const db = await databaseFor(factory);
    const tx = db.transaction("snapshots", "readonly");
    const stored = await new Promise((resolve, reject) => {
        const request = tx.objectStore("snapshots").openCursor();
        request.onsuccess = () => resolve(request.result?.value);
        request.onerror = () => reject(request.error);
    });
    assert.deepEqual(Object.keys(stored.rows[0]).sort(), ["bodyB64", "kind", "modifiedMs", "revision", "uuid"]);
    assert.equal(JSON.stringify(stored).includes("plaintext"), false);
    assert.equal(JSON.stringify(stored).includes("secret-key"), false);
    db.close();
    cache.close();
});

test("corrupt stored snapshot rejects rather than appearing absent", async () => {
    const factory = new IDBFactory();
    const cache = createEncryptedCache(factory);
    await seed(cache);
    const db = await databaseFor(factory);
    const tx = db.transaction("snapshots", "readwrite");
    tx.objectStore("snapshots").put({ unexpected: true }, "https://relay.example\u0000user-a\u0000vault-a");
    await new Promise((resolve, reject) => {
        tx.oncomplete = resolve;
        tx.onabort = () => reject(tx.error);
    });
    await assert.rejects(cache.read(scope), /encrypted_cache_corrupt/);
    db.close();
    cache.close();
});

test("stored snapshots with extra top-level keys are rejected", async () => {
    const factory = new IDBFactory();
    const cache = createEncryptedCache(factory);
    await seed(cache);
    const db = await databaseFor(factory);
    const tx = db.transaction("snapshots", "readwrite");
    const request = tx.objectStore("snapshots").openCursor();
    request.onsuccess = () => {
        const cursor = request.result;
        if (!cursor) return;
        cursor.update({ ...cursor.value, xml: "<card>plaintext</card>" });
    };
    await new Promise((resolve, reject) => {
        tx.oncomplete = resolve;
        tx.onabort = () => reject(tx.error);
    });
    await assert.rejects(cache.read(scope), /encrypted_cache_corrupt/);
    db.close();
    cache.close();
});

test("duplicate row UUIDs are rejected", async () => {
    const cache = createEncryptedCache(new IDBFactory());
    await assert.rejects(cache.commit(input(cache, { rows: [row(), row()] }), null), /encrypted_cache_invalid_row/);
    cache.close();
});

test("snapshot version overflow is rejected", async () => {
    const factory = new IDBFactory();
    const cache = createEncryptedCache(factory);
    const db = await databaseFor(factory);
    const tx = db.transaction("snapshots", "readwrite");
    tx.objectStore("snapshots").put({
        scope,
        envelope: "synthetic-envelope",
        passwordVersion: 1,
        cursor: 10,
        version: Number.MAX_SAFE_INTEGER,
        accountEpoch: 0,
        rows: [row()],
    }, "https://relay.example\u0000user-a\u0000vault-a");
    await new Promise((resolve, reject) => {
        tx.oncomplete = resolve;
        tx.onabort = () => reject(tx.error);
    });
    await assert.rejects(cache.commit(input(cache), Number.MAX_SAFE_INTEGER), /encrypted_cache_invalid_snapshot|encrypted_cache_corrupt/);
    db.close();
    cache.close();
});
