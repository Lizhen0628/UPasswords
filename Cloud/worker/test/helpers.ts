// 测试辅助:SELF.fetch 封装、mock 验证码派生、注册/建库/伪造信封。
// SMTP mock 模式下验证码确定性派生,测试可自行复算(生产不生效)。

import { SELF, env } from "cloudflare:test";
import { expect } from "vitest";
import { deriveMockCode } from "../src/auth";
import type { Env } from "../src/util";

export const BASE = "https://api.upasswords.com";
export const workerEnv = env as unknown as Env;

export async function call(
  method: string,
  path: string,
  body?: unknown,
  token?: string,
  extraHeaders?: Record<string, string>,
): Promise<Response> {
  const headers: Record<string, string> = { ...extraHeaders };
  // 二进制请求体原样传递(库体分块);JSON 对象才序列化并标 content-type
  const isBinary = body instanceof Uint8Array;
  if (body !== undefined && !isBinary) headers["content-type"] = "application/json";
  if (token) headers.authorization = `Bearer ${token}`;
  return SELF.fetch(BASE + path, {
    method,
    headers,
    body: body !== undefined ? (isBinary ? (body as unknown as BodyInit) : JSON.stringify(body)) : undefined,
  });
}

export async function mockCode(email: string, purpose = "login"): Promise<string> {
  return deriveMockCode(workerEnv, email, purpose);
}

/// 注册(或登录)账户,返回会话令牌。
export async function registerUser(email: string, deviceName = "test-device"): Promise<string> {
  const codeReq = await call("POST", "/v1/auth/code", { email });
  expect(codeReq.status).toBe(202);
  const res = await call("POST", "/v1/auth/verify", {
    email,
    code: await mockCode(email),
    deviceName,
  });
  expect(res.status).toBe(200);
  return ((await res.json()) as { token: string }).token;
}

/// 直接后移历史码的创建时间,绕过重发冷却(绕 60s 冷却但仍在小时窗内)。
export async function ageCodes(seconds: number): Promise<void> {
  await env.DB.prepare("UPDATE email_codes SET created_at = created_at - ?")
    .bind(seconds)
    .run();
}

/// 伪造合法信封:UPWKEY1 魔数 + 确定性填充,≥100B。
export function fakeEnvelope(size = 120): string {
  const bytes = new Uint8Array(size);
  bytes.set([0x55, 0x50, 0x57, 0x4b, 0x45, 0x59, 0x31, 0x00], 0);
  for (let i = 8; i < bytes.length; i++) bytes[i] = i % 251;
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin);
}

export async function createVault(token: string, name: string): Promise<string> {
  const res = await call("POST", "/v1/vaults", { name }, token);
  expect(res.status).toBe(201);
  return ((await res.json()) as { vaultId: string }).vaultId;
}

export async function sensitiveCode(email: string): Promise<string> {
  const res = await call("POST", "/v1/auth/code", { email, purpose: "sensitive" });
  expect(res.status).toBe(202);
  return mockCode(email, "sensitive");
}
