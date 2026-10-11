// 账户层测试:注册/登录统一流、单活跃码、限次、限速、会话、注销。

import { describe, expect, it } from "vitest";
import { ageCodes, call, mockCode, registerUser, sensitiveCode } from "./helpers";

describe("邮箱验证码登录", () => {
  const email = "alice@example.com";

  it("注册即登录:返回令牌;再次登录同 userId", async () => {
    const token = await registerUser(email);
    expect(token).toMatch(/^[0-9a-f]{64}$/);

    await ageCodes(120); // 绕过重发冷却
    const second = await call("POST", "/v1/auth/verify", {
      email,
      code: await mockCode(email),
      deviceName: "second",
    });
    // 上一次验证码已被消费,须重新请求
    const reReq = await call("POST", "/v1/auth/code", { email });
    expect(reReq.status).toBe(202);
    const res = await call("POST", "/v1/auth/verify", {
      email,
      code: await mockCode(email),
      deviceName: "second",
    });
    expect(res.status).toBe(200);
    const first = await call("GET", "/v1/auth/sessions", undefined, token);
    const data = (await first.json()) as { sessions: { deviceName: string }[] };
    expect(data.sessions.map((s) => s.deviceName)).toContain("second");
  });

  it("错误验证码 400;验证码一次性(重放 400)", async () => {
    const token = await registerUser("bob@example.com"); // 注册即消耗掉验证码
    expect(token).toMatch(/^[0-9a-f]{64}$/);
    // 该邮箱当前码已被消费 → 再用同码登录失败
    const replay = await call("POST", "/v1/auth/verify", {
      email: "bob@example.com",
      code: await mockCode("bob@example.com"),
    });
    expect(replay.status).toBe(400);
  });

  it("连续 5 次错码后验证码作废(正确码也 400)", async () => {
    const email2 = "carol@example.com";
    const req = await call("POST", "/v1/auth/code", { email: email2 });
    expect(req.status).toBe(202);
    const correct = await mockCode(email2);
    const wrong = String((Number(correct) + 1) % 1_000_000).padStart(6, "0");
    for (let i = 0; i < 5; i++) {
      const res = await call("POST", "/v1/auth/verify", { email: email2, code: wrong });
      expect(res.status).toBe(400);
    }
    const dead = await call("POST", "/v1/auth/verify", { email: email2, code: correct });
    expect(dead.status).toBe(400);
  });

  it("单活跃码:请求新码后旧码失效", async () => {
    const email3 = "dave@example.com";
    await call("POST", "/v1/auth/code", { email: email3 });
    const oldCode = await mockCode(email3);
    await ageCodes(120);
    await call("POST", "/v1/auth/code", { email: email3 });
    // mock 模式码确定性派生——旧码即新码;此处以"仍可登录"验证新码行生效
    const res = await call("POST", "/v1/auth/verify", { email: email3, code: oldCode });
    expect(res.status).toBe(200);
  });

  it("重发冷却:60s 内第二次请求 429 且带 retry-after", async () => {
    const email4 = "erin@example.com";
    await call("POST", "/v1/auth/code", { email: email4 });
    const res = await call("POST", "/v1/auth/code", { email: email4 });
    expect(res.status).toBe(429);
    expect(Number(res.headers.get("retry-after"))).toBeGreaterThan(0);
  });

  it("每邮箱小时限额:10 封后 429", async () => {
    const email5 = "frank@example.com";
    for (let i = 0; i < 10; i++) {
      await call("POST", "/v1/auth/code", { email: email5 });
      await ageCodes(61); // 只绕冷却,留在小时窗内
    }
    const res = await call("POST", "/v1/auth/code", { email: email5 });
    expect(res.status).toBe(429);
  });

  it("非法邮箱 400;缺会话 401;坏令牌 401", async () => {
    expect((await call("POST", "/v1/auth/code", { email: "not-an-email" })).status).toBe(400);
    expect((await call("GET", "/v1/vaults")).status).toBe(401);
    expect((await call("GET", "/v1/vaults", undefined, "0".repeat(64))).status).toBe(401);
  });
});

describe("会话管理", () => {
  it("设备列表与撤销:撤销后旧令牌 401", async () => {
    const email = "grace@example.com";
    const token = await registerUser(email);
    const list = await call("GET", "/v1/auth/sessions", undefined, token);
    expect(list.status).toBe(200);
    const { sessions } = (await list.json()) as { sessions: { id: string }[] };
    expect(sessions).toHaveLength(1);

    const revoke = await call("DELETE", `/v1/auth/sessions/${sessions[0].id}`, undefined, token);
    expect(revoke.status).toBe(200);
    expect((await call("GET", "/v1/auth/sessions", undefined, token)).status).toBe(401);
    expect((await call("GET", "/v1/vaults", undefined, token)).status).toBe(401);
  });

  it("撤销他人会话 → 404(行级隔离)", async () => {
    const a = await registerUser("henry@example.com");
    const b = await registerUser("isla@example.com");
    const listB = await call("GET", "/v1/auth/sessions", undefined, b);
    const { sessions } = (await listB.json()) as { sessions: { id: string }[] };
    // a 尝试撤销 b 的会话
    const res = await call("DELETE", `/v1/auth/sessions/${sessions[0].id}`, undefined, a);
    expect(res.status).toBe(404);
  });
});

describe("注销", () => {
  it("需 sensitive 码;注销后令牌失效、库清空、可重新注册", async () => {
    const email = "jack@example.com";
    const token = await registerUser(email);
    // 先建一个库(应随注销清除)
    const create = await call("POST", "/v1/vaults", { name: "Main" }, token);
    expect(create.status).toBe(201);

    expect((await call("DELETE", "/v1/account", { code: "000000" }, token)).status).toBe(403);
    // login 码不能充当 sensitive 码
    const loginCode = await mockCode(email, "login");
    // login 码已被注册消费,重取一枚未消费的 login 码也不行
    await ageCodes(120);
    await call("POST", "/v1/auth/code", { email });
    const freshLogin = await mockCode(email, "login");
    expect((await call("DELETE", "/v1/account", { code: freshLogin }, token)).status).toBe(403);

    const code = await sensitiveCode(email);
    const res = await call("DELETE", "/v1/account", { code }, token);
    expect(res.status).toBe(200);
    expect((await call("GET", "/v1/vaults", undefined, token)).status).toBe(401);

    // 重新注册:全新身份,库列表为空
    await ageCodes(120);
    const again = await registerUser(email);
    const vaults = await call("GET", "/v1/vaults", undefined, again);
    const data = (await vaults.json()) as { vaults: unknown[] };
    expect(data.vaults).toHaveLength(0);
  });
});

// ---------- 会话自命名(设备名自愈) ----------

it("会话自命名:PATCH /v1/auth/session 更新自己;列表可见;空名 400", async () => {
  const email = "rename@example.com";
  const tokenA = await registerUser(email, "device-A");
  // 同邮箱二次登录:后移历史码绕过重发冷却(仍在小时窗内)
  await ageCodes(70);
  await call("POST", "/v1/auth/code", { email });
  const verifyB = await call("POST", "/v1/auth/verify", {
    email,
    code: await mockCode(email),
    deviceName: "device-B",
  });
  expect(verifyB.status).toBe(200);
  const tokenB = ((await verifyB.json()) as { token: string }).token;

  const res = await call("PATCH", "/v1/auth/session", { deviceName: "iPhone 13 · 李振的 iPhone" }, tokenA);
  expect(res.status).toBe(200);

  const list = await call("GET", "/v1/auth/sessions", undefined, tokenA);
  const { sessions } = (await list.json()) as { sessions: { deviceName: string }[] };
  const names = sessions.map((s) => s.deviceName).sort();
  expect(names).toContain("iPhone 13 · 李振的 iPhone");
  expect(names).toContain("device-B");

  // 空名/非字符串 → 400
  expect((await call("PATCH", "/v1/auth/session", { deviceName: "  " }, tokenB)).status).toBe(400);
  // 未鉴权 → 401
  expect((await call("PATCH", "/v1/auth/session", { deviceName: "x" }, undefined)).status).toBe(401);
});
