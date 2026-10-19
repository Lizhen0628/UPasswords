import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { IDBFactory } from "fake-indexeddb";
import { JSDOM } from "jsdom";
import {
    createEncryptedCache, createUnlockSession, encryptItemBody, projectVaultFragment,
    synchronizeVault, bytesToBase64,
} from "../dist/index.js";

const { window } = new JSDOM("");
globalThis.DOMParser = window.DOMParser;
const fixture = JSON.parse(readFileSync(new URL("fixtures/item-vector.json", import.meta.url), "utf8"));

test("real encrypted delta passes cache, trusted session decrypt and XML projection without persisting plaintext", async () => {
    const scope = { userId: "synthetic-user", vaultId: "synthetic-vault" };
    const context = { ...scope, token: "synthetic-token" };
    const cache = createEncryptedCache(new IDBFactory());
    const local = { "relay.session": { token: context.token, userId: scope.userId, expiresAt: 1 },
        "relay.vault": { id: scope.vaultId } };
    const area = {
        async get(keys) { return structuredClone(Object.fromEntries(keys.map(key => [key, local[key]]))); },
        async set(values) { Object.assign(local, structuredClone(values)); },
    };
    const session = createUnlockSession({ local: area, session: null });
    const command = (action, extra = {}) => session.handle({ type: "vault-session", action, context, ...extra });
    const original = { uuid: fixture.uuid, bodyB64: fixture.body, revision: 1, kind: 1, modifiedMs: 1 };
    const snapshot = await cache.commit({ scope, envelope: "synthetic-wrapped-envelope", passwordVersion: 1,
        cursor: 10, accountEpoch: await cache.getEpoch(scope), rows: [original] }, null);
    const ticket = await command("begin");
    const key = Uint8Array.from(Buffer.from(fixture.vek, "base64"));
    const initial = projectVaultFragment({ ...original, xml: fixture.fragment });
    await command("commit", { generation: ticket.generation, items: [initial], vaultKey: [...key],
        passwordVersion: 1, snapshotVersion: snapshot.version });
    const xml = fixture.fragment.replace('title="GitHub"', 'title="Updated synthetic item"');
    const updated = { ...original, revision: 2, modifiedMs: 2,
        bodyB64: bytesToBase64(await encryptItemBody(xml, key, fixture.uuid)) };
    key.fill(0);
    const requests = [];
    const previousFetch = globalThis.fetch;
    globalThis.fetch = async input => {
        const url = new URL(input);
        requests.push(url.pathname);
        let value;
        if (url.pathname.endsWith("/seq")) value = { headSeq: 12, passwordVersion: 1 };
        else if (url.pathname.endsWith("/changes")) value = { headSeq: 12,
            changes: [{ ...updated, op: "upsert", seq: 12 }] };
        else value = { vaultId: scope.vaultId, name: "Synthetic", passwordVersion: 1,
            hasEnvelope: true, headSeq: 12, itemCount: 1, envelope: snapshot.envelope };
        return new Response(JSON.stringify(value));
    };
    try {
        let projected;
        const result = await synchronizeVault({ token: context.token, scope, cache, keyVersion: 1,
            validate: async () => {},
            verifyRows: async rows => {
                const response = await command("decrypt", { generation: ticket.generation, rows });
                assert.equal(response.unlocked, true, response.code);
                projected = response.fragments.map(projectVaultFragment).filter(Boolean);
            },
        });
        assert.equal(result.rebuilt, false);
        assert.equal(result.snapshot.cursor, 12);
        assert.equal(projected[0].title, "Updated synthetic item");
        assert.equal(projected[0].source.revision, 2);
        assert.equal(requests.some(path => path.endsWith("/items")), false);
        const refreshed = await command("refresh", { generation: ticket.generation, expectedSnapshotVersion: 1,
            snapshotVersion: result.snapshot.version, passwordVersion: 1, items: projected });
        assert.equal(refreshed.unlocked, true);
        const persisted = JSON.stringify(await cache.read(scope));
        assert.equal(persisted.includes("Updated synthetic item"), false);
        assert.equal(persisted.includes("<card"), false);
        assert.equal(persisted.includes(fixture.vek), false);
        await command("lock");
        assert.equal((await command("read")).unlocked, false);
        assert.equal((await cache.read(scope)).rows[0].revision, 2);
    } finally {
        globalThis.fetch = previousFetch;
        cache.close();
    }
});
