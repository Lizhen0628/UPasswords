// RFC 6238 TOTP for `one_time_password` fields — mirrors Services/TOTP.swift.
// Accepts a bare base32 secret or a full otpauth:// URI. HMAC via WebCrypto.
import { t } from "./i18n";

export interface TotpConfig {
  secret: Uint8Array;
  digits: number;
  period: number;
  algorithm: "SHA1" | "SHA256" | "SHA512";
  issuer?: string | null;
  account?: string | null;
}

export function base32Decode(s: string): Uint8Array {
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
  let bits = 0;
  let value = 0;
  const out: number[] = [];
  for (const ch of s.toUpperCase()) {
    const idx = alphabet.indexOf(ch);
    if (idx < 0) continue;
    value = (value << 5) | idx;
    bits += 5;
    if (bits >= 8) {
      out.push((value >> (bits - 8)) & 0xff);
      bits -= 8;
    }
  }
  return new Uint8Array(out);
}

/** Parses a raw field value: bare base32 secret or otpauth:// URI. */
export function parseTotp(raw: string): TotpConfig {
  const trimmed = raw.trim();
  if (!trimmed) throw new Error(t("invalid_value_text"));
  if (trimmed.toLowerCase().startsWith("otpauth://")) {
    const url = new URL(trimmed);
    const cfg: TotpConfig = {
      secret: new Uint8Array(0),
      digits: 6,
      period: 30,
      algorithm: "SHA1",
      issuer: url.hostname || null,
      account: null,
    };
    const accountPart = decodeURIComponent(url.pathname.replace(/^\//, ""));
    if (accountPart) cfg.account = accountPart;
    for (const [k, v] of url.searchParams.entries()) {
      switch (k.toLowerCase()) {
        case "secret": {
          const dec = base32Decode(v);
          if (dec.length) cfg.secret = dec;
          break;
        }
        case "digits": cfg.digits = parseInt(v, 10) || 6; break;
        case "period": cfg.period = parseInt(v, 10) || 30; break;
        case "algorithm":
          cfg.algorithm = (v.toUpperCase() as TotpConfig["algorithm"]) || "SHA1";
          break;
        case "issuer": cfg.issuer = v; break;
      }
    }
    if (!cfg.secret.length) throw new Error(t("invalid_value_text"));
    return cfg;
  }
  return { secret: base32Decode(trimmed), digits: 6, period: 30, algorithm: "SHA1", issuer: null, account: null };
}

async function hmac(algorithm: string, key: Uint8Array, message: Uint8Array): Promise<ArrayBuffer> {
  const cryptoKey = await crypto.subtle.importKey(
    "raw",
    key as BufferSource,
    { name: "HMAC", hash: { name: algorithm } },
    false,
    ["sign"],
  );
  return crypto.subtle.sign("HMAC", cryptoKey, message as BufferSource);
}

/** RFC 6238 code for the given time. */
export async function totpCode(config: TotpConfig, at = new Date()): Promise<string> {
  const counter = Math.floor(at.getTime() / 1000 / config.period);
  return hotp(config, counter);
}

export async function hotp(config: TotpConfig, counter: number): Promise<string> {
  const msg = new Uint8Array(8);
  for (let i = 0; i < 8; i++) {
    msg[i] = (counter / 2 ** (56 - 8 * i)) & 0xff;
  }
  const algo = config.algorithm === "SHA256" ? "SHA-256" : config.algorithm === "SHA512" ? "SHA-512" : "SHA-1";
  const digest = new Uint8Array(await hmac(algo, config.secret, msg));
  const offset = digest[digest.length - 1] & 0x0f;
  let bin = 0;
  for (let i = 0; i < 4; i++) bin = (bin << 8) | digest[offset + i];
  bin &= 0x7fffffff;
  const mod = 10 ** config.digits;
  return String(bin % mod).padStart(config.digits, "0");
}

/** Seconds until the current code rolls over. */
export function remainingSeconds(period: number, at = new Date()): number {
  return period - Math.floor(at.getTime() / 1000) % period;
}
