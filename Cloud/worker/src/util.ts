// 公共工具:KEK 应用层加密、键控哈希、随机、常量时间比较、输入校验、响应构造。
// 隐私红线:任何日志/错误/审计不包含邮箱、令牌、验证码、信封内容。

export type Env = {
  DB: D1Database;
  VAULTS: R2Bucket;
  APP_KEK: string;
  ADMIN_TOKEN: string;
  SMTP_HOST: string;
  SMTP_PORT: string;
  SMTP_FROM: string;
  SMTP_REPLY_TO: string;
  SMTP_USER: string;
  SMTP_PASSWORD: string;
  SMTP_MOCK?: string;
  VAULT_LIMIT_PER_USER: string;
  VAULT_BODY_MAX_BYTES: string;
  CODE_TTL_SECONDS: string;
  CODE_RESEND_COOLDOWN_SECONDS: string;
  CODE_HOURLY_PER_EMAIL: string;
  CODE_HOURLY_PER_IP: string;
  CODE_MAX_ATTEMPTS: string;
  SESSION_TTL_DAYS: string;
  DEREGISTER_PURGE_DAYS: string;
  CHANGED_AT_MAX_SKEW_SECONDS: string;
};

/// 数字型 var 读取,缺省回退。
export function numVar(env: Env, key: keyof Env, fallback: number): number {
  const n = Number(env[key]);
  return Number.isFinite(n) && n > 0 ? n : fallback;
}

export function nowSec(): number {
  return Date.now() / 1000;
}

// ---------- 编码 ----------

export function bytesToB64(bytes: Uint8Array): string {
  let bin = "";
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  return btoa(bin);
}

export function b64ToBytes(s: string): Uint8Array | null {
  try {
    const bin = atob(s);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  } catch {
    return null;
  }
}

export function bytesToHex(bytes: Uint8Array): string {
  let out = "";
  for (let i = 0; i < bytes.length; i++) out += bytes[i].toString(16).padStart(2, "0");
  return out;
}

export function hexToBytes(hex: string): Uint8Array | null {
  if (!/^[0-9a-fA-F]*$/.test(hex) || hex.length % 2 !== 0) return null;
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  return out;
}

const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder();

export function utf8(s: string): Uint8Array {
  return textEncoder.encode(s);
}

// ---------- 随机 ----------

export function randomBytes(n: number): Uint8Array {
  const b = new Uint8Array(n);
  crypto.getRandomValues(b);
  return b;
}

export function randomHex(nBytes: number): string {
  return bytesToHex(randomBytes(nBytes));
}

/// 6 位数字验证码:拒绝采样消除模偏差。
export function randomCode6(): string {
  for (;;) {
    const v = new DataView(randomBytes(4).buffer).getUint32(0);
    if (v < 4_000_000_000) return String(v % 1_000_000).padStart(6, "0");
  }
}

// ---------- KEK 应用层加密(版本前缀,支持轮换) ----------

let kekCache: { material: string; aesKey: CryptoKey; hmacKey: CryptoKey } | null = null;

async function kekKeys(env: Env): Promise<{ aesKey: CryptoKey; hmacKey: CryptoKey }> {
  if (kekCache?.material === env.APP_KEK) return kekCache;
  const raw = hexToBytes(env.APP_KEK);
  if (!raw || raw.length !== 32) throw new Error("APP_KEK invalid (need 64 hex chars)");
  // KEK(32B) 直接作为 AES-GCM 与 HMAC 密钥
  const aesKey = await crypto.subtle.importKey("raw", raw, { name: "AES-GCM" }, false, [
    "encrypt",
    "decrypt",
  ]);
  const hmacKey = await crypto.subtle.importKey(
    "raw",
    raw,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  kekCache = { material: env.APP_KEK, aesKey, hmacKey };
  return { aesKey, hmacKey };
}

/// AES-GCM(APP_KEK) 加密,输出 "v1." + b64(nonce12 + ct + tag)。
export async function kekSeal(env: Env, plain: Uint8Array): Promise<string> {
  const { aesKey } = await kekKeys(env);
  const nonce = randomBytes(12);
  const ct = new Uint8Array(
    await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce }, aesKey, plain),
  );
  const out = new Uint8Array(12 + ct.length);
  out.set(nonce, 0);
  out.set(ct, 12);
  return "v1." + bytesToB64(out);
}

/// 解密 kekSeal 产物;失败(含 KEK 轮换丢失)返回 null,调用方按缺省处理。
export async function kekOpen(env: Env, sealed: string | null): Promise<Uint8Array | null> {
  if (!sealed || !sealed.startsWith("v1.")) return null;
  const raw = b64ToBytes(sealed.slice(3));
  if (!raw || raw.length < 12 + 16) return null;
  try {
    const { aesKey } = await kekKeys(env);
    const pt = await crypto.subtle.decrypt(
      { name: "AES-GCM", iv: raw.slice(0, 12) },
      aesKey,
      raw.slice(12),
    );
    return new Uint8Array(pt);
  } catch {
    return null;
  }
}

/// 键控哈希 HMAC-SHA256(APP_KEK, info) → hex。
/// 拖库后既不可逆也不可枚举(无 KEK 无法验证猜测)。
export async function kekHmac(env: Env, info: string): Promise<string> {
  const { hmacKey } = await kekKeys(env);
  const mac = await crypto.subtle.sign("HMAC", hmacKey, utf8(info));
  return bytesToHex(new Uint8Array(mac));
}

/// 登录查询键:HMAC(APP_KEK, "email:" + 规范化邮箱)。
export async function emailHmac(env: Env, email: string): Promise<string> {
  return kekHmac(env, "email:" + email);
}

/// 验证码哈希:HMAC(APP_KEK, "code:" + emailHmac + ":" + code + ":" + purpose)。
export async function codeHash(
  env: Env,
  emailHmacHex: string,
  code: string,
  purpose: string,
): Promise<string> {
  return kekHmac(env, `code:${emailHmacHex}:${code}:${purpose}`);
}

/// 会话令牌哈希:令牌为 256bit 随机数,普通 SHA-256 即不可逆。
export async function sha256Hex(input: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", utf8(input));
  return bytesToHex(new Uint8Array(digest));
}

// ---------- 常量时间比较 ----------

export function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

// ---------- 输入校验 ----------

export function normalizeEmail(input: unknown): string | null {
  if (typeof input !== "string") return null;
  const email = input.trim().toLowerCase();
  if (email.length < 3 || email.length > 254) return null;
  if (!/^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z0-9-]+$/.test(email)) return null;
  return email;
}

/// 库名会成为网盘文件名:拒绝路径危险字符与伴随文件后缀冲突。
export function validVaultName(input: unknown): string | null {
  if (typeof input !== "string") return null;
  const name = input.trim();
  if (name.length < 1 || name.length > 64) return null;
  if (name.startsWith(".")) return null;
  if (/[\\/:*?"<>|\u0000-\u001f]/.test(name)) return null;
  const lower = name.toLowerCase();
  if (lower.endsWith(".upw") || lower.endsWith(".upwkey") || lower.endsWith(".old")) return null;
  return name;
}

export function validSha256Hex(input: unknown): string | null {
  if (typeof input !== "string" || !/^[0-9a-f]{64}$/.test(input)) return null;
  return input;
}

// ---------- 响应 ----------

export class ApiError extends Error {
  constructor(
    public status: number,
    public code: string,
    public retryAfter?: number,
  ) {
    super(code);
  }
}

const BASE_HEADERS: Record<string, string> = {
  "content-type": "application/json; charset=utf-8",
  "strict-transport-security": "max-age=31536000; includeSubDomains",
  "cache-control": "no-store",
};

export function json(data: unknown, status = 200, extra?: Record<string, string>): Response {
  const headers = { ...BASE_HEADERS, ...extra };
  return new Response(JSON.stringify(data), { status, headers });
}

/// 读取 JSON 请求体;非法/超限抛 400。
export async function readJson(request: Request): Promise<Record<string, unknown>> {
  const MAX_BODY_BYTES = 64 * 1024;
  const raw = await request.text();
  if (raw.length > MAX_BODY_BYTES) throw new ApiError(400, "bad_request");
  try {
    const parsed = JSON.parse(raw);
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
      return parsed as Record<string, unknown>;
    }
  } catch {
    // 落到统一 bad_request
  }
  throw new ApiError(400, "bad_request");
}
