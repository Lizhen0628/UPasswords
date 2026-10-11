// 杂项:能力协商/安全响应头/管理统计(只读)/MIME 构造。

import { describe, expect, it } from "vitest";
import { buildMail } from "../src/smtp";
import { call, registerUser } from "./helpers";

describe("入口与响应头", () => {
  it("GET /v1/ 能力协商 + HSTS + no-store", async () => {
    const res = await call("GET", "/v1/");
    expect(res.status).toBe(200);
    expect(res.headers.get("strict-transport-security")).toContain("max-age=31536000");
    expect(res.headers.get("cache-control")).toBe("no-store");
    const data = (await res.json()) as { name: string; capabilities: string[] };
    expect(data.name).toBe("upasswords-sync");
    expect(data.capabilities).toContain("vaults.envelope");
  });

  it("未知路径 404;方法不符 405", async () => {
    expect((await call("GET", "/v1/nope")).status).toBe(404);
    expect((await call("PUT", "/v1/auth/code", {})).status).toBe(405);
  });
});

describe("管理统计(只读)", () => {
  it("无/错令牌 401;正确令牌返回计数", async () => {
    await registerUser("admin-test@example.com");
    expect((await call("GET", "/v1/admin/stats")).status).toBe(401);
    expect(
      (await call("GET", "/v1/admin/stats", undefined, undefined, { "x-admin-token": "wrong" }))
        .status,
    ).toBe(401);
    const res = await call(
      "GET",
      "/v1/admin/stats",
      undefined,
      undefined,
      { "x-admin-token": "test-admin-token" },
    );
    expect(res.status).toBe(200);
    const data = (await res.json()) as { users: { active: { normal: number } } };
    expect(data.users.active.normal).toBeGreaterThanOrEqual(1);
  });
});

describe("MIME 构造(buildMail)", () => {
  it("含必要头;主题 B 编码;正文 base64 折行 ≤76", () => {
    const mail = buildMail({
      from: "from@example.com",
      replyTo: "register@upasswords.com",
      to: "to@example.com",
      subject: "UPasswords 登录验证码",
      body: "您的验证码:123456\n10 分钟内有效。",
    });
    const lines = mail.split("\r\n");
    expect(lines[0]).toBe("From: from@example.com");
    expect(lines).toContain("Reply-To: register@upasswords.com");
    expect(lines).toContain("To: to@example.com");
    expect(lines.find((l) => l.startsWith("Subject:"))).toMatch(/^Subject: =\?UTF-8\?B\?.+\?=$/);
    expect(lines).toContain("Content-Transfer-Encoding: base64");
    const blankIdx = lines.indexOf("");
    for (let i = blankIdx + 1; i < lines.length; i++) {
      if (lines[i].length > 0) expect(lines[i].length).toBeLessThanOrEqual(76);
    }
    // 正文可解回
    const b64 = lines.slice(blankIdx + 1).filter((l) => l.length > 0).join("");
    expect(atob(b64)).toContain("123456");
  });
});
