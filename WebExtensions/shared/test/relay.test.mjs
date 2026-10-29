// relay API 客户端(/v1, sync protocol 5)测试:请求形态、快照分页、毫秒时间戳契约、
// 错误映射。fetch 全程 mock——这里验证的是客户端行为,不是服务端。

import { test } from "node:test";
import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
import {
    getVaultChanges,
    getVaultAttachment,
    deleteVaultAttachment,
    listAllVaultItems,
    listVaultConflicts,
    listVaultConflictHistory,
    listVaultItems,
    listVaultAttachmentVersions,
    RelayApiError,
    revokeOwnSession,
    resolveVaultConflict,
    verifyCode,
} from "../dist/index.js";

globalThis.crypto ??= webcrypto;

/** 按 (method, path) 分发且逐条消费(同一路径多页按声明顺序匹配)的 mock fetch。 */
function mockFetch(routes) {
    const calls = [];
    const pending = [...routes];
    globalThis.fetch = async (input, init) => {
        const url = new URL(String(input));
        const index = pending.findIndex((r) => r.method === init?.method && r.path === url.pathname);
        calls.push({ method: init?.method, path: url.pathname, search: url.search, init });
        if (index < 0) {
            return new Response(JSON.stringify({ error: "not_mocked" }), { status: 500 });
        }
        const [route] = pending.splice(index, 1);
        if (route.status && route.status >= 400) {
            return new Response(JSON.stringify({ error: route.error ?? "error" }), { status: route.status });
        }
        return new Response(JSON.stringify(route.body ?? { ok: true }));
    };
    return calls;
}

test("verifyCode: POST /v1/auth/verify 携带 platform;expiresAt 毫秒原样透传", async () => {
    const expiresAt = Date.now() + 86_400_000;
    const calls = mockFetch([
        { method: "POST", path: "/v1/auth/verify", body: { token: "t1", expiresAt, userId: "u1" } },
    ]);
    const session = await verifyCode("a@b.c", "123456", "Chrome 扩展", "ext-chrome");
    assert.equal(session.token, "t1");
    assert.equal(session.expiresAt, expiresAt);
    const body = JSON.parse(calls[0].init.body);
    assert.equal(body.email, "a@b.c");
    assert.equal(body.platform, "ext-chrome");
    assert.equal(body.deviceName, "Chrome 扩展");
});

test("listVaultItems: 首页无 cursor,limit=500", async () => {
    const calls = mockFetch([
        { method: "GET", path: "/v1/vaults/v1/items", body: { items: [], nextCursor: null, headSeq: 0 } },
    ]);
    await listVaultItems("t", "v1");
    assert.equal(calls[0].search, "?limit=500");
});

test("getVaultChanges: protocol 5 header and atomic resolution event", async () => {
    const source = "00000000-0000-4000-8000-000000000001";
    const resolved = "00000000-0000-4000-8000-000000000002";
    const calls = mockFetch([{
        method: "GET", path: "/v1/vaults/v1/changes", body: {
            headSeq: 8,
            changes: [{
                seq: 8, uuid: source, op: "resolve", revision: 4,
                conflictId: "a".repeat(32), baseRevision: 2,
                winnerCandidateId: "b".repeat(32), winnerKind: 1, winnerOp: "upsert",
                resolutionType: "candidate", resolvedItemUuid: resolved,
                resolvedRevision: 3, kind: 1, bodyB64: "AQ==",
                sha256: "c".repeat(64), modifiedMs: 42,
            }],
        },
    }]);
    const result = await getVaultChanges("token", "v1", 7);
    assert.equal(result.changes[0].op, "resolve");
    assert.equal(result.changes[0].resolvedItemUuid, resolved);
    assert.equal(calls[0].init.headers["X-UPW-Sync-Protocol"], "5");
});

test("getVaultChanges: malformed resolution event is rejected", async () => {
    mockFetch([{
        method: "GET", path: "/v1/vaults/v1/changes", body: {
            headSeq: 8,
            changes: [{
                seq: 8, uuid: "00000000-0000-4000-8000-000000000001", op: "resolve", revision: 4,
                conflictId: "not-an-id", baseRevision: 2,
                winnerCandidateId: "b".repeat(32), winnerKind: 1, winnerOp: "upsert",
                resolutionType: "candidate", resolvedItemUuid: "00000000-0000-4000-8000-000000000002",
                resolvedRevision: 3, kind: 1, bodyB64: "AQ==", sha256: "c".repeat(64), modifiedMs: 42,
            }],
        },
    }]);
    await assert.rejects(() => getVaultChanges("token", "v1", 7),
        (error) => error instanceof RelayApiError && error.code === "bad_changes_response");
});

test("conflict API validates encrypted candidates and submits the complete CAS set", async () => {
    const conflictId = "a".repeat(32);
    const candidateId = "b".repeat(32);
    const itemUuid = "00000000-0000-4000-8000-000000000001";
    const calls = mockFetch([
        {
            method: "GET", path: "/v1/vaults/v1/conflicts", body: {
                conflicts: [{
                    conflictId, itemUuid, baseRevision: 1, currentRevision: 2,
                    currentDeletedSeq: 0, generation: 3, createdMs: 4, updatedMs: 5,
                    candidates: [
                        { candidateId, kind: 1, op: "upsert", revision: 2, modifiedMs: 4,
                            committedMs: 5, deviceName: "one", platform: "web", bodyB64: "AQ==", sha256: "c".repeat(64) },
                        { candidateId: "d".repeat(32), kind: 1, op: "delete", revision: 2, modifiedMs: 4,
                            committedMs: 5, deviceName: "two", platform: "web" },
                    ],
                }],
            },
        },
        {
            method: "POST", path: `/v1/vaults/v1/conflicts/${conflictId}/resolve`,
            body: { status: "resolved", itemUuid, itemCount: 1, headSeq: 9 },
        },
    ]);
    const [conflict] = await listVaultConflicts("token", "v1");
    assert.equal(conflict.candidates[0].bodyB64, "AQ==");
    const resolved = await resolveVaultConflict("token", "v1", {
        conflictId, generation: 3, candidateIds: [candidateId, "d".repeat(32)],
        winnerCandidateId: candidateId, expectedCurrentRevision: 2, expectedDeletedSeq: 0,
        attachmentRefs: [{
            attachmentId: "00000000-0000-4000-8000-000000000010",
            contentVersion: "00000000-0000-4000-8000-000000000011",
            restoreDeleted: true,
        }],
    });
    assert.deepEqual(resolved, { status: "resolved", itemUuid, itemCount: 1, headSeq: 9 });
    assert.equal(calls[1].init.headers["X-UPW-Sync-Protocol"], "5");
    assert.deepEqual(JSON.parse(calls[1].init.body), {
        generation: 3,
        candidateIds: [candidateId, "d".repeat(32)],
        winnerCandidateId: candidateId,
        expectedCurrentRevision: 2,
        expectedDeletedSeq: 0,
        attachmentRefs: [{
            attachmentId: "00000000-0000-4000-8000-000000000010",
            contentVersion: "00000000-0000-4000-8000-000000000011",
            restoreDeleted: true,
        }],
    });
});

test("conflict history pages retained candidates with a fixed snapshot", async () => {
    const conflictId = "a".repeat(32);
    const itemUuid = "00000000-0000-4000-8000-000000000001";
    const firstID = "b".repeat(32);
    const secondID = "c".repeat(32);
    const metadata = {
        conflictId,
        itemUuid,
        baseRevision: 1,
        currentRevision: 2,
        currentDeletedSeq: 0,
        generation: 3,
        createdMs: 10,
        updatedMs: 20,
        resolvedMs: 30,
        expiresMs: 1000,
        selectedCandidateId: firstID,
    };
    const first = {
        ...metadata,
        candidate: {
            candidateId: firstID, kind: 1, op: "upsert", revision: 2,
            modifiedMs: 15, committedMs: 18, deviceName: "Mac", platform: "macos",
            bodyB64: "AQ==", sha256: "e".repeat(64),
        },
    };
    const second = {
        ...metadata,
        candidate: {
            candidateId: secondID, kind: 1, op: "delete", revision: 2,
            modifiedMs: 16, committedMs: 19, deviceName: "iPhone", platform: "ios",
        },
    };
    const calls = mockFetch([
        {
            method: "GET", path: "/v1/vaults/v1/conflict-history",
            body: { snapshotMs: 500, totalCandidates: 2, candidates: [first], nextCursor: "signed-cursor" },
        },
        {
            method: "GET", path: "/v1/vaults/v1/conflict-history",
            body: { snapshotMs: 500, totalCandidates: 2, candidates: [second], nextCursor: null },
        },
    ]);

    const history = await listVaultConflictHistory("token", "v1");

    assert.equal(history.length, 1);
    assert.deepEqual(history[0].candidates.map(candidate => candidate.candidateId), [firstID, secondID]);
    assert.equal(history[0].resolvedMs, 30);
    assert.equal(history[0].selectedCandidateId, firstID);
    assert.equal(new URLSearchParams(calls[0].search).get("limit"), "50");
    assert.equal(new URLSearchParams(calls[1].search).get("cursor"), "signed-cursor");
});

test("conflict history rejects a selected candidate outside the retained set", async () => {
    const conflictId = "a".repeat(32);
    const selectedCandidateId = "d".repeat(32);
    mockFetch([{
        method: "GET", path: "/v1/vaults/v1/conflict-history",
        body: {
            snapshotMs: 500,
            totalCandidates: 1,
            candidates: [{
                conflictId,
                itemUuid: "00000000-0000-4000-8000-000000000001",
                baseRevision: 1,
                currentRevision: 2,
                currentDeletedSeq: 0,
                generation: 3,
                createdMs: 10,
                updatedMs: 20,
                resolvedMs: 30,
                expiresMs: 1000,
                selectedCandidateId,
                candidate: {
                    candidateId: "b".repeat(32),
                    kind: 1,
                    op: "delete",
                    revision: 2,
                    modifiedMs: 15,
                    committedMs: 18,
                    deviceName: "Mac",
                    platform: "macos",
                },
            }],
            nextCursor: null,
        },
    }]);

    await assert.rejects(() => listVaultConflictHistory("token", "v1"),
        error => error instanceof RelayApiError && error.code === "bad_conflict_history_response");
});

test("conflict history rejects a missing candidate from the fixed snapshot", async () => {
    mockFetch([{
        method: "GET", path: "/v1/vaults/v1/conflict-history",
        body: { snapshotMs: 500, totalCandidates: 1, candidates: [], nextCursor: null },
    }]);

    await assert.rejects(() => listVaultConflictHistory("token", "v1"),
        error => error instanceof RelayApiError && error.code === "bad_conflict_history_response");
});

test("resolveVaultConflict: restore and composed payloads cannot be mixed", async () => {
    await assert.rejects(() => resolveVaultConflict("token", "v1", {
        conflictId: "a".repeat(32), generation: 1,
        candidateIds: ["b".repeat(32), "c".repeat(32)], winnerCandidateId: "b".repeat(32),
        expectedCurrentRevision: 1, expectedDeletedSeq: 0,
        attachmentRefs: [],
        restoreItemUuid: "00000000-0000-4000-8000-000000000002", bodyB64: "AQ==",
        mergedBodyB64: "Ag==", mergedModifiedMs: 2,
    }), (error) => error instanceof RelayApiError && error.code === "bad_conflict_request");
});

test("listAllVaultItems: 跟随 nextCursor 翻页直到拉平", async () => {
    const uuids = [1, 2, 3].map(index => `00000000-0000-4000-8000-${String(index).padStart(12, "0")}`);
    const calls = mockFetch([
        {
            method: "GET", path: "/v1/vaults/v1/items",
            body: {
                items: [
                    { uuid: uuids[0], kind: 1, revision: 1, bodyB64: "AAAA", modifiedMs: 1 },
                    { uuid: uuids[1], kind: 2, revision: 1, bodyB64: "BBBB", modifiedMs: 2 },
                ],
                nextCursor: { ms: 2, uuid: uuids[1] }, headSeq: 9,
            },
        },
        {
            method: "GET", path: "/v1/vaults/v1/items",
            body: { items: [{ uuid: uuids[2], kind: 1, revision: 3, bodyB64: "CCCC", modifiedMs: 3 }], nextCursor: null, headSeq: 9 },
        },
    ]);
    const rows = await listAllVaultItems("t", "v1");
    assert.equal(rows.length, 3);
    assert.equal(rows[2].uuid, uuids[2]);
    // 第二页请求带上游返回的 cursor(uuid 须经 URL 编码通道)
    assert.equal(calls[1].search, `?cursorMs=2&cursorUuid=${uuids[1]}&limit=500`);
});

test("attachment version listing follows pages and validates stable identities", async () => {
    const attachmentId = "00000000-0000-4000-8000-000000000011";
    const cardUuid = "00000000-0000-4000-8000-000000000012";
    const contentVersion = "00000000-0000-4000-8000-000000000013";
    const base = { attachmentId, cardUuid, createdMs: 1, contentVersion, dekWrapped: Buffer.alloc(32).toString("base64"),
        sha256: "a".repeat(64), bytes: 32, isCurrent: true };
    const calls = mockFetch([
        { method: "GET", path: "/v1/vaults/v1/attachment-versions", body: {
            versions: [base], nextOffset: 1, hasMore: true,
        } },
        { method: "GET", path: "/v1/vaults/v1/attachment-versions", body: {
            versions: [{ ...base, contentVersion: "00000000-0000-4000-8000-000000000014", isCurrent: false }],
            nextOffset: 2, hasMore: false,
        } },
    ]);
    const versions = await listVaultAttachmentVersions("t", "v1", cardUuid);
    assert.equal(versions.length, 2);
    assert.equal(versions[0].attachmentId, attachmentId);
    assert.match(calls[0].search, /cardUuid=/);
    assert.match(calls[1].search, /offset=1/);
});

test("attachment version listing rejects inconsistent pagination and malformed wrappers", async () => {
    mockFetch([{ method: "GET", path: "/v1/vaults/v1/attachment-versions", body: {
        versions: [{ attachmentId: "bad" }], nextOffset: 1, hasMore: false,
    } }]);
    await assert.rejects(() => listVaultAttachmentVersions("t", "v1"),
        (error) => error instanceof RelayApiError && error.code === "bad_attachment_versions_response");
});

test("attachment version listing rejects duplicate identities and multiple current versions", async () => {
    const base = {
        attachmentId: "00000000-0000-4000-8000-000000000011",
        cardUuid: "00000000-0000-4000-8000-000000000012",
        createdMs: 1,
        contentVersion: "00000000-0000-4000-8000-000000000013",
        dekWrapped: Buffer.alloc(32).toString("base64"), sha256: "a".repeat(64), bytes: 32,
        isCurrent: true,
    };
    mockFetch([{ method: "GET", path: "/v1/vaults/v1/attachment-versions", body: {
        versions: [base, { ...base, contentVersion: "00000000-0000-4000-8000-000000000014" }],
        nextOffset: 2, hasMore: false,
    } }]);
    await assert.rejects(() => listVaultAttachmentVersions("t", "v1"),
        error => error instanceof RelayApiError && error.code === "bad_attachment_versions_response");

    mockFetch([{ method: "GET", path: "/v1/vaults/v1/attachment-versions", body: {
        versions: [base, { ...base, contentVersion: "00000000-0000-4000-8000-000000000014", isCurrent: true }],
        nextOffset: 2, hasMore: false,
    } }]);
    await assert.rejects(() => listVaultAttachmentVersions("t", "v1"),
        error => error instanceof RelayApiError && error.code === "bad_attachment_versions_response");
});

test("attachment download checks exact encrypted byte count and SHA-256", async () => {
    const cipher = Uint8Array.from([1, 2, 3, 4]);
    const sha256 = await crypto.subtle.digest("SHA-256", cipher);
    const digest = [...new Uint8Array(sha256)].map(byte => byte.toString(16).padStart(2, "0")).join("");
    const version = {
        attachmentId: "00000000-0000-4000-8000-000000000011",
        cardUuid: "00000000-0000-4000-8000-000000000012",
        contentVersion: "00000000-0000-4000-8000-000000000013",
        dekWrapped: "AQ==", sha256: digest, bytes: cipher.length, isCurrent: true,
    };
    globalThis.fetch = async (input, init) => {
        const url = new URL(String(input));
        assert.equal(url.pathname, `/v1/vaults/v1/attachments/${version.attachmentId}`);
        assert.equal(url.searchParams.get("version"), version.contentVersion);
        assert.equal(init.headers.authorization, "Bearer t");
        return new Response(cipher);
    };
    assert.deepEqual([...await getVaultAttachment("t", "v1", version)], [...cipher]);
    await assert.rejects(() => getVaultAttachment("t", "v1", { ...version, bytes: 5 }),
        (error) => error instanceof RelayApiError && error.code === "attachment_integrity_failure");
});

test("attachment download cancels a response as soon as it exceeds the authenticated length", async () => {
    globalThis.fetch = async () => new Response(Uint8Array.from([1, 2, 3, 4]));
    await assert.rejects(() => getVaultAttachment("t", "v1", {
        attachmentId: "00000000-0000-4000-8000-000000000011",
        cardUuid: "00000000-0000-4000-8000-000000000012",
        contentVersion: "00000000-0000-4000-8000-000000000013",
        dekWrapped: Buffer.alloc(32).toString("base64"),
        sha256: "a".repeat(64), bytes: 3, isCurrent: true,
    }), error => error instanceof RelayApiError && error.code === "attachment_integrity_failure");
});

test("deleteVaultAttachment removes a newly staged attachment with protocol 5", async () => {
    const attachmentID = "00000000-0000-4000-8000-000000000011";
    const calls = mockFetch([{
        method: "DELETE",
        path: `/v1/vaults/v1/attachments/${attachmentID}`,
    }]);
    await deleteVaultAttachment("token", "v1", attachmentID);
    assert.equal(calls[0].init.headers.authorization, "Bearer token");
    assert.equal(calls[0].init.headers["X-UPW-Sync-Protocol"], "5");
    assert.equal(calls[0].init.body, undefined);
});

test("listAllVaultItems: 401 → RelayApiError(status=401)", async () => {
    mockFetch([{ method: "GET", path: "/v1/vaults/v1/items", status: 401, error: "unauthorized" }]);
    await assert.rejects(
        () => listAllVaultItems("t", "v1"),
        (error) => error instanceof RelayApiError && error.status === 401,
    );
});

test("revokeOwnSession: DELETE /v1/auth/session(鉴权即身份,无会话号)", async () => {
    const calls = mockFetch([{ method: "DELETE", path: "/v1/auth/session" }]);
    await revokeOwnSession("t");
    assert.equal(calls[0].init.headers.authorization, "Bearer t");
});
