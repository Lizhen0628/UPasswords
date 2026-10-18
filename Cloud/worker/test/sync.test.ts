// 行级同步集成测试:CAS 上行、冲突、缺席即删除、游标拉取、全量分页、
// rekey(写锁/换入/revision+1/漂移防护)、附件、换绑。

import { describe, expect, it } from "vitest";
import {
  b64,
  call,
  createVault,
  fakeEnvelopeB64,
  registerUser,
  sensitiveCode,
  workerEnv,
} from "./helpers";

interface ItemResult {
  uuid: string;
  status: "ok" | "conflict" | "not_found";
  revision?: number;
  current?: { revision: number; bodyB64: string };
  deletedAt?: number;
}

async function postItems(
  env: ReturnType<typeof workerEnv>,
  token: string,
  vaultId: string,
  items: Record<string, unknown>[],
): Promise<{ status: number; results: ItemResult[] }> {
  const res = await call(env, "POST", `/v2/vaults/${vaultId}/items`, { token, body: { items } });
  const data = (await res.json()) as { results: ItemResult[] };
  return { status: res.status, results: data.results ?? [] };
}

describe("row sync", () => {
  it("create vault carries envelope; get returns it round-trip", async () => {
    const env = workerEnv();
    const { token } = await registerUser(env, "env1@example.com");
    const create = await call(env, "POST", "/v2/vaults", {
      token,
      body: { name: "Main", envelope: fakeEnvelopeB64(7) },
    });
    expect(create.status).toBe(201);
    const { vaultId } = (await create.json()) as { vaultId: string };
    const get = await call(env, "GET", `/v2/vaults/${vaultId}`, { token });
    const data = (await get.json()) as { envelope: string | null; hasEnvelope: boolean };
    expect(data.hasEnvelope).toBe(true);
    expect(data.envelope).toBe(fakeEnvelopeB64(7));
  });

  it("CAS insert/update/conflict cycle with changes feed", async () => {
    const env = workerEnv();
    const { token } = await registerUser(env, "cas@example.com");
    const vaultId = await createVault(env, token);
    const uuid = crypto.randomUUID();

    const insert = await postItems(env, token, vaultId, [
      { uuid, kind: 1, op: "upsert", baseRevision: 0, bodyB64: b64("v1"), modifiedMs: 100 },
    ]);
    expect(insert.status).toBe(200);
    expect(insert.results[0]).toMatchObject({ uuid, status: "ok", revision: 1 });

    const update = await postItems(env, token, vaultId, [
      { uuid, kind: 1, op: "upsert", baseRevision: 1, bodyB64: b64("v2"), modifiedMs: 200 },
    ]);
    expect(update.results[0]).toMatchObject({ status: "ok", revision: 2 });

    // 陈旧 base 撞冲突,返回现行行
    const stale = await postItems(env, token, vaultId, [
      { uuid, kind: 1, op: "upsert", baseRevision: 1, bodyB64: b64("v2x"), modifiedMs: 300 },
    ]);
    expect(stale.results[0].status).toBe("conflict");
    expect(stale.results[0].current?.revision).toBe(2);
    expect(stale.results[0].current?.bodyB64).toBe(b64("v2"));

    // 变更日志:两条 upsert,均为现行 body
    const changes = await call(env, "GET", `/v2/vaults/${vaultId}/changes?since=0`, { token });
    const feed = (await changes.json()) as {
      headSeq: number;
      changes: { seq: number; op: string; bodyB64?: string; revision: number }[];
    };
    expect(feed.changes).toHaveLength(2);
    expect(feed.changes.every((c) => c.op === "upsert" && c.bodyB64 === b64("v2"))).toBe(true);
    const headSeq = feed.headSeq;
    expect(headSeq).toBeGreaterThan(0);

    // seq 轮询端点
    const seq = await call(env, "GET", `/v2/vaults/${vaultId}/seq`, { token });
    expect(((await seq.json()) as { headSeq: number }).headSeq).toBe(headSeq);

    // since=headSeq → 空
    const none = await call(env, "GET", `/v2/vaults/${vaultId}/changes?since=${headSeq}`, { token });
    const empty = (await none.json()) as { changes: unknown[] };
    expect(empty.changes).toHaveLength(0);
  });

  /// Swift 客户端 UUID().uuidString 为大写:校验须大小写不敏感,且归一化
  /// 小写入库——同一条目以大小写两种写法上行必须命中同一行(CAS 生效、
  /// 变更日志回读 uuid 为小写),否则大小写变体会存成两条独立行。
  it("accepts uppercase uuid from Swift clients and normalizes to one row", async () => {
    const env = workerEnv();
    const { token } = await registerUser(env, "upper@example.com");
    const vaultId = await createVault(env, token);
    const uuidUpper = crypto.randomUUID().toUpperCase();

    const insert = await postItems(env, token, vaultId, [
      { uuid: uuidUpper, kind: 1, op: "upsert", baseRevision: 0, bodyB64: b64("s1"), modifiedMs: 10 },
    ]);
    expect(insert.status).toBe(200);
    expect(insert.results[0].status).toBe("ok");

    // 同一 uuid 换小写写法更新:CAS 命中同一行(revision 2),绝不插入第二行
    const update = await postItems(env, token, vaultId, [
      { uuid: uuidUpper.toLowerCase(), kind: 1, op: "upsert", baseRevision: 1, bodyB64: b64("s2"), modifiedMs: 20 },
    ]);
    expect(update.results[0]).toMatchObject({ status: "ok", revision: 2 });

    const list = await call(env, "GET", `/v2/vaults/${vaultId}/items`, { token });
    const data = (await list.json()) as { items: { uuid: string }[] };
    expect(data.items).toHaveLength(1);
    expect(data.items[0].uuid).toBe(uuidUpper.toLowerCase());
  });

  it("delete removes row, feeds purge marker; late push hits not_found with evidence", async () => {
    const env = workerEnv();
    const { token } = await registerUser(env, "del@example.com");
    const vaultId = await createVault(env, token);
    const uuid = crypto.randomUUID();
    await postItems(env, token, vaultId, [
      { uuid, kind: 1, op: "upsert", baseRevision: 0, bodyB64: b64("d1"), modifiedMs: 1 },
    ]);

    const del = await postItems(env, token, vaultId, [
      { uuid, kind: 1, op: "delete", baseRevision: 1, modifiedMs: 2 },
    ]);
    expect(del.results[0]).toMatchObject({ status: "ok" });

    // 幂等:再删一次照样 ok
    const again = await postItems(env, token, vaultId, [
      { uuid, kind: 1, op: "delete", baseRevision: 2, modifiedMs: 3 },
    ]);
    expect(again.results[0].status).toBe("ok");

    // 变更日志:upsert(行已删 → deleted 标记)+ purge
    const feed = (await (
      await call(env, "GET", `/v2/vaults/${vaultId}/changes?since=0`, { token })
    ).json()) as { changes: { op: string; deleted?: boolean }[] };
    expect(feed.changes[0].deleted).toBe(true);
    expect(feed.changes[1].op).toBe("purge");

    // 离线对端迟到推送旧条目:baseRevision>0 且行不存在 → not_found + 删除佐证
    const late = await postItems(env, token, vaultId, [
      { uuid, kind: 1, op: "upsert", baseRevision: 1, bodyB64: b64("late"), modifiedMs: 9 },
    ]);
    expect(late.results[0].status).toBe("not_found");
    expect(late.results[0].deletedAt).toBeGreaterThan(0);

    // 全量列表为空,item_count 归零
    const list = (await (
      await call(env, "GET", `/v2/vaults/${vaultId}/items`, { token })
    ).json()) as { items: unknown[] };
    expect(list.items).toHaveLength(0);
    const meta = (await (
      await call(env, "GET", `/v2/vaults/${vaultId}`, { token })
    ).json()) as { itemCount: number };
    expect(meta.itemCount).toBe(0);
  });

  it("full listing paginates with keyset cursor", async () => {
    const env = workerEnv();
    const { token } = await registerUser(env, "page@example.com");
    const vaultId = await createVault(env, token);
    const batch = [1, 2, 3].map((i) => ({
      uuid: crypto.randomUUID(),
      kind: 1,
      op: "upsert",
      baseRevision: 0,
      bodyB64: b64(`p${i}`),
      modifiedMs: i,
    }));
    await postItems(env, token, vaultId, batch);

    const page1 = (await (
      await call(env, "GET", `/v2/vaults/${vaultId}/items?limit=2`, { token })
    ).json()) as { items: { uuid: string }[]; nextCursor: { ms: number; uuid: string } | null };
    expect(page1.items).toHaveLength(2);
    expect(page1.nextCursor).not.toBeNull();
    const c = page1.nextCursor!;
    const page2 = (await (
      await call(
        env,
        "GET",
        `/v2/vaults/${vaultId}/items?limit=2&cursorMs=${c.ms}&cursorUuid=${c.uuid}`,
        { token },
      )
    ).json()) as { items: { uuid: string }[]; nextCursor: null };
    expect(page2.items).toHaveLength(1);
    expect(page2.nextCursor).toBeNull();
    const all = [...page1.items.map((i) => i.uuid), ...page2.items.map((i) => i.uuid)].sort();
    expect(all).toEqual(batch.map((b) => b.uuid).sort());
  });

  it("rekey: write lock, chunk/commit swap with revision bump, stale guard, abort", async () => {
    const env = workerEnv();
    const { token } = await registerUser(env, "rekey@example.com");
    const vaultId = await createVault(env, token);
    const u1 = crypto.randomUUID();
    const u2 = crypto.randomUUID();
    await postItems(env, token, vaultId, [
      { uuid: u1, kind: 1, op: "upsert", baseRevision: 0, bodyB64: b64("r1"), modifiedMs: 1 },
      { uuid: u2, kind: 2, op: "upsert", baseRevision: 0, bodyB64: b64("r2"), modifiedMs: 1 },
    ]);

    // begin:申报 2 条目 0 附件
    const begin = await call(env, "POST", `/v2/vaults/${vaultId}/rekey/begin`, {
      token,
      body: { envelope: fakeEnvelopeB64(9), itemCount: 2, dekCount: 0 },
    });
    expect(begin.status).toBe(201);
    const { rekeyId } = (await begin.json()) as { rekeyId: string };

    // 写锁生效:普通条目写 409
    const locked = await postItems(env, token, vaultId, [
      { uuid: u1, kind: 1, op: "upsert", baseRevision: 1, bodyB64: b64("x"), modifiedMs: 2 },
    ]);
    expect(locked.status).toBe(409);

    // 计数不齐 → rekey_incomplete
    const early = await call(env, "POST", `/v2/vaults/${vaultId}/rekey/${rekeyId}/commit`, {
      token,
      body: {},
    });
    expect(early.status).toBe(409);

    // chunk 分块上传新密文(重传同 uuid 幂等)
    const n1 = b64("n1");
    const n2 = b64("n2");
    const chunk = await call(env, "POST", `/v2/vaults/${vaultId}/rekey/${rekeyId}/chunk`, {
      token,
      body: { items: [{ uuid: u1, bodyB64: n1, sha256: await sha(n1) }] },
    });
    expect(chunk.status).toBe(200);
    expect(((await chunk.json()) as { itemStaged: number }).itemStaged).toBe(1);
    const chunk2 = await call(env, "POST", `/v2/vaults/${vaultId}/rekey/${rekeyId}/chunk`, {
      token,
      body: { items: [{ uuid: u2, bodyB64: n2, sha256: await sha(n2) }] },
    });
    expect(((await chunk2.json()) as { itemStaged: number }).itemStaged).toBe(2);

    // commit:换入 + revision 全部 +1 + 信封切换 + op=rekey
    const commit = await call(env, "POST", `/v2/vaults/${vaultId}/rekey/${rekeyId}/commit`, {
      token,
      body: {},
    });
    expect(commit.status).toBe(200);
    expect(((await commit.json()) as { passwordVersion: number }).passwordVersion).toBe(2);

    const detail = (await (
      await call(env, "GET", `/v2/vaults/${vaultId}`, { token })
    ).json()) as { envelope: string; passwordVersion: number };
    expect(detail.passwordVersion).toBe(2);
    expect(detail.envelope).toBe(fakeEnvelopeB64(9));

    const feed = (await (
      await call(env, "GET", `/v2/vaults/${vaultId}/changes?since=0`, { token })
    ).json()) as { changes: { uuid: string; op: string; bodyB64?: string; revision?: number }[] };
    const rekeyEntry = feed.changes.find((c) => c.op === "rekey");
    expect(rekeyEntry).toBeDefined();
    // 新密文 + revision 递增(rekey 换入把两行都推到 revision 2)
    const live = feed.changes.filter((c) => c.op === "upsert" && (c.uuid === u1 || c.uuid === u2));
    expect(live).toHaveLength(2);
    expect(live.every((c) => c.bodyB64 === b64("n1") || c.bodyB64 === b64("n2"))).toBe(true);
    expect(live.every((c) => (c.revision ?? 0) === 2)).toBe(true);

    // rekey 后写锁解除,新写入正常
    const after = await postItems(env, token, vaultId, [
      { uuid: crypto.randomUUID(), kind: 1, op: "upsert", baseRevision: 0, bodyB64: b64("z"), modifiedMs: 3 },
    ]);
    expect(after.results[0].status).toBe("ok");

    // 漂移防护:begin 申报 5 条(实际 3)→ commit 撞 rekey_stale → abort 后恢复
    const begin2 = await call(env, "POST", `/v2/vaults/${vaultId}/rekey/begin`, {
      token,
      body: { envelope: fakeEnvelopeB64(11), itemCount: 5, dekCount: 0 },
    });
    const { rekeyId: rid2 } = (await begin2.json()) as { rekeyId: string };
    for (const b of [b64("a1"), b64("a2"), b64("a3"), b64("a4"), b64("a5")]) {
      await call(env, "POST", `/v2/vaults/${vaultId}/rekey/${rid2}/chunk`, {
        token,
        body: { items: [{ uuid: crypto.randomUUID(), bodyB64: b, sha256: await sha(b) }] },
      });
    }
    const staleCommit = await call(env, "POST", `/v2/vaults/${vaultId}/rekey/${rid2}/commit`, {
      token,
      body: {},
    });
    expect(((await staleCommit.json()) as { error: string }).error).toBe("rekey_stale");
    const abort = await call(env, "DELETE", `/v2/vaults/${vaultId}/rekey/${rid2}`, { token });
    expect(abort.status).toBe(200);
    const writable = await postItems(env, token, vaultId, [
      { uuid: crypto.randomUUID(), kind: 1, op: "upsert", baseRevision: 0, bodyB64: b64("w"), modifiedMs: 4 },
    ]);
    expect(writable.results[0].status).toBe("ok");
    // abort 未切换信封
    const detail2 = (await (
      await call(env, "GET", `/v2/vaults/${vaultId}`, { token })
    ).json()) as { envelope: string };
    expect(detail2.envelope).toBe(fakeEnvelopeB64(9));
  });

  it("attachments: staging→commit→get→delete", async () => {
    const env = workerEnv();
    const { token } = await registerUser(env, "att@example.com");
    const vaultId = await createVault(env, token);
    const attachUuid = crypto.randomUUID();
    const cardUuid = crypto.randomUUID();
    const uploadId = "ab".repeat(16);
    const blob = new TextEncoder().encode("attachment-ciphertext-bytes");

    const put = await call(env, "PUT", `/v2/vaults/${vaultId}/attachments/${attachUuid}?upload=${uploadId}`, {
      token,
      raw: blob,
    });
    expect(put.status).toBe(200);

    const badCommit = await call(env, "POST", `/v2/vaults/${vaultId}/attachments/${attachUuid}/commit`, {
      token,
      body: { uploadId, sha256: "0".repeat(64), cardUuid, dekWrapped: b64("dek") },
    });
    expect(badCommit.status).toBe(400);

    const commit = await call(env, "POST", `/v2/vaults/${vaultId}/attachments/${attachUuid}/commit`, {
      token,
      body: { uploadId, sha256: await shaBytes(blob), cardUuid, dekWrapped: b64("dek-wrapped-32-bytes-payload!!") },
    });
    expect(commit.status).toBe(200);

    const get = await call(env, "GET", `/v2/vaults/${vaultId}/attachments/${attachUuid}`, { token });
    expect(get.status).toBe(200);
    expect(get.headers.get("x-sha256")).toBe(await shaBytes(blob));
    expect(new Uint8Array(await get.arrayBuffer())).toEqual(blob);

    // 配额核算随删除回收
    const meta1 = (await (
      await call(env, "GET", `/v2/vaults/${vaultId}`, { token })
    ).json()) as { attachBytes: number };
    expect(meta1.attachBytes).toBe(blob.length);
    const del = await call(env, "DELETE", `/v2/vaults/${vaultId}/attachments/${attachUuid}`, { token });
    expect(del.status).toBe(200);
    const meta2 = (await (
      await call(env, "GET", `/v2/vaults/${vaultId}`, { token })
    ).json()) as { attachBytes: number };
    expect(meta2.attachBytes).toBe(0);
    const gone = await call(env, "GET", `/v2/vaults/${vaultId}/attachments/${attachUuid}`, { token });
    expect(gone.status).toBe(404);
  });

  it("transfer moves vault to a new account with dual sensitive codes", async () => {
    const env = workerEnv();
    const currentEmail = "from@example.com";
    const targetEmail = "to@example.com";
    const { token } = await registerUser(env, currentEmail);
    const vaultId = await createVault(env, token, "Gift");
    await postItems(env, token, vaultId, [
      { uuid: crypto.randomUUID(), kind: 1, op: "upsert", baseRevision: 0, bodyB64: b64("t1"), modifiedMs: 1 },
    ]);

    const currentCode = await sensitiveCode(env, currentEmail);
    const targetCode = await sensitiveCode(env, targetEmail);
    const transfer = await call(env, "POST", `/v2/vaults/${vaultId}/transfer`, {
      token,
      body: { email: targetEmail, code: targetCode, currentCode, deviceName: "new-owner" },
    });
    expect(transfer.status).toBe(200);
    const newAuth = (await transfer.json()) as { token: string; userId: string };

    // 旧账户看不到,新账户拿到完整数据(信封随行)
    const oldList = (await (
      await call(env, "GET", "/v2/vaults", { token })
    ).json()) as { vaults: unknown[] };
    expect(oldList.vaults).toHaveLength(0);
    const detail = (await (
      await call(env, "GET", `/v2/vaults/${vaultId}`, { token: newAuth.token })
    ).json()) as { name: string; hasEnvelope: boolean; itemCount: number };
    expect(detail.name).toBe("Gift");
    expect(detail.hasEnvelope).toBe(true);
    expect(detail.itemCount).toBe(1);
  });
});

async function sha(bodyB64: string): Promise<string> {
  const bytes = Uint8Array.from(atob(bodyB64), (c) => c.charCodeAt(0));
  return shaBytes(bytes);
}

async function shaBytes(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
