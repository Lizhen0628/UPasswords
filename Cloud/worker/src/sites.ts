// 网站目录(全局非用户数据):lookup(名称按语言端上取 name_zh ?? name_en,
// 图标 b64 内联)、icon 字节流(sha256 内容寻址 + 强缓存)、管理面批量 upsert。
// 隐私红线:lookup 查询域名不进日志(只记计数/耗时)。

import { audit, exec, q, q1 } from "./db";
import {
  ApiError,
  b64ToBytes,
  bytesToB64,
  json,
  normalizeDomain,
  nowMs,
  numVar,
  readJson,
  sha256OfBytes,
  timingSafeEqual,
  validSha256Hex,
  type Env,
} from "./util";

function iconKey(sha256: string): string {
  return `sites/icons/${sha256}`;
}

interface SiteRow {
  site_id: number;
  name_zh: string | null;
  name_en: string;
  home_url: string | null;
  icon_sha256: string | null;
  icon_mime: string | null;
  icon_bytes: number | null;
  status: number;
}

/// GET /v2/sites/lookup?domain=<host> —— 命中返回站点与图标(b64 内联),
/// 未命中 404(客户端回退现行抓 favicon / host 作名称)。客户端按 host
/// 逐级去标签向根匹配后查询(与扩展 host 匹配矩阵同规则)。
export async function handleSiteLookup(env: Env, request: Request): Promise<Response> {
  const startedAt = Date.now();
  const domain = normalizeDomain(new URL(request.url).searchParams.get("domain"));
  if (!domain) throw new ApiError(400, "invalid_domain");
  const row = await q1<SiteRow & { is_primary: number }>(
    env,
    `SELECT w.*, wd.is_primary FROM website_domains wd JOIN websites w ON w.site_id = wd.site_id
     WHERE wd.domain = ? AND w.status = 1`,
    [domain],
  );
  if (!row) {
    console.log(JSON.stringify({ t: Date.now(), action: "site_lookup", hit: 0, ms: Date.now() - startedAt }));
    throw new ApiError(404, "not_found");
  }
  let primaryDomain = domain;
  if (!row.is_primary) {
    const primary = await q1<{ domain: string }>(
      env,
      "SELECT domain FROM website_domains WHERE site_id = ? AND is_primary = 1 LIMIT 1",
      [row.site_id],
    );
    if (primary) primaryDomain = primary.domain;
  }
  let icon: { sha256: string; bytes: number; b64: string } | null = null;
  if (row.icon_sha256) {
    const object = await env.VAULTS.get(iconKey(row.icon_sha256));
    if (object) {
      const bytes = new Uint8Array(await object.arrayBuffer());
      icon = { sha256: row.icon_sha256, bytes: bytes.length, b64: bytesToB64(bytes) };
    }
  }
  console.log(JSON.stringify({ t: Date.now(), action: "site_lookup", hit: 1, ms: Date.now() - startedAt }));
  return json({
    siteId: row.site_id,
    domain,
    primaryDomain,
    nameZh: row.name_zh,
    nameEn: row.name_en,
    homeUrl: row.home_url,
    icon,
  });
}

/// GET /v2/sites/icon/<sha256> —— 图标字节流(ETag=sha256 强缓存)。
export async function handleSiteIcon(env: Env, sha256: string): Promise<Response> {
  if (!validSha256Hex(sha256)) throw new ApiError(404, "not_found");
  const object = await env.VAULTS.get(iconKey(sha256));
  if (!object) throw new ApiError(404, "not_found");
  const headers = new Headers({
    "content-type": object.httpMetadata?.contentType ?? "image/png",
    "etag": `"${sha256}"`,
    "cache-control": "private, max-age=2592000, immutable",
  });
  return new Response(object.body, { status: 200, headers });
}

/// POST /v2/admin/sites —— 目录批量 upsert(X-Admin-Token + 运营导入;
/// 图标按 sha256 内容寻址落 R2 自动去重)。
export async function handleAdminSitesPut(env: Env, request: Request): Promise<Response> {
  requireAdmin(env, request);
  const body = await readJson(request, 8 * 1024 * 1024);
  const sites = Array.isArray(body.sites) ? body.sites : null;
  if (!sites || sites.length < 1 || sites.length > 2000) throw new ApiError(400, "bad_request");
  const iconMax = numVar(env, "SITES_ICON_MAX_BYTES", 65_536);
  const now = nowMs();
  let upserted = 0;

  for (const raw of sites) {
    const r = raw as Record<string, unknown>;
    const nameEn = typeof r.nameEn === "string" ? r.nameEn.trim().slice(0, 255) : "";
    const nameZh = typeof r.nameZh === "string" && r.nameZh.trim() ? r.nameZh.trim().slice(0, 255) : null;
    const homeUrl = typeof r.homeUrl === "string" ? r.homeUrl.trim().slice(0, 512) : null;
    const domainsRaw = Array.isArray(r.domains) ? r.domains : [];
    const primaryRaw = typeof r.primary === "string" ? normalizeDomain(r.primary) : null;
    const domains = [...new Set(domainsRaw.map((d) => normalizeDomain(d)).filter((d): d is string => d !== null))];
    if (!nameEn || domains.length < 1) throw new ApiError(400, "bad_request");
    const primary = primaryRaw && domains.includes(primaryRaw) ? primaryRaw : domains[0];

    let iconSha: string | null = null;
    let iconMime: string | null = null;
    let iconBytes: number | null = null;
    if (typeof r.iconB64 === "string" && r.iconB64) {
      const bytes = b64ToBytes(r.iconB64);
      if (!bytes || bytes.length < 1 || bytes.length > iconMax) throw new ApiError(400, "invalid_icon");
      iconSha = await sha256OfBytes(bytes);
      iconMime = typeof r.iconMime === "string" ? r.iconMime.slice(0, 16) : "image/png";
      iconBytes = bytes.length;
      await env.VAULTS.put(iconKey(iconSha), bytes, {
        httpMetadata: { contentType: iconMime },
      });
    }

    // 既有站点:按任一已有域名认领;否则新建
    const placeholders = domains.map(() => "?").join(", ");
    const existing = await q1<{ site_id: number }>(
      env,
      `SELECT site_id FROM website_domains WHERE domain IN (${placeholders}) LIMIT 1`,
      domains,
    );
    let siteId = existing?.site_id ?? 0;
    if (siteId) {
      await exec(
        env,
        "UPDATE websites SET name_zh = ?, name_en = ?, home_url = COALESCE(?, home_url), icon_sha256 = COALESCE(?, icon_sha256), icon_mime = COALESCE(?, icon_mime), icon_bytes = COALESCE(?, icon_bytes), icon_updated_ms = CASE WHEN ? THEN ? ELSE icon_updated_ms END, updated_ms = ? WHERE site_id = ?",
        [nameZh, nameEn, homeUrl, iconSha, iconMime, iconBytes, iconSha ? 1 : 0, now, now, siteId],
      );
    } else {
      const inserted = await exec(
        env,
        "INSERT INTO websites (name_zh, name_en, home_url, icon_sha256, icon_mime, icon_bytes, icon_updated_ms, status, created_ms, updated_ms) VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?, ?)",
        [nameZh, nameEn, homeUrl, iconSha, iconMime, iconBytes, iconSha ? now : null, now, now],
      );
      siteId = inserted.insertId;
    }
    for (const d of domains) {
      await exec(
        env,
        "INSERT INTO website_domains (domain, site_id, is_primary) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE site_id = VALUES(site_id), is_primary = VALUES(is_primary)",
        [d, siteId, d === primary ? 1 : 0],
      );
    }
    upserted += 1;
  }
  await audit(env, "admin_sites_upsert", {}, { n: upserted });
  return json({ ok: true, upserted });
}

export function requireAdmin(env: Env, request: Request): void {
  const token = request.headers.get("x-admin-token") ?? "";
  if (!token || !timingSafeEqual(token, env.ADMIN_TOKEN)) throw new ApiError(401, "unauthorized");
}
