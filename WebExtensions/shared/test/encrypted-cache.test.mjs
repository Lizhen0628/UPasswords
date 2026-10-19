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

function databaseFor(factory) {
    return new Promise((resolve, reject) => {
        const request = factory.open("upasswords-encrypted-vault-cache", 1);
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
