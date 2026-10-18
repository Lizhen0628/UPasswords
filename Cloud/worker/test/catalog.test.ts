// 网站目录 + 泄漏检测代理 + 能力协商/统计。

import { describe, expect, it } from "vitest";
import { call, registerUser, workerEnv } from "./helpers";

describe("site catalog", () => {
  it("admin upsert → lookup hit (zh/en + icon) → miss 404", async () => {
    const env = workerEnv();
    const { token } = await registerUser(env, "sites@example.com");

    const noAuth = await call(env, "POST", "/v2/admin/sites", {
      body: { sites: [{ domains: ["github.com"], nameEn: "GitHub" }] },
    });
    expect(noAuth.status).toBe(401);

    const upsert = await call(env, "POST", "/v2/admin/sites", {
      headers: { "x-admin-token": "test-admin-token" },
      body: {
        sites: [
          {
            domains: ["github.com", "gist.github.com"],
            primary: "github.com",
            nameEn: "GitHub",
            nameZh: null,
            iconB64: b64png(),
            iconMime: "image/png",
          },
          {
            domains: ["example.cn"],
            nameEn: "Example",
            nameZh: "示例站",
          },
        ],
      },
    });
    expect(upsert.status).toBe(200);
    expect(((await upsert.json()) as { upserted: number }).upserted).toBe(2);

    const hit = (await (
      await call(env, "GET", "/v2/sites/lookup?domain=gist.github.com", { token })
    ).json()) as {
      siteId: number;
      domain: string;
      primaryDomain: string;
      nameEn: string;
      nameZh: string | null;
      icon: { b64: string; bytes: number } | null;
    };
    expect(hit.primaryDomain).toBe("github.com");
    expect(hit.nameEn).toBe("GitHub");
    expect(hit.nameZh).toBeNull();
    expect(hit.icon?.b64).toBe(b64png());

    const zh = (await (
      await call(env, "GET", "/v2/sites/lookup?domain=example.cn", { token })
    ).json()) as { nameZh: string | null };
    expect(zh.nameZh).toBe("示例站");

    const miss = await call(env, "GET", "/v2/sites/lookup?domain=nosuch.example", { token });
    expect(miss.status).toBe(404);

    const badDomain = await call(env, "GET", "/v2/sites/lookup?domain=not_a_domain", { token });
    expect(badDomain.status).toBe(400);
  });

  it("icon endpoint serves bytes with strong cache headers", async () => {
    const env = workerEnv();
    const { token } = await registerUser(env, "icon@example.com");
    await call(env, "POST", "/v2/admin/sites", {
      headers: { "x-admin-token": "test-admin-token" },
      body: { sites: [{ domains: ["withicon.net"], nameEn: "WithIcon", iconB64: b64png() }] },
    });
    const lookup = (await (
      await call(env, "GET", "/v2/sites/lookup?domain=withicon.net", { token })
    ).json()) as { icon: { sha256: string } };
    const icon = await call(env, "GET", `/v2/sites/icon/${lookup.icon.sha256}`, { token });
    expect(icon.status).toBe(200);
    expect(icon.headers.get("cache-control")).toContain("immutable");
    expect(icon.headers.get("etag")).toBe(`"${lookup.icon.sha256}"`);
    expect(await icon.text()).toBe(pngText());
  });
});

describe("breach range proxy", () => {
  const realFetch = globalThis.fetch;

  it("requires auth and proxies HIBP with same-shape body", async ({ onTestFinished }) => {
    const env = workerEnv();
    let upstreamHits = 0;
    globalThis.fetch = (async (input: RequestInfo | URL) => {
      const url = String(input);
      if (url.includes("pwnedpasswords.com")) {
        upstreamHits += 1;
        expect(url.endsWith("/range/0ABCD")).toBe(true);
        return new Response("CDEF1:5\nCDEF2:42\r\n", { status: 200 });
      }
      return realFetch(input);
    }) as typeof fetch;
    onTestFinished(() => {
      globalThis.fetch = realFetch;
    });

    const noAuth = await call(env, "GET", "/v2/breach/range/0ABCD");
    expect(noAuth.status).toBe(401);

    const { token } = await registerUser(env, "breach@example.com");
    const res = await call(env, "GET", "/v2/breach/range/0ABCD", { token });
    expect(res.status).toBe(200);
    expect(await res.text()).toContain("CDEF2:42");
    expect(upstreamHits).toBe(1);

    const badPrefix = await call(env, "GET", "/v2/breach/range/XYZ", { token });
    expect(badPrefix.status).toBe(400);
  });
});

describe("capabilities & stats", () => {
  it("GET /v2 advertises row_sync and v2 capabilities", async () => {
    const env = workerEnv();
    const res = await call(env, "GET", "/v2");
    expect(res.status).toBe(200);
    expect(res.headers.get("strict-transport-security")).toContain("max-age");
    const data = (await res.json()) as { version: number; capabilities: string[] };
    expect(data.version).toBe(2);
    expect(data.capabilities).toContain("vaults.row_sync");
    expect(data.capabilities).toContain("breach.range");
  });

  it("admin stats require token and aggregate counters", async () => {
    const env = workerEnv();
    await registerUser(env, "stats@example.com");
    const noAuth = await call(env, "GET", "/v2/admin/stats");
    expect(noAuth.status).toBe(401);
    const res = await call(env, "GET", "/v2/admin/stats", {
      headers: { "x-admin-token": "test-admin-token" },
    });
    expect(res.status).toBe(200);
    const data = (await res.json()) as { users: { active: number }; sessions: number };
    expect(data.users.active).toBeGreaterThanOrEqual(1);
    expect(data.sessions).toBeGreaterThanOrEqual(1);
  });
});

function pngText(): string {
  return "fake-png-bytes-for-icon";
}

function b64png(): string {
  const bytes = new TextEncoder().encode(pngText());
  let bin = "";
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  return btoa(bin);
}
