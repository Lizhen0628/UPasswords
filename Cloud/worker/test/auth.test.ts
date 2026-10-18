// 账户层集成测试:注册/登录统一流、单活跃码、限次、限速、会话、注销、隔离。

import { describe, expect, it } from "vitest";
import { ageCodes, b64, call, mockCode, registerUser, sensitiveCode, workerEnv } from "./helpers";

describe("account", () => {
  it("registers on first verify and issues session with platform", async () => {
    const env = workerEnv();
    const email = "new-user@example.com";
    await call(env, "POST", "/v2/auth/code", { body: { email } });
    const code = await mockCode(env, email);
    const res = await call(env, "POST", "/v2/auth/verify", {
      body: { email, code, deviceName: "MacBook Pro", platform: "macos" },
    });
    expect(res.status).toBe(200);
    const data = (await res.json()) as { token: string; userId: string; expiresAt: number };
    expect(data.token).toMatch(/^[0-9a-f]{64}$/);

    const list = await call(env, "GET", "/v2/auth/sessions", { token: data.token });
    expect(list.status).toBe(200);
    const sessions = (await list.json()) as { sessions: { platform: string; deviceName: string }[] };
    expect(sessions.sessions).toHaveLength(1);
    expect(sessions.sessions[0].platform).toBe("macos");
    expect(sessions.sessions[0].deviceName).toBe("MacBook Pro");
  });

  it("rejects wrong code and burns attempts (5 max)", async () => {
    const env = workerEnv();
    const email = "burn@example.com";
    await call(env, "POST", "/v2/auth/code", { body: { email } });
    for (let i = 0; i < 5; i++) {
      const bad = await call(env, "POST", "/v2/auth/verify", {
        body: { email, code: "000000" },
      });
      expect(bad.status).toBe(400);
    }
    // 正确码也救不回:尝试配额已耗尽,码作废
    const good = await call(env, "POST", "/v2/auth/verify", {
      body: { email, code: await mockCode(env, email) },
    });
    expect(good.status).toBe(400);
  });

  it("code is single-use: second verify with the same code fails", async () => {
    const env = workerEnv();
    const email = "single@example.com";
    await call(env, "POST", "/v2/auth/code", { body: { email } });
    const code = await mockCode(env, email);
    const first = await call(env, "POST", "/v2/auth/verify", { body: { email, code } });
    expect(first.status).toBe(200);
    // 单活跃码在 (email, purpose) 主键上只有一行,消费后 used_ms 置位
    const again = await call(env, "POST", "/v2/auth/verify", { body: { email, code } });
    expect(again.status).toBe(400);
  });

  it("rate-limits resend within cooldown", async () => {
    const env = workerEnv();
    const email = "cooldown@example.com";
    const first = await call(env, "POST", "/v2/auth/code", { body: { email } });
    expect(first.status).toBe(202);
    const second = await call(env, "POST", "/v2/auth/code", { body: { email } });
    expect(second.status).toBe(429);
  });

  it("renames own session and revokes sessions; revoked token is 401", async () => {
    const env = workerEnv();
    const { token, userId } = await registerUser(env, "session@example.com");
    const rename = await call(env, "PATCH", "/v2/auth/session", {
      token,
      body: { deviceName: "iPhone 17" },
    });
    expect(rename.status).toBe(200);

    const list = await call(env, "GET", "/v2/auth/sessions", { token });
    const { sessions } = (await list.json()) as { sessions: { id: string }[] };
    expect(sessions).toHaveLength(1);
    const revoke = await call(env, "DELETE", `/v2/auth/sessions/${sessions[0].id}`, { token });
    expect(revoke.status).toBe(200);
    const after = await call(env, "GET", "/v2/auth/sessions", { token });
    expect(after.status).toBe(401);
    expect(userId).toMatch(/^[0-9a-f]{32}$/);
  });

  it("marks current session and self-revokes via DELETE /v2/auth/session", async () => {
    const env = workerEnv();
    const email = "selfrevoke@example.com";
    // 同一账户两台设备各一条会话(模拟重登残留);ageCodes 跳过重发冷却
    const first = await registerUser(env, email);
    await ageCodes();
    await call(env, "POST", "/v2/auth/code", { body: { email } });
    const second = await call(env, "POST", "/v2/auth/verify", {
      body: { email, code: await mockCode(env, email), deviceName: "iPhone 17", platform: "ios" },
    });
    const secondToken = ((await second.json()) as { token: string }).token;

    const list = await call(env, "GET", "/v2/auth/sessions", { token: secondToken });
    const { sessions } = (await list.json()) as { sessions: { current: boolean }[] };
    expect(sessions).toHaveLength(2);
    // 发起请求的会话标 current,另一条不标——重名设备也能识别本机
    expect(sessions.filter((s) => s.current)).toHaveLength(1);

    // 自撤销第二条:旧令牌即刻 401,第一条仍可用
    const self = await call(env, "DELETE", "/v2/auth/session", { token: secondToken });
    expect(self.status).toBe(200);
    expect((await call(env, "GET", "/v2/auth/sessions", { token: secondToken })).status).toBe(401);
    const remaining = await call(env, "GET", "/v2/auth/sessions", { token: first.token });
    expect(((await remaining.json()) as { sessions: unknown[] }).sessions).toHaveLength(1);
  });

  it("deregister wipes vaults and revokes sessions (sensitive code)", async () => {
    const env = workerEnv();
    const email = "bye@example.com";
    const { token } = await registerUser(env, email);
    // 建库 + 写一条目,验证注销后行级清除
    const create = await call(env, "POST", "/v2/vaults", { token, body: { name: "Main" } });
    const { vaultId } = (await create.json()) as { vaultId: string };
    const uuid = crypto.randomUUID();
    const put = await call(env, "POST", `/v2/vaults/${vaultId}/items`, {
      token,
      body: { items: [{ uuid, kind: 1, op: "upsert", baseRevision: 0, bodyB64: b64("x"), modifiedMs: 1 }] },
    });
    expect(put.status).toBe(200);

    const noCode = await call(env, "DELETE", "/v2/account", { token, body: { code: "123456" } });
    expect(noCode.status).toBe(403);
    const code = await sensitiveCode(env, email);
    const dereg = await call(env, "DELETE", "/v2/account", { token, body: { code } });
    expect(dereg.status).toBe(200);
    const after = await call(env, "GET", "/v2/vaults", { token });
    expect(after.status).toBe(401);

    // 重新登录(注销重注册 = 全新身份);先拨表绕过重发冷却
    await ageCodes();
    const reToken = (await registerUser(env, email)).token;
    const vaults = await call(env, "GET", "/v2/vaults", { token: reToken });
    const body = (await vaults.json()) as { vaults: unknown[] };
    expect(body.vaults).toHaveLength(0);
    const gone = await call(env, "GET", `/v2/vaults/${vaultId}`, { token: reToken });
    expect(gone.status).toBe(404);
  });

  it("isolates vaults across users (404, not 403)", async () => {
    const env = workerEnv();
    const a = await registerUser(env, "a@example.com");
    const b = await registerUser(env, "b@example.com");
    const create = await call(env, "POST", "/v2/vaults", { token: a.token, body: { name: "Main" } });
    const { vaultId } = (await create.json()) as { vaultId: string };
    const bRead = await call(env, "GET", `/v2/vaults/${vaultId}`, { token: b.token });
    expect(bRead.status).toBe(404);
    const bWrite = await call(env, "POST", `/v2/vaults/${vaultId}/items`, {
      token: b.token,
      body: { items: [{ uuid: crypto.randomUUID(), kind: 1, op: "upsert", baseRevision: 0, bodyB64: b64("y"), modifiedMs: 1 }] },
    });
    expect(bWrite.status).toBe(404);
  });
});
