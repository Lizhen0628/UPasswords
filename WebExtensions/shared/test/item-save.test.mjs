import { test } from "node:test";
import assert from "node:assert/strict";
import { saveVaultItem, RelayApiError } from "../dist/index.js";

const uuid = "abcdefab-1234-4abc-8def-0123456789ab";
const attachmentId = "11111111-2222-4333-8444-555555555555";
const contentVersion = "11111111-2222-4333-8444-555555555556";
const item = {
    uuid: uuid.toUpperCase(), revision: 7, bodyB64: "encrypted-test-body", modifiedMs: 1_800_000_000_123,
    attachmentRefs: [{ attachmentId: attachmentId.toUpperCase(), contentVersion: contentVersion.toUpperCase() }],
};

function mock(t, body, status = 200) {
    const calls = [];
    t.mock.method(globalThis, "fetch", async (url, init) => {
        calls.push({ url: String(url), init });
        return new Response(JSON.stringify(body), { status });
    });
    return calls;
}

const isError = (status, code) => (error) => error instanceof RelayApiError && error.status === status && error.code === code;

test("saveVaultItem: exact single-card CAS POST and returned revision", async (t) => {
    const calls = mock(t, { results: [{ uuid, status: "ok", revision: 8 }] });
    assert.deepEqual(await saveVaultItem("token", "vault1", item), { revision: 8 });
    assert.equal(calls.length, 1);
    assert.equal(calls[0].url, "https://api.upasswords.com/v1/vaults/vault1/items");
    assert.equal(calls[0].init.method, "POST");
    assert.equal(calls[0].init.headers.authorization, "Bearer token");
    assert.equal(calls[0].init.headers["X-UPW-Sync-Protocol"], "5");
    assert.equal(calls[0].init.headers["content-type"], "application/json");
    assert.deepEqual(JSON.parse(calls[0].init.body), { items: [{
        uuid: item.uuid, kind: 1, op: "upsert", baseRevision: 7, bodyB64: item.bodyB64, modifiedMs: item.modifiedMs,
        attachmentRefs: [{ attachmentId, contentVersion }],
    }] });
});

for (const [status, httpStatus, code] of [["conflict", 409, "item_conflict"], ["not_found", 404, "item_deleted"]]) {
    test(`saveVaultItem: HTTP200 ${status} fails without retry or resurrection`, async (t) => {
        const calls = mock(t, { results: [{ uuid, status, current: { revision: 99, bodyB64: "newer" } }] });
        await assert.rejects(() => saveVaultItem("token", "vault1", item), isError(httpStatus, code));
        assert.equal(calls.length, 1);
        assert.equal(JSON.parse(calls[0].init.body).items[0].baseRevision, 7);
    });
}

test("saveVaultItem: HTTP409 rekey_in_progress passes through unchanged without retry", async (t) => {
    const calls = mock(t, { error: "rekey_in_progress" }, 409);
    await assert.rejects(() => saveVaultItem("token", "vault1", item), isError(409, "rekey_in_progress"));
    assert.equal(calls.length, 1);
});

test("saveVaultItem: malformed/mismatched results never report a successful save", async (t) => {
    for (const body of [
        null, {}, { results: [] }, { results: null }, { results: [null] },
        { results: [{ uuid, status: "ok" }] }, { results: [{ uuid, status: "ok", revision: "8" }] },
        { results: [{ uuid, status: "ok", revision: -1 }] }, { results: [{ uuid, status: "ok", revision: 7 }] },
        { results: [{ uuid, status: "ok", revision: 9 }] }, { results: [{ uuid, status: "other", revision: 8 }] },
        { results: [{ uuid: "other", status: "ok", revision: 8 }] },
        { results: [{ status: "conflict" }] },
        { results: [{ uuid, status: "ok", revision: 8 }, { uuid, status: "ok", revision: 8 }] },
    ]) {
        const calls = mock(t, body);
        await assert.rejects(() => saveVaultItem("token", "vault1", item), isError(0, "bad_item_response"));
        assert.equal(calls.length, 1);
        t.mock.restoreAll();
    }
});

test("saveVaultItem: refuses absent/zero CAS revision before sending a create", async (t) => {
    const calls = mock(t, { results: [{ uuid, status: "ok", revision: 1 }] });
    for (const revision of [undefined, 0, -1, 1.5, NaN, Number.MAX_SAFE_INTEGER + 1]) {
        await assert.rejects(() => saveVaultItem("token", "vault1", { ...item, revision }), isError(0, "bad_item_revision"));
    }
    assert.equal(calls.length, 0);
});

test("saveVaultItem: requires unique, versioned attachment references before sending", async (t) => {
    const calls = mock(t, { results: [{ uuid, status: "ok", revision: 8 }] });
    for (const attachmentRefs of [undefined, [
        { attachmentId, contentVersion }, { attachmentId: attachmentId.toUpperCase(), contentVersion },
    ], [{ attachmentId, contentVersion: "00000000-0000-0000-0000-000000000000" }]]) {
        await assert.rejects(() => saveVaultItem("token", "vault1", { ...item, attachmentRefs }),
            isError(0, "bad_attachment_reference"));
    }
    assert.equal(calls.length, 0);
});
