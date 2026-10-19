import assert from "node:assert/strict";
import test from "node:test";
import { createUnlockSession, UNLOCK_SESSION_TTL_MS } from "../dist/storage/unlock-session.js";

const item = { id: "a", title: "Empty fields", symbol: null, fields: [], host: "" };

function harness({ persistent = true, ttl = UNLOCK_SESSION_TTL_MS, lockMinutes } = {}) {
    let time = 10_000;
    let pause = null;
    const localData = {
        "relay.session": { token: "token-one", expiresAt: 1_000_000 },
        "relay.vault": { id: "vault-one" },
        "vault.items": [{ id: "legacy-plaintext" }],
    };
    if (lockMinutes !== undefined) localData["extension.lockMinutes"] = lockMinutes;
    const sessionData = {};
    async function checkpoint(operation) {
        if (!pause || pause.operation !== operation) return;
        const pending = pause;
        pause = null;
        pending.entered();
        await pending.release;
    }
    const area = (data, name) => ({
        async get(keys) {
            const snapshot = structuredClone(Object.fromEntries(keys.map((key) => [key, data[key]])));
            await checkpoint(`${name}.get`);
            return snapshot;
        },
        async set(entries) {
            Object.assign(data, structuredClone(entries));
            await checkpoint(`${name}.set`);
        },
        async remove(keys) { for (const key of keys) delete data[key]; },
    });
    const pauseNext = (operation) => {
        let entered;
        let resume;
        const waiting = new Promise((resolve) => { entered = resolve; });
        const release = new Promise((resolve) => { resume = resolve; });
        pause = { operation, entered, release };
        return { waiting, resume };
    };
    let id = 0;
    const unlock = createUnlockSession({
        local: area(localData, "local"),
        session: persistent ? area(sessionData, "session") : null,
        now: () => time,
        makeId: () => `generation-${++id}`,
        idleMs: ttl,
    });
    return { unlock, localData, sessionData, pauseNext, advance: (amount) => { time += amount; } };
}

const context = { token: "token-one", vaultId: "vault-one" };

async function beginAndCommit(unlock, items = [item]) {
    const begun = await unlock.handle({ type: "vault-session", action: "begin", context });
    const committed = await unlock.handle({
        type: "vault-session", action: "commit", context, generation: begun.generation, items,
    });
    return { begun, committed };
}

test("restricted session storage survives instance recreation without local plaintext", async () => {
    const h = harness();
    const { committed } = await beginAndCommit(h.unlock);
    assert.equal(committed.unlocked, true);
    assert.equal(h.localData["vault.items"], null);
    const second = createUnlockSession({
        local: {
            async get(keys) { return Object.fromEntries(keys.map((key) => [key, h.localData[key]])); },
            async set(values) { Object.assign(h.localData, values); },
        },
        session: {
            async get(keys) { return Object.fromEntries(keys.map((key) => [key, h.sessionData[key]])); },
            async set(values) { Object.assign(h.sessionData, structuredClone(values)); },
            async remove(keys) { for (const key of keys) delete h.sessionData[key]; },
        },
        now: () => 10_000,
    });
    const read = await second.handle({ type: "vault-session", action: "read", context });
    assert.equal(read.unlocked, true);
    assert.deepEqual(read.items, [item]);
});

test("memory fallback reports nonpersistent and safely loses state with background lifetime", async () => {
    const h = harness({ persistent: false });
    const { committed } = await beginAndCommit(h.unlock, []);
    assert.equal(committed.unlocked, true);
    assert.equal(committed.persistent, false);
    const restarted = harness({ persistent: false }).unlock;
    assert.equal((await restarted.handle({ type: "vault-session", action: "read" })).unlocked, false);
});

test("empty vault is unlocked, while idle expiry locks before returning data", async () => {
    const h = harness({ ttl: 100 });
    await beginAndCommit(h.unlock, []);
    const empty = await h.unlock.handle({ type: "vault-session", action: "read", context });
    assert.equal(empty.unlocked, true);
    assert.deepEqual(empty.items, []);
    h.advance(100);
    const expired = await h.unlock.handle({ type: "vault-session", action: "read", context });
    assert.equal(expired.unlocked, false);
    assert.equal("items" in expired, false);
});

test("lock and changed relay context invalidate sessions and stale commits", async () => {
    const h = harness();
    const begun = await h.unlock.handle({ type: "vault-session", action: "begin", context });
    await h.unlock.handle({ type: "vault-session", action: "lock" });
    const stale = await h.unlock.handle({
        type: "vault-session", action: "commit", context, generation: begun.generation, items: [item],
    });
    assert.equal(stale.unlocked, false);

    const next = await h.unlock.handle({ type: "vault-session", action: "begin", context });
    const invalid = await h.unlock.handle({
        type: "vault-session", action: "commit", context, generation: next.generation, items: [item],
    });
    assert.equal(invalid.unlocked, true);
    h.localData["relay.vault"] = { id: "vault-two" };
    assert.equal((await h.unlock.handle({ type: "vault-session", action: "read", context })).unlocked, false);
});

test("session operations serialize competing commits", async () => {
    const h = harness();
    const begun = await h.unlock.handle({ type: "vault-session", action: "begin", context });
    const [first, second] = await Promise.all([
        h.unlock.handle({ type: "vault-session", action: "commit", context, generation: begun.generation, items: [item] }),
        h.unlock.handle({ type: "vault-session", action: "commit", context, generation: begun.generation, items: [] }),
    ]);
    assert.deepEqual([first.unlocked, second.unlocked], [true, false]);
});

test("idle deadline honors supported user timeout setting and rejects invalid values", async () => {
    const h = harness({ lockMinutes: 5 });
    const { committed } = await beginAndCommit(h.unlock);
    assert.equal(committed.expiresAt, 10_000 + 5 * 60_000);
    const invalid = harness({ lockMinutes: 2, ttl: 123 });
    const fallback = await beginAndCommit(invalid.unlock);
    assert.equal(fallback.committed.expiresAt, 10_000 + 123);
});

test("mismatched request account context cannot begin, read, touch, or commit", async () => {
    const h = harness();
    const foreign = { token: "token-two", vaultId: "vault-two" };
    const begin = await h.unlock.handle({ type: "vault-session", action: "begin", context: foreign });
    assert.equal(begin.unlocked, false);
    await beginAndCommit(h.unlock);
    const read = await h.unlock.handle({ type: "vault-session", action: "read", context: foreign });
    const touch = await h.unlock.handle({ type: "vault-session", action: "touch", context: foreign });
    const commit = await h.unlock.handle({
        type: "vault-session", action: "commit", context: foreign,
        generation: "generation-1", items: [item],
    });
    assert.equal(read.unlocked, false);
    assert.equal(touch.unlocked, false);
    assert.equal(commit.unlocked, false);
    assert.equal((await h.unlock.handle({ type: "vault-session", action: "read", context })).unlocked, true);
});

test("read polling never extends expiry but explicit interaction renews it", async () => {
    const h = harness({ ttl: 100 });
    const { committed } = await beginAndCommit(h.unlock);
    h.advance(50);
    const read = await h.unlock.handle({ type: "vault-session", action: "read", context });
    assert.equal(read.expiresAt, committed.expiresAt);
    const touched = await h.unlock.handle({ type: "vault-session", action: "touch", context });
    assert.equal(touched.expiresAt, committed.expiresAt + 50);
    h.advance(100);
    assert.equal((await h.unlock.handle({ type: "vault-session", action: "read", context })).unlocked, false);
});

test("authentication expiry locks even if the vault deadline has not elapsed", async () => {
    const h = harness();
    await beginAndCommit(h.unlock);
    h.localData["relay.session"].expiresAt = 10_000;
    assert.equal((await h.unlock.handle({ type: "vault-session", action: "read", context })).unlocked, false);
    assert.equal(h.sessionData["upw.unlockSession"], undefined);
});

test("failed session access restriction falls back to background memory before storing data", async () => {
    const h = harness();
    let sessionAccesses = 0;
    const unlock = createUnlockSession({
        local: {
            async get(keys) { return Object.fromEntries(keys.map(key => [key, h.localData[key]])); },
            async set(values) { Object.assign(h.localData, values); },
        },
        session: {
            async get() { sessionAccesses++; return {}; },
            async set() { sessionAccesses++; },
        },
        configureSessionStorage: async () => { throw new Error('unavailable'); },
        now: () => 10_000,
    });
    const { committed } = await beginAndCommit(unlock);
    assert.equal(committed.unlocked, true);
    assert.equal(committed.persistent, false);
    assert.equal(unlock.persistent, false);
    assert.equal(sessionAccesses, 0);
    assert.equal((await unlock.handle({ type: "vault-session", action: "read", context })).unlocked, true);
});

test("background inspection never renews idle deadline and clears invalid context", async () => {
    const h = harness({ ttl: 100 });
    const { committed } = await beginAndCommit(h.unlock);
    h.advance(50);
    const snapshot = await h.unlock.inspect();
    assert.equal(snapshot.expiresAt, committed.expiresAt);
    assert.deepEqual(snapshot.items, [item]);
    h.advance(50);
    assert.equal((await h.unlock.inspect()).unlocked, false);
    await beginAndCommit(h.unlock);
    delete h.localData["relay.session"];
    assert.equal((await h.unlock.inspect()).unlocked, false);
    assert.equal(h.sessionData["upw.unlockSession"], undefined);
});

test("saved item replacement is generation-bound, edit-only, and session-only", async () => {
    const h = harness();
    const original = { ...item, source: { xml: '<card id="a"/>', revision: 1 } };
    const { committed } = await beginAndCommit(h.unlock, [original]);
    const updated = { ...item, title: "Updated", source: { xml: '<card id="a"/>', revision: 2 } };
    const replace = (extra = {}) => h.unlock.handle({
        type: "vault-session", action: "replace", context,
        generation: committed.generation, item: updated, ...extra,
    });
    assert.equal((await replace({ generation: "stale" })).unlocked, false);
    assert.equal((await replace({ context: { token: "other", vaultId: "vault-one" } })).unlocked, false);
    assert.equal((await replace({ item: { ...updated, id: "missing" } })).unlocked, false);
    const saved = await replace();
    assert.equal(saved.unlocked, true);
    assert.equal(saved.generation, committed.generation);
    assert.deepEqual(saved.items, [updated]);
    assert.equal(h.localData["vault.items"], null);
    assert.equal(JSON.stringify(h.localData).includes("<card"), false);
    await h.unlock.handle({ type: "vault-session", action: "lock" });
    assert.equal((await replace()).unlocked, false);
    assert.equal((await h.unlock.inspect()).unlocked, false);
});

test("replacement cannot commit pending unlocks or revive expired sessions", async () => {
    const h = harness({ ttl: 10 });
    const begun = await h.unlock.handle({ type: "vault-session", action: "begin", context });
    const request = { type: "vault-session", action: "replace", context, generation: begun.generation, item };
    assert.equal((await h.unlock.handle(request)).unlocked, false);
    const { committed } = await beginAndCommit(h.unlock);
    h.advance(10);
    assert.equal((await h.unlock.handle({ ...request, generation: committed.generation })).unlocked, false);
});

test("replacement requires valid strictly increasing source revisions for an existing ID", async () => {
    const h = harness();
    const original = { ...item, source: { xml: "fixture", revision: 2 } };
    const { committed } = await beginAndCommit(h.unlock, [original]);
    const replace = (replacement) => h.unlock.handle({
        type: "vault-session", action: "replace", context,
        generation: committed.generation, item: replacement,
    });
    for (const source of [undefined, null, {}, { xml: 1, revision: 3 },
        ...[undefined, 0, -1, 1, 2, 2.5, NaN, Infinity, Number.MAX_SAFE_INTEGER + 1]
            .map((revision) => ({ xml: "fixture", revision }))]) {
        assert.equal((await replace({ ...item, source })).unlocked, false);
    }
    assert.equal((await replace({ ...original, id: "other", source: { xml: "fixture", revision: 3 } })).unlocked, false);
    const revision4 = { ...original, source: { xml: "fixture", revision: 4 } };
    assert.equal((await replace(revision4)).unlocked, true);
    assert.equal((await replace({ ...original, source: { xml: "fixture", revision: 3 } })).unlocked, false);
    assert.equal((await replace(revision4)).unlocked, false);
    assert.equal((await h.unlock.inspect()).items[0].source.revision, 4);
});

for (const action of ["begin", "commit", "replace", "touch"]) {
    for (const change of ["vault", "token", "auth-expiry", "invalidate", "lock", "idle-expiry"]) {
        test(`${action}: ${change} during awaited session write fails closed`, async () => {
            const h = harness({ ttl: 100 });
            const original = { ...item, source: { xml: "fixture", revision: 1 } };
            const { committed } = await beginAndCommit(h.unlock, [original]);
            let generation = committed.generation;
            if (action === "commit") {
                generation = (await h.unlock.handle({ type: "vault-session", action: "begin", context })).generation;
            }
            const gate = h.pauseNext("session.set");
            const pending = h.unlock.handle({
                type: "vault-session", action, context, generation,
                items: [original], item: { ...original, source: { xml: "fixture", revision: 2 } },
            });
            await gate.waiting;
            let cleanup;
            if (change === "vault") h.localData["relay.vault"] = { id: "other-vault" };
            if (change === "token") h.localData["relay.session"].token = "other-token";
            if (change === "auth-expiry") h.localData["relay.session"].expiresAt = 0;
            if (change === "idle-expiry") h.advance(100);
            if (change === "invalidate") cleanup = h.unlock.invalidate();
            if (change === "lock") cleanup = h.unlock.handle({ type: "vault-session", action: "lock" });
            gate.resume();
            const result = await pending;
            await cleanup;
            assert.equal(result.unlocked, false);
            assert.equal("items" in result, false);
            assert.equal("generation" in result, false);
            assert.equal(h.sessionData["upw.unlockSession"], undefined);
        });
    }
}

for (const action of ["read", "inspect"]) {
    for (const change of ["vault", "invalidate", "lock", "idle-expiry"]) {
        test(`${action}: ${change} during awaited snapshot read never returns plaintext`, async () => {
            const h = harness({ ttl: 100 });
            await beginAndCommit(h.unlock);
            const gate = h.pauseNext("session.get");
            const pending = action === "inspect" ? h.unlock.inspect()
                : h.unlock.handle({ type: "vault-session", action: "read", context });
            await gate.waiting;
            let cleanup;
            if (change === "vault") h.localData["relay.vault"] = { id: "other-vault" };
            if (change === "invalidate") cleanup = h.unlock.invalidate();
            if (change === "lock") cleanup = h.unlock.handle({ type: "vault-session", action: "lock" });
            if (change === "idle-expiry") h.advance(100);
            gate.resume();
            const result = await pending;
            await cleanup;
            assert.equal(result.unlocked, false);
            assert.equal("items" in result, false);
            assert.equal(h.sessionData["upw.unlockSession"], undefined);
        });
    }
}

test("invalidation epoch rejects in-flight context ABA and queued operations", async () => {
    const h = harness();
    await beginAndCommit(h.unlock);
    const gate = h.pauseNext("session.get");
    const reading = h.unlock.inspect();
    await gate.waiting;
    const queued = h.unlock.handle({ type: "vault-session", action: "begin", context });
    h.localData["relay.vault"] = { id: "other-vault" };
    const invalidating = h.unlock.invalidate();
    h.localData["relay.vault"] = { id: context.vaultId };
    gate.resume();
    assert.equal((await reading).unlocked, false);
    assert.equal((await queued).generation, undefined);
    await invalidating;
    assert.equal(h.sessionData["upw.unlockSession"], undefined);
});

test("purge clears expired secure state and deprecated plaintext key", async () => {
    const h = harness({ ttl: 20 });
    await beginAndCommit(h.unlock);
    h.advance(20);
    await h.unlock.purge();
    assert.equal(h.sessionData["upw.unlockSession"], undefined);
    assert.equal(h.localData["vault.items"], null);
});

for (const change of ["lock", "invalidate", "token", "idle-expiry"]) {
    test(`refresh: ${change} during awaited write clears the entire key-bearing record`, async () => {
        const h = harness({ ttl: 100 });
        const begun = await h.unlock.handle({ type: "vault-session", action: "begin", context });
        await h.unlock.handle({ type: "vault-session", action: "commit", context,
            generation: begun.generation, items: [item], vaultKey: Array(32).fill(83),
            snapshotVersion: 1, passwordVersion: 2 });
        const gate = h.pauseNext("session.set");
        const pending = h.unlock.handle({ type: "vault-session", action: "refresh", context,
            generation: begun.generation, expectedSnapshotVersion: 1, snapshotVersion: 2,
            passwordVersion: 2, items: [] });
        await gate.waiting;
        let cleanup;
        if (change === "lock") cleanup = h.unlock.handle({ type: "vault-session", action: "lock" });
        if (change === "invalidate") cleanup = h.unlock.invalidate();
        if (change === "token") h.localData["relay.session"].token = "changed";
        if (change === "idle-expiry") h.advance(100);
        gate.resume();
        const result = await pending;
        await cleanup;
        assert.equal(result.unlocked, false);
        assert.equal("items" in result, false);
        assert.equal("vaultKey" in result, false);
        assert.equal(h.sessionData["upw.unlockSession"], undefined);
    });
}
