// 跨端解密链对齐测试:fixture 由 Swift Core(真实 PBKDF2/AES-GCM 实现与字节布局)
// 生成——TS 侧必须用同一密码解开信封、还原库密钥、解出本体 XML。
// XML→条目映射依赖 DOMParser(扩展页环境),node 下仅验证解密产物内容。

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import assert from "node:assert/strict";
import { decryptBody, envelopeChangedAt, unwrapEnvelope, VaultCryptoError } from "../dist/index.js";

const here = fileURLToPath(new URL(".", import.meta.url));
const fixture = JSON.parse(readFileSync(`${here}fixtures/vault-vector.json`, "utf8"));

const envelope = Uint8Array.from(atob(fixture.envelope), (c) => c.charCodeAt(0));
const body = Uint8Array.from(atob(fixture.body), (c) => c.charCodeAt(0));
const expectedVek = Uint8Array.from(atob(fixture.vek), (c) => c.charCodeAt(0));

test("unwrapEnvelope: Swift 生成的信封 + 正确密码 → 还原同一库密钥", async () => {
    const vek = await unwrapEnvelope(envelope, fixture.password);
    assert.deepEqual([...vek], [...expectedVek]);
});

test("unwrapEnvelope: 错误密码 → wrong_password(不泄露其他信息)", async () => {
    await assert.rejects(
        () => unwrapEnvelope(envelope, "definitely-wrong"),
        (error) => error instanceof VaultCryptoError && error.message === "wrong_password",
    );
});

test("unwrapEnvelope: 非信封字节 → not_a_key_envelope", async () => {
    await assert.rejects(
        () => unwrapEnvelope(new Uint8Array(64), fixture.password),
        (error) => error instanceof VaultCryptoError && error.message === "not_a_key_envelope",
    );
});

test("decryptBody: 库密钥解本体 → XML 明文,条目字段逐项可见", async () => {
    const xml = await decryptBody(body, expectedVek);
    assert.ok(xml.startsWith("<?xml"), "XML prolog present");
    assert.ok(xml.includes('title="GitHub"'), "card title round-trips");
    assert.ok(xml.includes("octocat"), "login value round-trips");
    assert.ok(xml.includes("hunter2-example"), "password value round-trips");
    assert.ok(xml.includes('type="website"'), "website field type round-trips");
    assert.ok(xml.includes('title="Bank"'), "trashed card still serialized (filter happens at parse)");
});

test("decryptBody: 错误库密钥 → vault_key_mismatch", async () => {
    const wrongKey = new Uint8Array(32).fill(0xab);
    await assert.rejects(
        () => decryptBody(body, wrongKey),
        (error) => error instanceof VaultCryptoError && error.message === "vault_key_mismatch",
    );
});

test("envelopeChangedAt: Swift 写入的时间戳按 f64 LE 读回", () => {
    // wrapVaultKey 默认 changedAt=Date(),fixture 生成时刻即期望值——
    // 这里只验证可读且在 2026 年合理范围(结构性校验,不做精确断言)
    const changedAt = envelopeChangedAt(envelope);
    assert.ok(changedAt !== null && changedAt > 1_700_000_000 && changedAt < 4_100_000_000);
});
