import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { createUnlockSession } from "../dist/storage/unlock-session.js";
import { decryptItemBodyWithKey, importVaultDecryptKey, unwrapEnvelope, wrapEnvelope } from "../dist/core/vault-crypto.js";
import { isRequestMessage } from "../dist/messaging/protocol.js";

const fixture = JSON.parse(readFileSync(new URL("fixtures/item-vector.json", import.meta.url), "utf8"));
const vaultKey = [...Buffer.from(fixture.vek, "base64")];
const context = { token: "fixture-token", vaultId: "fixture-vault", userId: "fixture-user" };
const original = { id: "a", title: "Fixture", symbol: null, fields: [], host: "",
    source: { xml: "<card/>", revision: 1 } };
const row = { uuid: fixture.uuid, bodyB64: fixture.body, revision: 1, kind: 1, modifiedMs: 1000 };
const request = (action, extra = {}) => ({ type: "vault-session", action, context, ...extra });

function harness({ memory = false } = {}) {
    let time = 1000;
    let nextId = 0;
    const local = { "relay.session": { token: context.token, userId: context.userId, expiresAt: 0 },
        "relay.vault": { id: context.vaultId } };
    const session = {};
    const logs = [];
    const area = data => ({
        async get(keys) { return structuredClone(Object.fromEntries(keys.map(key => [key, data[key]]))); },
        async set(values) { Object.assign(data, structuredClone(values)); },
        async remove(keys) { for (const key of keys) delete data[key]; },
    });
    const options = { local: area(local), session: memory ? null : area(session),
        now: () => time, idleMs: 100, makeId: () => `generation-${++nextId}`,
        log: (...args) => logs.push(args) };
    const unlock = createUnlockSession(options);
    const commit = async (extra = {}) => {
        const begun = await unlock.handle(request("begin"));
        return unlock.handle(request("commit", { generation: begun.generation, items: [original],
            vaultKey, snapshotVersion: 1, passwordVersion: 7, ...extra }));
    };
    return { unlock, local, session, logs, commit, restart: () => createUnlockSession(options),
        advance: amount => { time += amount; } };
}

function assertNoKey(response) {
    assert.equal("vaultKey" in response, false);
    assert.equal(JSON.stringify(response).includes(JSON.stringify(vaultKey)), false);
}

for (const memory of [false, true]) {
    test(`key supports decrypt in ${memory ? "memory" : "trusted session"} only, never generic responses`, async () => {
        const h = harness({ memory });
        const committed = await h.commit();
        assertNoKey(committed);
        const current = memory ? h.unlock : h.restart();
        const decrypted = await current.handle(request("decrypt", { generation: committed.generation, rows: [row] }));
        assert.equal(decrypted.unlocked, true);
        assert.deepEqual(decrypted.fragments, [{ uuid: row.uuid, xml: fixture.fragment,
            revision: row.revision, kind: row.kind, modifiedMs: row.modifiedMs }]);
        assert.equal(decrypted.snapshotVersion, 1);
        assert.equal(decrypted.passwordVersion, 7);
        assertNoKey(decrypted);
        for (const response of [await current.inspect(), await current.handle(request("read")),
            await current.handle(request("touch", { generation: committed.generation }))]) assertNoKey(response);
        const replacement = { ...original, source: { xml: "<card/>", revision: 2 } };
        assertNoKey(await current.handle(request("replace", { generation: committed.generation, item: replacement })));
        const localText = JSON.stringify(h.local);
        assert.equal(localText.includes("<card"), false);
        assert.equal(localText.includes("vaultKey"), false);
        assert.equal(JSON.stringify(h.logs).includes(fixture.fragment), false);
        assert.equal(JSON.stringify(h.logs).includes(JSON.stringify(vaultKey)), false);
        await current.handle(request("lock"));
        assert.equal(h.session["upw.unlockSession"], undefined);
        assert.equal((await current.handle(request("decrypt", { generation: committed.generation, rows: [row] }))).unlocked, false);
    });
}

test("decrypt and refresh do not renew TTL, refresh atomically replaces same generation", async () => {
    const h = harness();
    const committed = await h.commit();
    h.advance(40);
    assert.equal((await h.unlock.handle(request("decrypt", { generation: committed.generation, rows: [row] }))).unlocked, true);
    const refreshed = await h.unlock.handle(request("refresh", { generation: committed.generation,
        expectedSnapshotVersion: 1, snapshotVersion: 2, passwordVersion: 7, items: [] }));
    assert.equal(refreshed.unlocked, true);
    assert.equal(refreshed.generation, committed.generation);
    assert.equal(refreshed.expiresAt, committed.expiresAt);
    const read = await h.unlock.handle(request("read"));
    assert.deepEqual(read.items, []);
    assert.equal(read.snapshotVersion, 2);
    assertNoKey(refreshed);
    h.advance(60);
    const expired = await h.unlock.handle(request("decrypt", { generation: committed.generation, rows: [row] }));
    assert.equal(expired.unlocked, false);
    assert.equal("fragments" in expired, false);
    assert.equal(h.session["upw.unlockSession"], undefined);
});

test("same-session edit increments version and stale refresh cannot overwrite it", async () => {
    const h = harness();
    const committed = await h.commit();
    const edited = { ...original, title: "Edited", source: { xml: "<card/>", revision: 2 } };
    const saved = await h.unlock.handle(request("replace", { generation: committed.generation, item: edited }));
    assert.equal(saved.snapshotVersion, 2);
    const stale = await h.unlock.handle(request("refresh", { generation: committed.generation,
        expectedSnapshotVersion: 1, snapshotVersion: 3, passwordVersion: 7, items: [] }));
    assert.equal(stale.code, "session_snapshot_conflict");
    assert.equal("items" in stale, false);
    assert.deepEqual((await h.unlock.handle(request("read"))).items, [edited]);
    const aligned = await h.unlock.handle(request("replace", { generation: committed.generation,
        expectedSnapshotVersion: 2, snapshotVersion: 9,
        item: { ...edited, source: { xml: "<card/>", revision: 3 } } }));
    assert.equal(aligned.snapshotVersion, 9);
    const rejected = await h.unlock.handle(request("replace", { generation: committed.generation,
        expectedSnapshotVersion: 2, snapshotVersion: 10,
        item: { ...edited, source: { xml: "<card/>", revision: 4 } } }));
    assert.equal(rejected.code, "session_snapshot_conflict");
});

test("serialized competing refreshes permit exactly one CAS winner", async () => {
    const h = harness();
    const { generation } = await h.commit();
    const results = await Promise.all([2, 3].map(snapshotVersion => h.unlock.handle(request("refresh", {
        generation, expectedSnapshotVersion: 1, snapshotVersion, passwordVersion: 7, items: [] }))));
    assert.deepEqual(results.map(result => result.unlocked), [true, false]);
    assert.equal(results[1].code, "session_snapshot_conflict");
});

test("missing legacy key and any corrupt row fail the whole decrypt batch", async () => {
    const h = harness();
    const { generation } = await h.commit({ vaultKey: undefined, snapshotVersion: undefined });
    assert.equal((await h.unlock.handle(request("decrypt", { generation, rows: [row] }))).code, "session_key_missing");
    assert.equal((await h.unlock.handle(request("read"))).snapshotVersion, undefined);
    const next = await h.commit();
    for (const rows of [[row, { ...row, uuid: "00000000-0000-4000-8000-000000000000" }],
        [{ ...row, bodyB64: "!!!" }], [{ ...row, revision: 0 }], [row, row],
        ...["card", "1", 0, 4, null, undefined].map(kind => [{ ...row, kind }])]) {
        const failed = await h.unlock.handle(request("decrypt", { generation: next.generation, rows }));
        assert.equal(failed.unlocked, false);
        assert.equal(typeof failed.code, "string");
        assert.equal("fragments" in failed, false);
    }
});

test("user-bound offline context survives token expiry but not changed identity/token/vault", async () => {
    for (const change of ["userId", "token", "vault"]) {
        const h = harness();
        const { generation } = await h.commit();
        assert.equal((await h.unlock.handle(request("read"))).unlocked, true);
        assert.equal(h.local["relay.session"].expiresAt, 0);
        assert.equal((await h.unlock.handle(request("read", { context: { ...context, userId: "foreign" } }))).unlocked, false);
        assert.equal((await h.unlock.handle(request("read"))).unlocked, true);
        if (change === "vault") h.local["relay.vault"].id = "other";
        else h.local["relay.session"][change] = "other";
        assert.equal((await h.unlock.handle(request("decrypt", { generation, rows: [row] }))).unlocked, false);
        assert.equal(h.session["upw.unlockSession"], undefined);
    }
});

test("invalid keys and versions cannot commit or mutate a session", async () => {
    for (const invalid of [[], vaultKey.slice(1), [...vaultKey, 1], Array(32).fill(256),
        Array(32).fill(1.5), Array(32).fill(NaN), new Array(32)]) {
        const h = harness();
        assert.equal((await h.commit({ vaultKey: invalid })).code, "invalid_session_commit");
    }
    const h = harness();
    const { generation } = await h.commit();
    for (const extra of [{ snapshotVersion: 1 }, { snapshotVersion: -1 }, { passwordVersion: 8 },
        { expectedSnapshotVersion: 0 }, { snapshotVersion: NaN }]) {
        const result = await h.unlock.handle(request("refresh", { generation, expectedSnapshotVersion: 1,
            snapshotVersion: 2, passwordVersion: 7, items: [], ...extra }));
        assert.equal(result.unlocked, false);
    }
    assert.equal((await h.unlock.handle(request("read"))).snapshotVersion, 1);
    for (const action of ["read", "touch", "decrypt", "refresh"]) {
        assert.equal((await h.unlock.handle(request(action, { generation: "old", rows: [row] }))).unlocked, false);
    }
});

test("lock immediately invalidates epoch during an awaited decrypt; no partial plaintext escapes", async () => {
    const h = harness();
    const { generation } = await h.commit();
    const realDecrypt = crypto.subtle.decrypt.bind(crypto.subtle);
    let entered;
    let resume;
    const waiting = new Promise(resolve => { entered = resolve; });
    const release = new Promise(resolve => { resume = resolve; });
    crypto.subtle.decrypt = async (...args) => {
        const plaintext = await realDecrypt(...args);
        entered();
        await release;
        return plaintext;
    };
    try {
        const decrypting = h.unlock.handle(request("decrypt", { generation, rows: [row] }));
        await waiting;
        const locking = h.unlock.handle(request("lock"));
        const queued = h.unlock.handle(request("decrypt", { generation, rows: [row] }));
        resume();
        const result = await decrypting;
        assert.equal(result.unlocked, false);
        assert.equal("fragments" in result, false);
        await locking;
        assert.equal((await queued).unlocked, false);
        assert.equal(h.session["upw.unlockSession"], undefined);
    } finally {
        crypto.subtle.decrypt = realDecrypt;
    }
});

test("imported AES-256 key is decrypt-only/nonextractable and matches raw helper vectors", async () => {
    const key = await importVaultDecryptKey(Uint8Array.from(vaultKey));
    assert.equal(key.extractable, false);
    assert.deepEqual(key.usages, ["decrypt"]);
    await assert.rejects(() => crypto.subtle.exportKey("raw", key));
    const body = new Uint8Array(Buffer.from(row.bodyB64, "base64"));
    assert.equal(await decryptItemBodyWithKey(body, key, row.uuid), fixture.fragment);
    await assert.rejects(() => decryptItemBodyWithKey(body, key, "other"), /item_decrypt_failed/);
    await assert.rejects(() => importVaultDecryptKey(new Uint8Array(16)), /invalid_vault_key/);
});

test("request discriminator accepts both new session commands", () => {
    assert.equal(isRequestMessage(request("decrypt")), true);
    assert.equal(isRequestMessage(request("refresh")), true);
    assert.equal(isRequestMessage(request("unknown")), false);
});

test("conditional lock never invalidates a newer generation, but matching lock clears key", async () => {
    const h = harness();
    const old = await h.commit();
    const current = await h.commit();
    const result = await h.unlock.handle(request("lock", { generation: old.generation }));
    assert.equal(result.unlocked, false);
    assert.equal(result.code, "session_generation_mismatch");
    assert.equal((await h.unlock.handle(request("read"))).generation, current.generation);
    assert.equal((await h.unlock.handle(request("decrypt", { generation: current.generation, rows: [row] }))).unlocked, true);
    await h.unlock.handle(request("lock", { generation: current.generation }));
    assert.equal(h.session["upw.unlockSession"], undefined);
    assert.equal((await h.unlock.inspect()).unlocked, false);
});

for (const change of ["conditional-lock", "old-lock", "invalidate", "token", "idle-expiry"]) {
    test(`decrypt: ${change} while awaiting WebCrypto obeys epoch and generation`, async () => {
        const h = harness();
        const old = await h.commit();
        const { generation } = await h.commit();
        const realDecrypt = crypto.subtle.decrypt.bind(crypto.subtle);
        let entered;
        let resume;
        const waiting = new Promise(resolve => { entered = resolve; });
        const release = new Promise(resolve => { resume = resolve; });
        crypto.subtle.decrypt = async (...args) => {
            const plaintext = await realDecrypt(...args);
            entered();
            await release;
            return plaintext;
        };
        try {
            const pending = h.unlock.handle(request("decrypt", { generation, rows: [row] }));
            await waiting;
            let cleanup;
            if (change === "conditional-lock") cleanup = h.unlock.handle(request("lock", { generation }));
            if (change === "old-lock") cleanup = h.unlock.handle(request("lock", { generation: old.generation }));
            if (change === "invalidate") cleanup = h.unlock.invalidate();
            if (change === "token") h.local["relay.session"].token = "changed";
            if (change === "idle-expiry") h.advance(100);
            resume();
            const result = await pending;
            await cleanup;
            assert.equal(result.unlocked, change === "old-lock");
            if (change !== "old-lock") {
                assert.equal("fragments" in result, false);
                assert.equal(h.session["upw.unlockSession"], undefined);
            }
        } finally {
            crypto.subtle.decrypt = realDecrypt;
        }
    });
}

test("wrapping/unwrapping clears controllable password and KEK byte buffers on success and failure", async () => {
    const realImport = crypto.subtle.importKey.bind(crypto.subtle);
    const captured = [];
    crypto.subtle.importKey = async (...args) => {
        if (args[0] === "raw") captured.push(args[1]);
        return realImport(...args);
    };
    try {
        const wrapped = await wrapEnvelope("fixture-password", 100_000);
        assert.equal(captured.length, 2);
        assert.ok(captured.every(bytes => Array.from(bytes).every(byte => byte === 0)));
        captured.length = 0;
        assert.deepEqual(await unwrapEnvelope(wrapped.envelope, "fixture-password"), wrapped.vek);
        assert.ok(captured.every(bytes => Array.from(bytes).every(byte => byte === 0)));
        captured.length = 0;
        await assert.rejects(() => unwrapEnvelope(wrapped.envelope, "wrong"), /wrong_password/);
        assert.ok(captured.every(bytes => Array.from(bytes).every(byte => byte === 0)));
    } finally {
        crypto.subtle.importKey = realImport;
    }
});

test("decrypt preserves numeric card and label kinds across the popup/background contract", async () => {
    const h = harness();
    const { generation } = await h.commit();
    for (const kind of [1, 2]) {
        const result = await h.unlock.handle(request("decrypt", { generation, rows: [{ ...row, kind }] }));
        assert.equal(result.unlocked, true);
        assert.equal(result.fragments[0].kind, kind);
    }
});
