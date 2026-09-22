import { describe, expect, it } from "vitest";
import { base32Decode, hotp, parseTotp, remainingSeconds, totpCode } from "../src/lib/totp";

// RFC 6238 reference secret ("12345678901234567890") in base32 = GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ
const RFC_SECRET = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ";

describe("base32Decode", () => {
  it("decodes RFC 4238 test vectors", () => {
    expect(Buffer.from(base32Decode(RFC_SECRET)).toString()).toBe("12345678901234567890");
    expect(Buffer.from(base32Decode("MY======")).toString()).toBe("f");
    expect(Buffer.from(base32Decode("MZXQ====")).toString()).toBe("fo");
  });
});

describe("TOTP (RFC 6238 official vectors)", () => {
  // RFC 6238 uses a different seed length per algorithm
  const SEEDS: Record<string, string> = {
    SHA1: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", // "12345678901234567890"
    SHA256: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZA", // 32-byte seed
    SHA512: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNA", // 64-byte seed
  };
  const cases: [string, string, number][] = [
    // [algorithm, expected 8-digit code at T=59]
    ["SHA1", "94287082", 59],
    ["SHA256", "46119246", 59],
    ["SHA512", "90693936", 59],
  ];
  for (const [algorithm, expected, at] of cases) {
    it(`${algorithm} @ T=${at}`, async () => {
      const cfg = parseTotp(SEEDS[algorithm]);
      cfg.algorithm = algorithm as never;
      cfg.digits = 8;
      expect(await hotp(cfg, Math.floor(at / 30))).toBe(expected);
    });
  }

  it("rejects invalid secrets", () => {
    expect(() => parseTotp("")).toThrow();
    expect(() => parseTotp("otpauth://totp/x?digits=6")).toThrow();
  });

  it("parses otpauth URIs", async () => {
    // JBSWY3DPEHPK3PXP decodes to "Hello!" + padding bytes (Google's canonical example)
    const cfg = parseTotp("otpauth://totp/Example:alice?secret=JBSWY3DPEHPK3PXP&period=60&digits=6&issuer=Example");
    expect(cfg.period).toBe(60);
    expect(cfg.issuer).toBe("Example");
    expect(Buffer.from(cfg.secret.slice(0, 6)).toString()).toBe("Hello!");
  });

  it("computes the code at a fixed time", async () => {
    const cfg = parseTotp(RFC_SECRET);
    const code = await totpCode(cfg, new Date(59_000));
    expect(code).toHaveLength(6);
    expect(code).toMatch(/^\d{6}$/);
  });

  it("remainingSeconds rolls over at the period boundary", () => {
    expect(remainingSeconds(30, new Date(29_000))).toBe(1);
    expect(remainingSeconds(30, new Date(0))).toBe(30);
  });
});
