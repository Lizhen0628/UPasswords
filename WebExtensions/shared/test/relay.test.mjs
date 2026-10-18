// relay API 客户端(/v2)测试:请求形态、快照分页、毫秒时间戳契约、
// 错误映射。fetch 全程 mock——这里验证的是客户端行为,不是服务端。

import { test } from "node:test";
import assert from "node:assert/strict";
import {
    listAllVaultItems,
    listVaultItems,
    RelayApiError,
    revokeOwnSession,
    verifyCode,
} from "../dist/index.js";

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

test("verifyCode: POST /v2/auth/verify 携带 platform;expiresAt 毫秒原样透传", async () => {
    const expiresAt = Date.now() + 86_400_000;
    const calls = mockFetch([
        { method: "POST", path: "/v2/auth/verify", body: { token: "t1", expiresAt, userId: "u1" } },
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
        { method: "GET", path: "/v2/vaults/v1/items", body: { items: [], nextCursor: null, headSeq: 0 } },
    ]);
    await listVaultItems("t", "v1");
    assert.equal(calls[0].search, "?limit=500");
});

test("listAllVaultItems: 跟随 nextCursor 翻页直到拉平", async () => {
    const calls = mockFetch([
        {
            method: "GET", path: "/v2/vaults/v1/items",
            body: {
                items: [
                    { uuid: "a", kind: 1, revision: 1, bodyB64: "AAA", modifiedMs: 1 },
                    { uuid: "b", kind: 2, revision: 1, bodyB64: "BBB", modifiedMs: 2 },
                ],
                nextCursor: { ms: 2, uuid: "b" }, headSeq: 9,
            },
        },
        {
            method: "GET", path: "/v2/vaults/v1/items",
            body: { items: [{ uuid: "c", kind: 1, revision: 3, bodyB64: "CCC", modifiedMs: 3 }], nextCursor: null, headSeq: 9 },
        },
    ]);
    const rows = await listAllVaultItems("t", "v1");
    assert.equal(rows.length, 3);
    assert.equal(rows[2].uuid, "c");
    // 第二页请求带上游返回的 cursor(uuid 须经 URL 编码通道)
    assert.equal(calls[1].search, "?cursorMs=2&cursorUuid=b&limit=500");
});

test("listAllVaultItems: 401 → RelayApiError(status=401)", async () => {
    mockFetch([{ method: "GET", path: "/v2/vaults/v1/items", status: 401, error: "unauthorized" }]);
    await assert.rejects(
        () => listAllVaultItems("t", "v1"),
        (error) => error instanceof RelayApiError && error.status === 401,
    );
});

test("revokeOwnSession: DELETE /v2/auth/session(鉴权即身份,无会话号)", async () => {
    const calls = mockFetch([{ method: "DELETE", path: "/v2/auth/session" }]);
    await revokeOwnSession("t");
    assert.equal(calls[0].init.headers.authorization, "Bearer t");
});
