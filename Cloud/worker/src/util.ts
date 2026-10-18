// 公共工具:KEK 应用层加密、键控哈希、随机、常量时间比较、输入校验、响应构造。
// 隐私红线:任何日志/错误/审计不包含邮箱、令牌、验证码、信封内容、条目密文。

export type Env = {
  /// Hyperdrive 绑定(生产);本地/测试用 DATABASE_URL 直连
  DB?: { connectionString: string };
  DATABASE_URL?: string;
  /// "1" = 直连启用 TLS(自签证书不校验,仅加密通道)
  DATABASE_SSL?: string;
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
  ITEM_BODY_MAX_BYTES: string;
  ITEMS_PER_VAULT_LIMIT: string;
  ITEMS_BATCH_MAX: string;
  ATTACHMENT_MAX_BYTES: string;
  ATTACH_QUOTA_PER_VAULT: string;
  ATTACH_STAGING_MAX_OBJECTS: string;
  CHANGE_RETENTION_DAYS: string;
  REKEY_TTL_MS: string;
  SITES_ICON_MAX_BYTES: string;
  BREACH_CACHE_TTL_SECONDS: string;
  CODE_TTL_SECONDS: string;
  CODE_RESEND_COOLDOWN_SECONDS: string;
  CODE_HOURLY_PER_EMAIL: string;
  CODE_HOURLY_PER_IP: string;
  CODE_MAX_ATTEMPTS: string;
  SESSION_TTL_DAYS: string;
  DEREGISTER_PURGE_DAYS: string;
};

/// 数字型 var 读取,缺省回退。
export function numVar(env: Env, key: keyof Env, fallback: number): number {
  const n = Number(env[key]);
  return Number.isFinite(n) && n > 0 ? n : fallback;
}

export function nowMs(): number {
  return Date.now();
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

export function decodeUtf8(bytes: Uint8Array): string {
  return textDecoder.decode(bytes);
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
  // KEK(32B) 直接作为 AES-GCM 与 HMAC 密钥。设计决策:已知同钥复用属
  // key-separation 卫生问题,GCM(计数器)与 HMAC(迭代)构造不同且 HMAC 消息
  // 域有 "email:"/"code:" 前缀分离,无已知跨协议攻击路径——接受现状;
  // 未来新增 KEK 用途必须走 HKDF 分域,轮换 KEK 时顺带引入 v2 双读。
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
/// 日志脱敏:错误文本中若混入邮箱(未来邮件库变更),统一替换为 [email]。
export function scrubEmails(text: string): string {
  return text.replace(/[\w.+-]+@[\w.-]+/g, "[email]");
}

export async function kekHmac(env: Env, info: string): Promise<string> {
  const { hmacKey } = await kekKeys(env);
  const mac = await crypto.subtle.sign("HMAC", hmacKey, utf8(info));
  return bytesToHex(new Uint8Array(mac));
}

/// 登录查询键:HMAC(APP_KEK, "email:" + 规范化邮箱)。
export async function emailHmc(env: Env, email: string): Promise<string> {
  return kekHmac(env, "email:" + email);
}

/// 验证码哈希:HMAC(APP_KEK, "code:" + emailHmc + ":" + code + ":" + purpose)。
export async function codeHash(
  env: Env,
  emailHmcHex: string,
  code: string,
  purpose: string,
): Promise<string> {
  return kekHmac(env, `code:${emailHmcHex}:${code}:${purpose}`);
}

/// 会话令牌哈希:令牌为 256bit 随机数,普通 SHA-256 即不可逆。
export async function sha256Hex(input: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", utf8(input));
  return bytesToHex(new Uint8Array(digest));
}

/// 字节版 SHA-256(条目体/附件写入的服务端实算校验用)。
export async function sha256OfBytes(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", bytes);
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

/// 库名会成为本地文件名:拒绝路径危险字符与伴随文件后缀冲突。
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

/// 十六进制校验统一大小写不敏感,并归一化为小写存储:
/// Swift 的 UUID().uuidString 是大写、TS 侧是小写,不归一化的话同一
/// 条目会按大小写变体存成两行(游标分页与 CAS 全部失真)。
export function validSha256Hex(input: unknown): string | null {
  if (typeof input !== "string" || !/^[0-9a-f]{64}$/i.test(input)) return null;
  return input.toLowerCase();
}

/// 条目标识:UUIDv4 客户端生成,服务端只认格式;同样归一化为小写
/// (Swift uuidString 大写 → 小写入库,与 changes/列表回读一致)。
export function validItemUuid(input: unknown): string | null {
  if (typeof input !== "string") return null;
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(input)) return null;
  return input.toLowerCase();
}

/// 网站目录域名:小写 host(去端口去末尾点),字符集收紧。
export function normalizeDomain(input: unknown): string | null {
  if (typeof input !== "string") return null;
  let d = input.trim().toLowerCase();
  if (d.includes("://")) d = d.split("://", 2)[1] ?? "";
  d = d.split("/", 1)[0].split(":", 1)[0].replace(/\.+$/, "");
  if (d.length < 1 || d.length > 253) return null;
  if (!/^[a-z0-9.-]+$/.test(d)) return null;
  return d;
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

/// 读取 JSON 请求体;非法/超限抛 400。maxBytes 按端点区分:
/// 条目批量与 rekey chunk 允许到 8MB,其余维持 64KB。
export async function readJson(
  request: Request,
  maxBytes = 64 * 1024,
): Promise<Record<string, unknown>> {
  // 未认证端点也走这里:content-length 预检防匿名大包先把 isolate 内存吃满
  const declaredLength = Number(request.headers.get("content-length") ?? "");
  if (Number.isFinite(declaredLength) && declaredLength > maxBytes) {
    throw new ApiError(413, "too_large");
  }
  const raw = await request.text();
  if (raw.length > maxBytes) throw new ApiError(400, "bad_request");
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

/// R2 前缀全删(游标翻页到空)。删库、注销 purge 与附件前缀清理共用同一实现。
export async function deleteR2Prefix(bucket: R2Bucket, prefix: string): Promise<void> {
  let cursor: string | undefined;
  do {
    const listing = await bucket.list({ prefix, cursor });
    for (const item of listing.objects) {
      await bucket.delete(item.key);
    }
    cursor = listing.truncated ? listing.cursor : undefined;
  } while (cursor);
}
