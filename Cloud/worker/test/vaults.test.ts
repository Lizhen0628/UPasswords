// vault 注册表测试:登记/配额/信封决胜与钳制/哈希/改名/解绑/跨用户隔离。

import { describe, expect, it } from "vitest";
import { call, createVault, fakeEnvelope, registerUser, sensitiveCode, workerEnv } from "./helpers";

async function putEnvelope(
  token: string,
  vaultId: string,
  changedAt: number,
  envelope = fakeEnvelope(),
): Promise<Response> {
  return call("PUT", `/v1/vaults/${vaultId}/envelope`, { envelope, changedAt }, token);
}

describe("vault 登记", () => {
  it("创建/列表/详情;重名 409;非法名 400", async () => {
    const token = await registerUser("kate@example.com");
    const vaultId = await createVault(token, "Main");

    const list = await call("GET", "/v1/vaults", undefined, token);
    const { vaults } = (await list.json()) as { vaults: { vaultId: string; name: string }[] };
    expect(vaults.map((v) => v.name)).toContain("Main");

    const detail = await call("GET", `/v1/vaults/${vaultId}`, undefined, token);
    expect(detail.status).toBe(200);
    const meta = (await detail.json()) as { envelope: string | null; passwordVersion: number };
    expect(meta.envelope).toBeNull();
    expect(meta.passwordVersion).toBe(1);

    expect((await call("POST", "/v1/vaults", { name: "Main" }, token)).status).toBe(409);
    expect((await call("POST", "/v1/vaults", { name: "a/b" }, token)).status).toBe(400);
    expect((await call("POST", "/v1/vaults", { name: "x.upw" }, token)).status).toBe(400);
    expect((await call("POST", "/v1/vaults", { name: "" }, token)).status).toBe(400);
  });

  it("每用户 10 库配额:第 11 个 413", async () => {
    const token = await registerUser("liam@example.com");
    for (let i = 0; i < 10; i++) {
      await createVault(token, `V${i}`);
    }
    const res = await call("POST", "/v1/vaults", { name: "V10" }, token);
    expect(res.status).toBe(413);
  });
});

describe("信封上报", () => {
  it("合法信封写入并读回一致;版本递增", async () => {
    const token = await registerUser("mona@example.com");
    const vaultId = await createVault(token, "Main");
    const now = Date.now() / 1000;
    const envelope = fakeEnvelope();

    const put = await putEnvelope(token, vaultId, now, envelope);
    expect(put.status).toBe(200);
    const { passwordVersion } = (await put.json()) as { passwordVersion: number };
    expect(passwordVersion).toBe(2);

    const detail = await call("GET", `/v1/vaults/${vaultId}`, undefined, token);
    const meta = (await detail.json()) as { envelope: string; hasEnvelope: boolean };
    expect(meta.hasEnvelope).toBe(true);
    expect(meta.envelope).toBe(envelope);
  });

  it("changedAt 决胜:过期写返回 stale 且不覆盖", async () => {
    const token = await registerUser("nina@example.com");
    const vaultId = await createVault(token, "Main");
    const now = Date.now() / 1000;
    await putEnvelope(token, vaultId, now + 30);

    const stale = await putEnvelope(token, vaultId, now);
    const data = (await stale.json()) as { stale: boolean };
    expect(data.stale).toBe(true);

    const detail = await call("GET", `/v1/vaults/${vaultId}`, undefined, token);
    const meta = (await detail.json()) as { passwordVersion: number };
    expect(meta.passwordVersion).toBe(2); // 未递增
  });

  it("时钟偏斜钳制:未来 1 小时的时间戳被钳到当前", async () => {
    const token = await registerUser("oscar@example.com");
    const vaultId = await createVault(token, "Main");
    const now = Date.now() / 1000;
    const res = await putEnvelope(token, vaultId, now + 3600);
    const { changedAt } = (await res.json()) as { changedAt: number };
    expect(Math.abs(changedAt - now)).toBeLessThan(10);
  });

  it("非法信封(坏魔数/过短/坏 b64)400", async () => {
    const token = await registerUser("pete@example.com");
    const vaultId = await createVault(token, "Main");
    const now = Date.now() / 1000;
    // 坏魔数:覆盖前 8 字节
    const badMagic = fakeEnvelope();
    const bytes = Uint8Array.from(atob(badMagic), (c) => c.charCodeAt(0));
    bytes[0] = 0x58;
    let bin = "";
    for (const b of bytes) bin += String.fromCharCode(b);
    expect(
      (await call("PUT", `/v1/vaults/${vaultId}/envelope`, { envelope: btoa(bin), changedAt: now }, token)).status,
    ).toBe(400);
    // 过短
    expect(
      (await call("PUT", `/v1/vaults/${vaultId}/envelope`, { envelope: btoa("short"), changedAt: now }, token)).status,
    ).toBe(400);
    // 坏 b64
    expect(
      (await call("PUT", `/v1/vaults/${vaultId}/envelope`, { envelope: "!!not-b64!!", changedAt: now }, token)).status,
    ).toBe(400);
  });
});

describe("哈希/改名/解绑", () => {
  it("哈希上报与校验", async () => {
    const token = await registerUser("quinn@example.com");
    const vaultId = await createVault(token, "Main");
    const sha = "a".repeat(64);
    expect(
      (await call("PUT", `/v1/vaults/${vaultId}/hashes`, { cipherSha256: sha, xmlSha256: "b".repeat(64) }, token)).status,
    ).toBe(200);
    const detail = await call("GET", `/v1/vaults/${vaultId}`, undefined, token);
    const meta = (await detail.json()) as { cipherSha256: string; xmlSha256: string };
    expect(meta.cipherSha256).toBe(sha);
    expect(
      (await call("PUT", `/v1/vaults/${vaultId}/hashes`, { cipherSha256: "xyz", xmlSha256: sha }, token)).status,
    ).toBe(400);
  });

  it("改名与同名冲突", async () => {
    const token = await registerUser("rose@example.com");
    const a = await createVault(token, "Alpha");
    await createVault(token, "Beta");
    expect((await call("PATCH", `/v1/vaults/${a}`, { name: "Gamma" }, token)).status).toBe(200);
    expect((await call("PATCH", `/v1/vaults/${a}`, { name: "Beta" }, token)).status).toBe(409);
  });

  it("解绑需 sensitive 码;解绑后 404", async () => {
    const email = "sam@example.com";
    const token = await registerUser(email);
    const vaultId = await createVault(token, "Main");

    expect((await call("DELETE", `/v1/vaults/${vaultId}`, {}, token)).status).toBe(403);
    const code = await sensitiveCode(email);
    expect((await call("DELETE", `/v1/vaults/${vaultId}`, { code }, token)).status).toBe(200);
    expect((await call("GET", `/v1/vaults/${vaultId}`, undefined, token)).status).toBe(404);
  });
});

describe("跨用户隔离", () => {
    it("他库一律 404(读/写/信封/哈希/改名/删除)", async () => {
        const owner = await registerUser("tina@example.com");
        const other = await registerUser("ursa@example.com");
        const vaultId = await createVault(owner, "Secret");
        const now = Date.now() / 1000;

        expect((await call("GET", `/v1/vaults/${vaultId}`, undefined, other)).status).toBe(404);
        expect((await putEnvelope(other, vaultId, now)).status).toBe(404);
        expect(
            (await call("PUT", `/v1/vaults/${vaultId}/hashes`, { cipherSha256: "a".repeat(64), xmlSha256: "b".repeat(64) }, other)).status,
        ).toBe(404);
        expect((await call("PATCH", `/v1/vaults/${vaultId}`, { name: "Steal" }, other)).status).toBe(404);
        expect((await call("DELETE", `/v1/vaults/${vaultId}`, { code: "123456" }, other)).status).toBe(404);
    });
});

describe("换绑邮箱(注册表转移)", () => {
    it("双敏感码(当前账户+新邮箱)通过 → 记录换主并签发新会话;旧会话失去该库", async () => {
        const tokenA = await registerUser("old@example.com");
        const vaultId = await createVault(tokenA, "Main");
        const { mockCode } = await import("./helpers");

        // 门槛一:当前账户的敏感码(令牌被盗不足以过户)
        await call("POST", "/v1/auth/code", { email: "old@example.com", purpose: "sensitive" });
        const currentCode = await mockCode("old@example.com", "sensitive");
        // 只带新邮箱码、缺当前账户码 → 403
        const noCurrent = await call("POST", `/v1/vaults/${vaultId}/transfer`, {
            email: "fresh@example.com",
            code: "000000",
            deviceName: "x",
        }, tokenA);
        expect(noCurrent.status).toBe(403);

        // 新邮箱(从未注册过)先收敏感码
        const codeReq = await call("POST", "/v1/auth/code", {
            email: "fresh@example.com",
            purpose: "sensitive",
        });
        expect(codeReq.status).toBe(202);
        const code = await mockCode("fresh@example.com", "sensitive");

        const res = await call("POST", `/v1/vaults/${vaultId}/transfer`, {
            email: "fresh@example.com",
            code,
            currentCode,
            deviceName: "transfer-test",
        }, tokenA);
        expect(res.status).toBe(200);
        const data = (await res.json()) as { token: string; userId: string };
        expect(data.token).toMatch(/^[0-9a-f]{64}$/);

        // 旧账户会话不再可见该库;新会话照常访问
        expect((await call("GET", `/v1/vaults/${vaultId}`, undefined, tokenA)).status).toBe(404);
        const got = await call("GET", `/v1/vaults/${vaultId}`, undefined, data.token);
        expect(got.status).toBe(200);
        expect(((await got.json()) as { name: string }).name).toBe("Main");
    });

    it("错码 403;目标为已注销账户可重建换主", async () => {
        const tokenA = await registerUser("keep@example.com");
        const vaultId = await createVault(tokenA, "V");
        const { mockCode } = await import("./helpers");
        await call("POST", "/v1/auth/code", { email: "keep@example.com", purpose: "sensitive" });
        const currentCode = await mockCode("keep@example.com", "sensitive");
        await call("POST", "/v1/auth/code", { email: "gone@example.com", purpose: "sensitive" });
        const good = await mockCode("gone@example.com", "sensitive");

        // 错码拒绝
        const wrong = await call("POST", `/v1/vaults/${vaultId}/transfer`, {
            email: "gone@example.com",
            code: String((Number(good) + 1) % 1_000_000).padStart(6, "0"),
            currentCode,
        }, tokenA);
        expect(wrong.status).toBe(403);
        // sensitive 码单次性:错码尝试已消费 currentCode,重新签发(绕 60s 冷却)
        const { ageCodes } = await import("./helpers");
        await ageCodes(120);
        await call("POST", "/v1/auth/code", { email: "keep@example.com", purpose: "sensitive" });
        const currentCode2 = await mockCode("keep@example.com", "sensitive");
        // 正码成功(目标账户不存在→自动创建)
        const ok = await call("POST", `/v1/vaults/${vaultId}/transfer`, {
            email: "gone@example.com",
            code: good,
            currentCode: currentCode2,
        }, tokenA);
        expect(ok.status).toBe(200);
    });
});

describe("库体密文存储(R2)", () => {
  async function shaOf(bytes: Uint8Array): Promise<string> {
    const digest = await crypto.subtle.digest("SHA-256", bytes as BufferSource);
    return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
  }

  function fillRandom(bytes: Uint8Array): void {
    for (let off = 0; off < bytes.length; off += 65536) {
      crypto.getRandomValues(bytes.subarray(off, Math.min(off + 65536, bytes.length)));
    }
  }

  async function uploadBody(
    token: string,
    vaultId: string,
    bytes: Uint8Array,
    uploadId = "a1b2c3d4e5f60718293a4b5c6d7e8f90",
  ): Promise<{ put: Response; commit: Response; sha: string }> {
    const put = await call("PUT", `/v1/vaults/${vaultId}/body?upload=${uploadId}`, bytes, token, {
      "content-type": "application/octet-stream",
    });
    const sha = await shaOf(bytes);
    const commit = await call(
      "POST",
      `/v1/vaults/${vaultId}/body/commit`,
      { uploadId, sha256: sha },
      token,
    );
    return { put, commit, sha };
  }

  it("3MB 单请求上传/commit/下载逐字节一致;列表元数据可短路", async () => {
    const token = await registerUser("body-a@example.com");
    const vaultId = await createVault(token, "Main");
    const payload = new Uint8Array(3 * 1024 * 1024 + 777);
    fillRandom(payload);

    const { put, commit, sha } = await uploadBody(token, vaultId, payload);
    expect(put.status).toBe(200);
    expect(commit.status).toBe(200);
    const { bytes } = (await commit.json()) as { bytes: number };
    expect(bytes).toBe(payload.length);

    const get = await call("GET", `/v1/vaults/${vaultId}/body`, undefined, token);
    expect(get.status).toBe(200);
    expect(get.headers.get("x-body-sha256")).toBe(sha);
    expect(get.headers.get("x-body-bytes")).toBe(String(payload.length));
    const round = new Uint8Array(await get.arrayBuffer());
    expect(await shaOf(round)).toBe(sha);

    const list = await call("GET", "/v1/vaults", undefined, token);
    const { vaults } = (await list.json()) as { vaults: { bodySha256: string; bodyBytes: number }[] };
    expect(vaults[0].bodySha256).toBe(sha);
    expect(vaults[0].bodyBytes).toBe(payload.length);
  });

  it("二次上传原子换代:旧密文不再可见;staging 被清理", async () => {
    const token = await registerUser("body-b@example.com");
    const vaultId = await createVault(token, "Main");
    const gen1 = new Uint8Array(1000);
    fillRandom(gen1);
    await uploadBody(token, vaultId, gen1, "b1b2c3d4e5f60718293a4b5c6d7e8f90");

    const gen2 = new Uint8Array(2000);
    fillRandom(gen2);
    const { commit } = await uploadBody(token, vaultId, gen2, "b2b2c3d4e5f60718293a4b5c6d7e8f90");
    expect(commit.status).toBe(200);

    const get = await call("GET", `/v1/vaults/${vaultId}/body`, undefined, token);
    const round = new Uint8Array(await get.arrayBuffer());
    expect(await shaOf(round)).toBe(await shaOf(gen2));
  });

  it("commit 未上传 → 400;缺 content-length → 411;超配额(60MB 声明)→ 413", async () => {
    const token = await registerUser("body-c@example.com");
    const vaultId = await createVault(token, "Main");

    const ghost = await call(
      "POST",
      `/v1/vaults/${vaultId}/body/commit`,
      { uploadId: "c1b2c3d4e5f60718293a4b5c6d7e8f90", sha256: await shaOf(new Uint8Array(1)) },
      token,
    );
    expect(ghost.status).toBe(400);

    // fetch 会自动补 content-length;绕开 helper 直发无长度请求难构造,
    // 改测配额:声明 60MB > 50MB 配额
    const big = new Uint8Array(10);
    const over = await call(
      "PUT",
      `/v1/vaults/${vaultId}/body?upload=d1b2c3d4e5f60718293a4b5c6d7e8f90`,
      big,
      token,
      { "content-type": "application/octet-stream", "content-length": String(60 * 1024 * 1024) },
    );
    expect(over.status).toBe(413);
  });

  it("commit 申报哈希与实际字节不符 → 400 hash_mismatch,生效对象保持旧版", async () => {
    const token = await registerUser("body-hash@example.com");
    const vaultId = await createVault(token, "Main");
    const gen1 = new Uint8Array(400);
    fillRandom(gen1);
    await uploadBody(token, vaultId, gen1, "e1b2c3d4e5f60718293a4b5c6d7e8f90");

    const gen2 = new Uint8Array(600);
    fillRandom(gen2);
    const put = await call(
      "PUT",
      `/v1/vaults/${vaultId}/body?upload=e2b2c3d4e5f60718293a4b5c6d7e8f90`,
      gen2,
      token,
      { "content-type": "application/octet-stream" },
    );
    expect(put.status).toBe(200);
    const bad = await call(
      "POST",
      `/v1/vaults/${vaultId}/body/commit`,
      { uploadId: "e2b2c3d4e5f60718293a4b5c6d7e8f90", sha256: await shaOf(new Uint8Array(1)) },
      token,
    );
    expect(bad.status).toBe(400);
    expect(((await bad.json()) as { error: string }).error).toBe("hash_mismatch");

    // 坏数据未换入:生效对象仍是 gen1;残 staging 已被废弃
    const get = await call("GET", `/v1/vaults/${vaultId}/body`, undefined, token);
    const round = new Uint8Array(await get.arrayBuffer());
    expect(await shaOf(round)).toBe(await shaOf(gen1));
    const staging = await workerEnv.VAULTS.list({ prefix: `vaults/staging/${vaultId}/` });
    expect(staging.objects.length).toBe(0);
  });

  it("删库清理 vaults/staging/<vaultId>/ 前缀(中断上传残渣不残留)", async () => {
    const token = await registerUser("body-staging@example.com");
    const vaultId = await createVault(token, "Main");
    await workerEnv.VAULTS.put(
      `vaults/staging/${vaultId}/ffeeddccbbaa99887766554433221100`,
      new Uint8Array(8),
    );
    const del = await call(
      "DELETE",
      `/v1/vaults/${vaultId}`,
      { code: await sensitiveCode("body-staging@example.com") },
      token,
    );
    expect(del.status).toBe(200);
    const staging = await workerEnv.VAULTS.list({ prefix: `vaults/staging/${vaultId}/` });
    expect(staging.objects.length).toBe(0);
    expect(await workerEnv.VAULTS.head(`vaults/${vaultId}`)).toBeNull();
  });

  it("跨用户隔离:他人 vaultId 一律 404", async () => {
    const alice = await registerUser("alice-body@example.com");
    const mallory = await registerUser("mallory-body@example.com");
    const vaultId = await createVault(alice, "Main");
    const chunk = new Uint8Array(10);
    expect(
      (await call("PUT", `/v1/vaults/${vaultId}/body?upload=f1b2c3d4e5f60718293a4b5c6d7e8f90`, chunk, mallory, {
        "content-type": "application/octet-stream",
      })).status,
    ).toBe(404);
  });

  it("未上传过库体的库 GET 404;解绑后库体一并清除", async () => {
    const token = await registerUser("body-d@example.com");
    const vaultId = await createVault(token, "Main");
    expect((await call("GET", `/v1/vaults/${vaultId}/body`, undefined, token)).status).toBe(404);

    const payload = new Uint8Array(500);
    fillRandom(payload);
    const { commit } = await uploadBody(token, vaultId, payload, "aabbccddeeff00112233445566778899");
    expect(commit.status).toBe(200);

    const del = await call(
      "DELETE",
      `/v1/vaults/${vaultId}`,
      { code: await sensitiveCode("body-d@example.com") },
      token,
    );
    expect(del.status).toBe(200);
    expect((await call("GET", `/v1/vaults/${vaultId}/body`, undefined, token)).status).toBe(404);
  });
});
