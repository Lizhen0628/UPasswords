// upasswords.com 信封同步通道(零知识)
// 只存取主密码包裹库密钥的 ~100B 信封;vault id 与访问令牌由库密钥 HKDF 派生,
// 服务端只见 SHA-256(token) 与密文,无法关联用户身份,也无法解密任何数据。
const VAULT_PATH = /^\/v1\/vaults\/([0-9a-f]{64})\/envelope$/;
const MAX_ENVELOPE_B64 = 4096;
// 墓碑 TTL:400 天不活跃的信封自动清除(KV 最小 60s,取宽松值避免活跃库被误清)
const ENVELOPE_TTL_SECONDS = 400 * 24 * 60 * 60;

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

async function sha256hex(text) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export default {
  async fetch(request, env) {
    const match = new URL(request.url).pathname.match(VAULT_PATH);
    if (!match) return json({ error: "not found" }, 404);
    const key = `vault:${match[1]}`;

    if (request.method === "GET") {
      const record = await env.VAULTS.get(key, "json");
      return record
        ? json({ rev: record.rev, changedAt: record.changedAt, envelope: record.envelope })
        : json({ error: "not found" }, 404);
    }

    if (request.method === "PUT") {
      const token = (request.headers.get("authorization") || "").replace(/^Bearer /i, "");
      if (!/^[0-9a-f]{64}$/.test(token)) return json({ error: "unauthorized" }, 401);
      let body;
      try {
        body = await request.json();
      } catch {
        return json({ error: "bad request" }, 400);
      }
      if (
        typeof body?.envelope !== "string" ||
        body.envelope.length > MAX_ENVELOPE_B64 ||
        typeof body?.changedAt !== "number"
      ) {
        return json({ error: "bad request" }, 400);
      }
      const tokenHash = await sha256hex(token);
      const existing = await env.VAULTS.get(key, "json");
      // 库已被认领且令牌不符 → 拒绝(令牌即库密钥派生,无法伪造)
      if (existing && existing.tokenHash !== tokenHash) return json({ error: "forbidden" }, 403);
      // changedAt 决胜:过期写不覆盖新值(iCloud 分歧期盲传在强一致侧无效)
      if (existing && body.changedAt <= existing.changedAt) {
        return json({ rev: existing.rev, changedAt: existing.changedAt, stale: true });
      }
      const next = {
        tokenHash,
        envelope: body.envelope,
        changedAt: body.changedAt,
        rev: (existing?.rev ?? 0) + 1,
      };
      await env.VAULTS.put(key, JSON.stringify(next), { expirationTtl: ENVELOPE_TTL_SECONDS });
      return json({ rev: next.rev, changedAt: next.changedAt });
    }

    return json({ error: "method not allowed" }, 405);
  },
};
