// 泄漏密码检测(k-匿名,Worker 代理):客户端只查自有端点,Worker 查边缘
// 缓存,未命中转发 HIBP range API 并回填(TTL 默认 24h)。HIBP 从此只见
// Worker 聚合流量,不再见用户 IP 与单设备查询时机。
// 隐私红线:查询前缀不进日志(只记计数/耗时)。

import { ApiError, json, numVar, type Env } from "./util";

const HIBP_RANGE_ORIGIN = "https://api.pwnedpasswords.com/range/";

/// GET /v2/breach/range/<5位hex前缀> —— 与 HIBP range API 同形响应
/// (每行 `35位后缀:流行度`),客户端本地比对完整 SHA-1。
export async function handleBreachRange(
  env: Env,
  prefix: string,
  startedAt: number,
): Promise<Response> {
  if (!/^[0-9A-Fa-f]{5}$/.test(prefix)) throw new ApiError(400, "bad_request");
  const ttl = numVar(env, "BREACH_CACHE_TTL_SECONDS", 86_400);
  const cacheKey = new Request(`https://breach-cache.internal/range/${prefix.toUpperCase()}`);

  // Cache API 仅生产 workerd 可用;Node 测试环境直连
  if (typeof caches !== "undefined" && caches.default) {
    const hit = await caches.default.match(cacheKey);
    if (hit) {
      console.log(JSON.stringify({ t: Date.now(), action: "breach_range", cached: 1, ms: Date.now() - startedAt }));
      return hit;
    }
  }

  // Add-Padding:HIBP 官方抗流量分析头(空格填充响应)
  const upstream = await fetch(HIBP_RANGE_ORIGIN + prefix.toUpperCase(), {
    headers: { "Add-Padding": "true" },
  });
  if (!upstream.ok) throw new ApiError(502, "upstream_unavailable");
  const body = await upstream.text();
  const response = new Response(body, {
    status: 200,
    headers: {
      "content-type": "text/plain; charset=utf-8",
      "cache-control": `private, max-age=${ttl}`,
    },
  });
  if (typeof caches !== "undefined" && caches.default) {
    // 缓存失败不影响响应(下一请求再回填)
    await caches.default.put(cacheKey, response.clone()).catch(() => undefined);
  }
  console.log(JSON.stringify({ t: Date.now(), action: "breach_range", cached: 0, ms: Date.now() - startedAt }));
  return response;
}
