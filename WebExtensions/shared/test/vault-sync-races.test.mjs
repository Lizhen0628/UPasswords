import { test } from "node:test";
import assert from "node:assert/strict";
import { IDBFactory } from "fake-indexeddb";
import { createEncryptedCache } from "../dist/storage/encrypted-cache.js";
import { synchronizeVault } from "../dist/sync/vault-sync.js";

const UUID = "00000000-0000-0000-0000-000000000001";
const UUID_OTHER = "00000000-0000-0000-0000-000000000002";
const scope = { userId: "user", vaultId: "vault", origin: "https://test.example" };
const row = (revision = 1, uuid = UUID) => ({ uuid, kind: 1, revision, bodyB64: btoa(`cipher${revision}`), modifiedMs: revision });
const validate = async () => {};
const verifyRows = async () => {};

async function setup(cachedRows, cursor = 1) {
    const cache = createEncryptedCache(new IDBFactory());
    if (cachedRows) await cache.commit({
        scope, accountEpoch: 0, envelope: "wrapped", passwordVersion: 1, cursor, rows: cachedRows,
    }, null);
    return cache;
}

function routes(custom = () => undefined) {
    const calls = [];
    globalThis.fetch = async (input) => {
        const url = new URL(String(input));
        calls.push(url.pathname + url.search);
        let value = await custom(url);
        if (value === undefined) {
            if (url.pathname.endsWith("/seq")) value = { headSeq: 2, passwordVersion: 1 };
            else if (url.pathname.endsWith("/vault")) value = {
                vaultId: "vault", name: "name", hasEnvelope: true, passwordVersion: 1,
                headSeq: 2, itemCount: 1, envelope: "wrapped",
            };
            else if (url.pathname.endsWith("/items")) value = { items: [row()], nextCursor: null, headSeq: 2 };
            else if (url.pathname.endsWith("/changes")) value = { headSeq: 2, changes: [] };
            else throw new Error("unexpected_route");
        }
        return value instanceof Response ? value : new Response(JSON.stringify(value));
    };
    return calls;
}

const options = (cache, extra = {}) => ({ token: "test", scope, cache, validate, verifyRows, ...extra });

test("cold init keeps initial epoch: logout while network awaits cannot resurrect account", async () => {
    const cache = await setup();
    let removed = false;
    routes(async (url) => {
        if (url.pathname.endsWith("/items") && !removed) {
            removed = true;
            await cache.removeAccount(scope.userId);
        }
    });
    await assert.rejects(() => synchronizeVault(options(cache)), /account_epoch_mismatch/);
    assert.equal(await cache.read(scope), null);
    cache.close();
});

test("410 rebuild returns and verifies all rows including unchanged rows", async () => {
    const cache = await setup([row(), row(1, UUID_OTHER)]);
    routes((url) => {
        if (url.pathname.endsWith("/changes") && url.searchParams.get("since") === "1") {
            return new Response(JSON.stringify({ error: "cursor_expired" }), { status: 410 });
        }
        if (url.pathname.endsWith("/items")) return { items: [row(), row(2, UUID_OTHER)], nextCursor: null, headSeq: 2 };
    });
    let verified;
    const result = await synchronizeVault(options(cache, { verifyRows: async (rows) => { verified = rows; } }));
    assert.equal(result.rebuilt, true);
    assert.equal(result.changedRows.length, 2);
    assert.equal(verified.length, 2);
    assert.equal(result.changedCount, 1);
    cache.close();
});

test("only explicit cursor_expired 410 is rebuilt", async () => {
    const cache = await setup([row()]);
    const calls = routes((url) => url.pathname.endsWith("/changes")
        ? new Response(JSON.stringify({ error: "another_gone" }), { status: 410 }) : undefined);
    await assert.rejects(() => synchronizeVault(options(cache)), (error) => error.code === "another_gone");
    assert.equal(calls.some((url) => url.includes("/items")), false);
    assert.equal((await cache.read(scope)).version, 1);
    cache.close();
});

test("current-projection same revision is deduplicated and deleted upserts remove rows", async () => {
    const cache = await setup([row(), row(1, UUID_OTHER)], 0);
    routes((url) => {
        if (url.pathname.endsWith("/seq")) return { headSeq: 3, passwordVersion: 1 };
        if (url.pathname.endsWith("/changes")) return { headSeq: 3, changes: [
            { ...row(2), seq: 1, op: "upsert" },
            { ...row(2), seq: 2, op: "upsert" },
            { uuid: UUID_OTHER, revision: 1, seq: 3, op: "upsert", deleted: true },
        ] };
    });
    const result = await synchronizeVault(options(cache));
    assert.equal(result.snapshot.rows.length, 1);
    assert.equal(result.changedRows.length, 1);
    assert.deepEqual(result.deletedIds, [UUID_OTHER]);
    cache.close();
});

test("historical rekey at matching password version is allowed during rebuild", async () => {
    const cache = await setup();
    routes((url) => {
        if (url.pathname.endsWith("/seq")) return { headSeq: 3, passwordVersion: 1 };
        if (url.pathname.endsWith("/changes")) return {
            headSeq: 3, changes: [{ seq: 3, uuid: "", revision: 1, op: "rekey" }],
        };
    });
    const result = await synchronizeVault(options(cache));
    assert.equal(result.snapshot.cursor, 3);
    cache.close();
});

test("rekey in ordinary delta or ahead of authenticated version rejects before disk", async () => {
    for (const cached of [true, false]) {
        const cache = await setup(cached ? [row()] : undefined);
        routes((url) => {
            if (url.pathname.endsWith("/seq")) return { headSeq: 3, passwordVersion: 1 };
            if (url.pathname.endsWith("/changes")) return {
                headSeq: 3, changes: [{ seq: 3, uuid: "", revision: cached ? 1 : 2, op: "rekey" }],
            };
        });
        await assert.rejects(() => synchronizeVault(options(cache)), (error) => error.code === "password_changed");
        assert.equal((await cache.read(scope))?.version ?? null, cached ? 1 : null);
        cache.close();
    }
});

test("full listing detects password rotation before decrypt or commit", async () => {
    const cache = await setup();
    let seqChecks = 0;
    let decrypted = false;
    routes((url) => {
        if (url.pathname.endsWith("/seq")) return { headSeq: 2, passwordVersion: ++seqChecks === 1 ? 1 : 2 };
    });
    await assert.rejects(() => synchronizeVault(options(cache, {
        keyVersion: 1, verifyRows: async () => { decrypted = true; },
    })), (error) => error.code === "password_changed");
    assert.equal(decrypted, false);
    assert.equal(await cache.read(scope), null);
    cache.close();
});

test("commit completion is returned even when subsequent validate would abort", async () => {
    const cache = await setup();
    routes();
    let committed = false;
    const committingCache = {
        ...cache,
        commit: async (...args) => {
            const snapshot = await cache.commit(...args);
            committed = true;
            return snapshot;
        },
    };
    const result = await synchronizeVault(options(committingCache, {
        validate: async () => { if (committed) throw new Error("aborted_after_commit"); },
    }));
    assert.equal(result.snapshot.version, 1);
    assert.equal(committed, true);
    cache.close();
});

test("empty delta never advances to advertised head and bounded retries keep old cache", async () => {
    const cache = await setup([row()]);
    const calls = routes();
    await assert.rejects(() => synchronizeVault(options(cache)), (error) => error.code === "sync_incomplete");
    assert.equal((await cache.read(scope)).cursor, 1);
    assert.equal(calls.filter((url) => url.includes("/changes")).length, 3);
    cache.close();
});

test("snapshot pagination has a hard page cap rather than committing truncated rows", async () => {
    const cache = await setup();
    let pages = 0;
    routes((url) => {
        if (url.pathname.endsWith("/items")) return {
            items: [row()], nextCursor: { ms: ++pages, uuid: UUID }, headSeq: 2,
        };
    });
    await assert.rejects(() => synchronizeVault(options(cache)), (error) => error.code === "too_many_snapshot_pages");
    assert.equal(pages, 200);
    assert.equal(await cache.read(scope), null);
    cache.close();
});

test("non-rekey identities and event high-water marks are strictly validated", async () => {
    const { getVaultChanges } = await import("../dist/api/relay.js");
    for (const value of [
        { headSeq: 1, changes: [{ uuid: "bad", seq: 1, op: "purge", revision: 1 }] },
        { headSeq: 1, changes: [{ uuid: UUID, seq: 2, op: "purge", revision: 1 }] },
        { headSeq: 1, changes: [{ uuid: UUID, seq: 1, op: "rekey", revision: 1 }] },
        { headSeq: 1, changes: [{ uuid: UUID, seq: 1, op: "purge", revision: 0 }] },
    ]) {
        routes(() => value);
        await assert.rejects(() => getVaultChanges("test", "vault", 0), (error) => error.code === "bad_changes_response");
    }
});
