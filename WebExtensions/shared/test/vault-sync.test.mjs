import { test } from "node:test";
import assert from "node:assert/strict";
import { indexedDB } from "fake-indexeddb";
import { createEncryptedCache } from "../dist/storage/encrypted-cache.js";
import { RelayApiError } from "../dist/api/relay.js";
import { synchronizeVault, VaultSyncError } from "../dist/sync/vault-sync.js";

const scope = { userId: "u1", vaultId: "v1", origin: "https://api.example" };
let scopeCounter = 0;
const freshScope = () => ({ ...scope, userId: `u${++scopeCounter}` });
const UUID_A = "00000000-0000-4000-8000-000000000001";
const UUID_B = "00000000-0000-4000-8000-000000000002";
const UUID_OLD = "00000000-0000-4000-8000-000000000003";
const UUID_NEW = "00000000-0000-4000-8000-000000000004";
const id = (value) => ({ a: UUID_A, b: UUID_B, old: UUID_OLD, new: UUID_NEW })[value.toLowerCase()] ?? value;
const row = (uuid, revision, bodyB64 = btoa(`cipher-${revision}`)) => ({
    uuid: id(uuid), kind: 1, revision, bodyB64, modifiedMs: revision,
});
const meta = (headSeq, passwordVersion = 1) => ({
    vaultId: "v1", name: "vault", passwordVersion, hasEnvelope: true, headSeq, itemCount: 1,
});

function routeFetch(handler) {
    const calls = [];
    globalThis.fetch = async (input) => {
        const url = new URL(String(input));
        calls.push(url.pathname + url.search);
        const result = await handler(url);
        return result instanceof Response ? result : new Response(JSON.stringify(result));
    };
    return calls;
}

async function makeCache() {
    return createEncryptedCache(indexedDB);
}

const validate = async () => {};

function verify(shouldFail = false) {
    return async (rows) => {
        if (shouldFail && rows.length) throw new Error("decrypt_failed");
    };
}

test("encrypted cache commits atomically with CAS and logout fencing", async () => {
    const cache = await makeCache();
    const cacheScope = freshScope();
    const epoch = await cache.getEpoch(cacheScope);
    const first = await cache.commit({
        scope: cacheScope, envelope: "wrapped", passwordVersion: 1, cursor: 4, accountEpoch: epoch, rows: [row("a", 1)],
    }, null);
    assert.equal(first.version, 1);
    await assert.rejects(() => cache.commit({
        scope: cacheScope, envelope: "wrapped", passwordVersion: 1, cursor: 4,
        accountEpoch: epoch, rows: [row("a", 1)],
    }, null), /cache_version_conflict/);
    await cache.removeAccount(cacheScope.userId);
    assert.equal(await cache.read(cacheScope), null);
    assert.notEqual(await cache.getEpoch(cacheScope), epoch);
    await assert.rejects(() => cache.commit({
        scope: cacheScope, envelope: "late", passwordVersion: 1, cursor: 5, accountEpoch: epoch, rows: [],
    }, null), /account_epoch_mismatch/);
    cache.close();
});

test("cold rebuild takes paginated snapshot, verifies and commits atomically", async () => {
    const cache = await makeCache();
    const testScope = freshScope();
    routeFetch(async (url) => {
        if (url.pathname.endsWith("/v1")) return { ...meta(2), envelope: "env1" };
        if (url.pathname.endsWith("/seq")) return { headSeq: 2, passwordVersion: 1 };
        if (url.pathname.endsWith("/items")) {
            if (url.searchParams.has("cursorMs")) {
                return { items: [row("b", 1)], nextCursor: null, headSeq: 2 };
            }
            return { items: [row("a", 1)], nextCursor: { ms: 1, uuid: "a" }, headSeq: 2 };
        }
        if (url.pathname.endsWith("/changes")) return { headSeq: 2, changes: [] };
        throw new Error(url.pathname);
    });
    const result = await synchronizeVault({ token: "t", scope: testScope, cache, validate, verifyRows: verify() });
    assert.equal(result.rebuilt, true);
    assert.equal(result.snapshot.rows.length, 2);
    assert.equal(result.snapshot.cursor, 2);
    assert.equal(result.snapshot.version, 1);
    cache.close();
});

test("delta deduplicates revisions, tracks deletes and no-op leaves version unchanged", async () => {
    const cache = await makeCache();
    const testScope = freshScope();
    const epoch = await cache.getEpoch(testScope);
    await cache.commit({
        scope: testScope, envelope: "env1", passwordVersion: 1, cursor: 3, accountEpoch: epoch,
        rows: [row("a", 1), row("b", 1)],
    }, null);
    routeFetch(async (url) => {
        if (url.pathname.endsWith("/v1")) return { ...meta(6), envelope: "ignored" };
        if (url.pathname.endsWith("/seq")) return { headSeq: 6, passwordVersion: 1 };
        if (url.pathname.endsWith("/changes")) return {
            headSeq: 6,
            changes: [
                { seq: 4, uuid: UUID_A.toUpperCase(), op: "upsert", revision: 2, bodyB64: btoa("cipher-2"), kind: 1, modifiedMs: 2 },
                { seq: 5, uuid: UUID_A, op: "upsert", revision: 2, bodyB64: btoa("cipher-2"), kind: 1, modifiedMs: 2 },
                { seq: 6, uuid: UUID_B, op: "purge", revision: 2, deleted: true },
            ],
        };
        throw new Error(url.pathname);
    });
    const changed = await synchronizeVault({ token: "t", scope: testScope, cache, validate, verifyRows: verify() });
    assert.deepEqual(changed.deletedIds, [UUID_B]);
    assert.equal(changed.snapshot.rows.length, 1);
    const stableVersion = changed.snapshot.version;
    routeFetch(async (url) => {
        if (url.pathname.endsWith("/v1")) return { ...meta(6), envelope: "env1" };
        if (url.pathname.endsWith("/seq")) return { headSeq: 6, passwordVersion: 1 };
        if (url.pathname.endsWith("/changes")) return { headSeq: 6, changes: [] };
        throw new Error(url.pathname);
    });
    const unchanged = await synchronizeVault({ token: "t", scope: testScope, cache, validate, verifyRows: verify() });
    assert.equal(unchanged.snapshot.version, stableVersion);
    assert.equal(unchanged.changedCount, 0);
    cache.close();
});

test("410 causes staged rebuild; failed verification keeps old cache intact", async () => {
    const cache = await makeCache();
    const testScope = freshScope();
    const epoch = await cache.getEpoch(testScope);
    const original = await cache.commit({
        scope: testScope, envelope: "env1", passwordVersion: 1, cursor: 1, accountEpoch: epoch, rows: [row("old", 1)],
    }, null);
    routeFetch(async (url) => {
        if (url.pathname.endsWith("/v1")) return { ...meta(2), envelope: "env1" };
        if (url.pathname.endsWith("/seq")) return { headSeq: 2, passwordVersion: 1 };
        if (url.pathname.endsWith("/changes")) {
            if (url.searchParams.get("since") === "1") {
                return new Response(JSON.stringify({ error: "cursor_expired" }), { status: 410 });
            }
            return { headSeq: 2, changes: [] };
        }
        if (url.pathname.endsWith("/items")) return { items: [row("new", 1)], nextCursor: null, headSeq: 2 };
        throw new Error(url.pathname);
    });
    await assert.rejects(
        () => synchronizeVault({ token: "t", scope: testScope, cache, validate, verifyRows: verify(true) }),
        /decrypt_failed/,
    );
    assert.equal((await cache.read(testScope)).version, original.version);
    cache.close();
});

test("remote password change rejects old key and accepts supplied re-unwrapped version", async () => {
    const cache = await makeCache();
    const testScope = freshScope();
    const epoch = await cache.getEpoch(testScope);
    await cache.commit({
        scope: testScope, envelope: "old-env", passwordVersion: 1, cursor: 1, accountEpoch: epoch, rows: [row("old", 1)],
    }, null);
    routeFetch(async (url) => {
        if (url.pathname.endsWith("/v1")) return { ...meta(2, 2), envelope: "new-env" };
        if (url.pathname.endsWith("/seq")) return { headSeq: 2, passwordVersion: 2 };
        if (url.pathname.endsWith("/items")) return { items: [row("new", 1)], nextCursor: null, headSeq: 2 };
        if (url.pathname.endsWith("/changes")) return { headSeq: 2, changes: [] };
        throw new Error(url.pathname);
    });
    await assert.rejects(
        () => synchronizeVault({
            token: "t", scope: testScope, cache, keyVersion: 1, validate, verifyRows: verify(),
        }),
        (error) => error instanceof VaultSyncError && error.code === "password_changed",
    );
    const rebuilt = await synchronizeVault({
        token: "t", scope: testScope, cache, keyVersion: 2, validate, verifyRows: verify(),
    });
    assert.equal(rebuilt.snapshot.passwordVersion, 2);
    assert.equal(rebuilt.snapshot.envelope, "new-env");
    cache.close();
});

test("cancel callback stops progress before writing cache", async () => {
    const cache = await makeCache();
    const testScope = freshScope();
    let checks = 0;
    const abort = async () => {
        checks += 1;
        if (checks > 3) throw new VaultSyncError("aborted");
    };
    routeFetch(async (url) => {
        if (url.pathname.endsWith("/v1")) return { ...meta(0), envelope: "env1" };
        if (url.pathname.endsWith("/seq")) return { headSeq: 0, passwordVersion: 1 };
        if (url.pathname.endsWith("/items")) return { items: [], nextCursor: null, headSeq: 0 };
        if (url.pathname.endsWith("/changes")) return { headSeq: 0, changes: [] };
        throw new Error(url.pathname);
    });
    await assert.rejects(() => synchronizeVault({
        token: "t", scope: testScope, cache, validate: abort, verifyRows: verify(),
    }), /aborted/);
    assert.equal(await cache.read(testScope), null);
    cache.close();
});

test("relay rejects malformed change pages and exposes expiration status", async () => {
    const { getVaultChanges } = await import("../dist/api/relay.js");
    routeFetch(async () => ({ headSeq: 2, changes: [{ seq: 1, uuid: "x", op: "odd", revision: 1 }] }));
    await assert.rejects(() => getVaultChanges("t", "v1", 0), (error) =>
        error instanceof RelayApiError && error.code === "bad_changes_response");
    routeFetch(async () => new Response("{}", { status: 410 }));
    await assert.rejects(() => getVaultChanges("t", "v1", 0), (error) =>
        error instanceof RelayApiError && error.status === 410);
});
