import assert from "node:assert/strict";
import test from "node:test";
import { createBrowserUnlockSession, installSessionBackground } from "../dist/storage/unlock-session.js";

function fakeApi() {
    const listeners = [];
    const lifecycle = new Map();
    const storageChanged = [];
    const local = {
        "relay.session": { token: "t", expiresAt: Date.now() + 60_000 },
        "relay.vault": { id: "v" },
    };
    const session = {};
    const area = (store) => ({
        async get(keys) { return Object.fromEntries(keys.map((key) => [key, store[key]])); },
        async set(values) { Object.assign(store, structuredClone(values)); },
        async remove(keys) { for (const key of keys) delete store[key]; },
        async setAccessLevel({ accessLevel }) { store.accessLevel = accessLevel; },
    });
    const event = () => ({ addListener(listener) { return lifecycle.set(this, listener); } });
    return {
        api: {
            runtime: {
                id: "extension-id",
                getURL(path) { return `moz-extension://id/${path}`; },
                onMessage: { addListener(listener) { listeners.push(listener); } },
                onStartup: event(),
                onInstalled: event(),
            },
            storage: {
                local: area(local),
                session: area(session),
                onChanged: { addListener(listener) { storageChanged.push(listener); } },
            },
            alarms: { create() {}, onAlarm: event() },
        }, listeners, lifecycle, local, session, storageChanged,
    };
}

test("background accepts exact popup sender and denies content or sibling extension", async () => {
    const f = fakeApi();
    installSessionBackground(f.api);
    const listener = f.listeners[0];
    const denied = (sender) => new Promise((resolve) => {
        const keepAlive = listener({ type: "vault-session", action: "begin", context: { token: "t", vaultId: "v" } }, sender, resolve);
        assert.equal(keepAlive, false);
    });
    assert.equal((await denied({ id: "extension-id", url: "https://site.example/", tab: { id: 1 } })).unlocked, false);
    assert.equal((await denied({ id: "other-extension", url: "moz-extension://id/src/popup.html" })).unlocked, false);
    const allowed = new Promise((resolve) => {
        assert.equal(listener({ type: "vault-session", action: "begin", context: { token: "t", vaultId: "v" } }, {
            id: "extension-id", url: "moz-extension://id/src/popup.html",
        }, resolve), true);
    });
    assert.equal((await allowed).type, "vault-session");
});

test("legacy query never returns cached plaintext and remains popup-only", async () => {
    const f = fakeApi();
    f.local["vault.items"] = [{ id: "secret" }];
    installSessionBackground(f.api);
    const listener = f.listeners[0];
    const result = await new Promise((resolve) => {
        assert.equal(listener({ type: "query", host: "example.com" }, {
            id: "extension-id", url: "moz-extension://id/src/popup.html",
        }, resolve), false);
    });
    assert.deepEqual(result, { type: "locked" });
    const denied = await new Promise((resolve) => {
        listener({ type: "query", host: "example.com" }, { id: "extension-id", url: "https://site.example" }, resolve);
    });
    assert.deepEqual(denied, { type: "locked" });
});

for (const failure of ["missing", "throws"]) {
    test(`browser session without trusted access (${failure}) stores plaintext/key in memory only`, async () => {
        const f = fakeApi();
        if (failure === "missing") delete f.api.storage.session.setAccessLevel;
        else f.api.storage.session.setAccessLevel = async () => { throw new Error("unsupported"); };
        let accesses = 0;
        f.api.storage.session.get = async () => { accesses++; return {}; };
        f.api.storage.session.set = async () => { accesses++; };
        const session = createBrowserUnlockSession(f.api);
        const context = { token: "t", vaultId: "v" };
        const begun = await session.handle({ type: "vault-session", action: "begin", context });
        const committed = await session.handle({ type: "vault-session", action: "commit", context,
            generation: begun.generation, items: [], vaultKey: Array(32).fill(71) });
        assert.equal(committed.unlocked, true);
        assert.equal(committed.persistent, false);
        assert.equal(accesses, 0);
        assert.equal(JSON.stringify(f.local).includes("vaultKey"), false);
        assert.equal((await session.inspect()).unlocked, true);
    });
}

test("decrypt and refresh keep exact popup sender boundaries even for a valid generation", async () => {
    const f = fakeApi();
    const session = installSessionBackground(f.api);
    const context = { token: "t", vaultId: "v" };
    const begun = await session.handle({ type: "vault-session", action: "begin", context });
    await session.handle({ type: "vault-session", action: "commit", context,
        generation: begun.generation, items: [], vaultKey: Array(32).fill(71),
        snapshotVersion: 1, passwordVersion: 1 });
    const listener = f.listeners[0];
    for (const action of ["decrypt", "refresh"]) {
        for (const sender of [
            { id: "extension-id", url: "https://example.test", tab: { id: 1 } },
            { id: "other-id", url: "moz-extension://id/src/popup.html" },
            { id: "extension-id", url: "moz-extension://id/src/popup.html", tab: { id: 1 } },
            { id: "extension-id", url: "moz-extension://id/src/popup.html?extra" },
            { id: "extension-id", url: "moz-extension://id/src/options.html" },
        ]) {
            const response = await new Promise(resolve => {
                assert.equal(listener({ type: "vault-session", action, context,
                    generation: begun.generation, rows: [], items: [], expectedSnapshotVersion: 1,
                    snapshotVersion: 2, passwordVersion: 1 }, sender, resolve), false);
            });
            assert.equal(response.unlocked, false);
            for (const field of ["items", "fragments", "vaultKey", "generation"]) {
                assert.equal(field in response, false);
            }
        }
    }
    assert.equal((await session.inspect()).snapshotVersion, 1);
    const allowed = await new Promise(resolve => {
        assert.equal(listener({ type: "vault-session", action: "decrypt", context,
            generation: begun.generation, rows: [] }, {
            id: "extension-id", url: "moz-extension://id/src/popup.html",
        }, resolve), true);
    });
    assert.deepEqual(allowed.fragments, []);
});
