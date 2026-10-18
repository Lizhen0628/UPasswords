// 测试辅助:worker 直调封装、内存 R2 mock、环境构造、mock 验证码派生、
// 注册/建库/伪造信封。SMTP mock 模式下验证码确定性派生,测试可自行复算。

import { bytesToB64, type Env } from "../src/util";
import { deriveMockCode } from "../src/auth";
import worker from "../src/index";

// ---------- 内存 R2 mock(workers-types 的 R2Bucket 最小面) ----------

interface MemObject {
  bytes: Uint8Array;
  uploaded: number;
  contentType: string;
}

class MemR2 {
  private store = new Map<string, MemObject>();

  async put(key: string, value: ReadableStream | Uint8Array | string): Promise<void> {
    let bytes: Uint8Array;
    if (typeof value === "string") {
      bytes = new TextEncoder().encode(value);
    } else if (value instanceof Uint8Array) {
      bytes = value;
    } else {
      bytes = new Uint8Array(await new Response(value).arrayBuffer());
    }
    this.store.set(key, { bytes, uploaded: Date.now(), contentType: "application/octet-stream" });
  }

  async get(key: string): Promise<{
    body: ReadableStream;
    size: number;
    httpMetadata: { contentType: string };
    arrayBuffer(): Promise<ArrayBuffer>;
  } | null> {
    const obj = this.store.get(key);
    if (!obj) return null;
    const body = new Response(obj.bytes).body!;
    return {
      body,
      size: obj.bytes.length,
      httpMetadata: { contentType: obj.contentType },
      arrayBuffer: async () => obj.bytes.slice().buffer as ArrayBuffer,
    };
  }

  async head(key: string): Promise<{ size: number; uploaded: Date } | null> {
    const obj = this.store.get(key);
    if (!obj) return null;
    return { size: obj.bytes.length, uploaded: new Date(obj.uploaded) };
  }

  async delete(key: string): Promise<void> {
    this.store.delete(key);
  }

  async list(options: { prefix: string; cursor?: string }): Promise<{
    objects: { key: string; size: number; uploaded: Date }[];
    truncated: boolean;
    cursor?: string;
  }> {
    const keys = [...this.store.keys()].filter((k) => k.startsWith(options.prefix)).sort();
    return { objects: keys.map((k) => ({ key: k, size: this.store.get(k)!.bytes.length, uploaded: new Date(this.store.get(k)!.uploaded) })), truncated: false };
  }
}

// ---------- 环境与调用 ----------

export function workerEnv(): Env {
  return {
    DATABASE_URL: process.env.UPW_TEST_DB_URL!,
    DATABASE_SSL: process.env.UPW_TEST_DB_SSL === "1" ? "1" : undefined,
    VAULTS: new MemR2() as unknown as R2Bucket,
    APP_KEK: "11".repeat(32),
    ADMIN_TOKEN: "test-admin-token",
    SMTP_HOST: "",
    SMTP_PORT: "",
    SMTP_FROM: "",
    SMTP_REPLY_TO: "",
    SMTP_USER: "",
    SMTP_PASSWORD: "",
    SMTP_MOCK: "1",
  } as unknown as Env;
}

export interface CallOptions {
  token?: string;
  body?: unknown;
  raw?: Uint8Array;
  headers?: Record<string, string>;
}

export async function call(
  env: Env,
  method: string,
  path: string,
  opts: CallOptions = {},
): Promise<Response> {
  const headers: Record<string, string> = { ...opts.headers };
  if (opts.token) headers.authorization = `Bearer ${opts.token}`;
  let body: string | Uint8Array | undefined;
  if (opts.raw !== undefined) {
    body = opts.raw;
    headers["content-type"] = "application/octet-stream";
    headers["content-length"] = String(opts.raw.length);
  } else if (opts.body !== undefined) {
    body = JSON.stringify(opts.body);
    headers["content-type"] = "application/json";
    headers["content-length"] = String(body.length);
  }
  const request = new Request(`https://api.test${path}`, { method, headers, body });
  return worker.fetch(request, env);
}

// ---------- 业务流助手 ----------

export async function mockCode(env: Env, email: string, purpose = "login"): Promise<string> {
  return deriveMockCode(env, email, purpose);
}

export async function registerUser(
  env: Env,
  email = "u1@example.com",
  platform = "macos",
): Promise<{ token: string; userId: string }> {
  await call(env, "POST", "/v2/auth/code", { body: { email } });
  const code = await mockCode(env, email);
  const res = await call(env, "POST", "/v2/auth/verify", {
    body: { email, code, deviceName: "tester", platform },
  });
  if (res.status !== 200) throw new Error(`register failed: ${res.status}`);
  const data = (await res.json()) as { token: string; userId: string };
  return data;
}

/// 伪造合法形态的 .upwkey 信封(UPWKEY1 魔数 + 填充到 100+ 字节;服务端只验格式)。
export function fakeEnvelope(seed = 1): Uint8Array {
  const bytes = new Uint8Array(120);
  const magic = [0x55, 0x50, 0x57, 0x4b, 0x45, 0x59, 0x31, 0x00];
  bytes.set(magic, 0);
  for (let i = 8; i < bytes.length; i++) bytes[i] = (seed + i) % 251;
  return bytes;
}

export function fakeEnvelopeB64(seed = 1): string {
  return bytesToB64(fakeEnvelope(seed));
}

export async function createVault(
  env: Env,
  token: string,
  name = "Main",
): Promise<string> {
  const res = await call(env, "POST", "/v2/vaults", {
    token,
    body: { name, envelope: fakeEnvelopeB64() },
  });
  if (res.status !== 201) throw new Error(`createVault failed: ${res.status}`);
  const data = (await res.json()) as { vaultId: string };
  return data.vaultId;
}

export async function sensitiveCode(env: Env, email: string): Promise<string> {
  await call(env, "POST", "/v2/auth/code", { body: { email, purpose: "sensitive" } });
  return mockCode(env, email, "sensitive");
}

/// 确定性条目密文占位(往返比对用,内容无意义)。
export function b64(seed: string): string {
  const bytes = new TextEncoder().encode(`body-${seed}`);
  let bin = "";
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  return btoa(bin);
}

/// 把 email_codes 全部行时间拨回 2 分钟前(绕过重发冷却的测试捷径:
/// 单活跃码结构下每 (邮箱,purpose) 只有一行,直接 UPDATE 即可)。
export async function ageCodes(): Promise<void> {
  const { createPool } = await import("mysql2/promise");
  const pool = createPool({
    uri: process.env.UPW_TEST_DB_URL!,
    multipleStatements: false,
    ...(process.env.UPW_TEST_DB_SSL === "1" ? { ssl: { rejectUnauthorized: false } } : {}),
  });
  await pool.query("UPDATE email_codes SET created_ms = created_ms - 120000");
  await pool.end();
}
