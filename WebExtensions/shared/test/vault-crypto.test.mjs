// 跨端解密链对齐测试:fixture 由 Swift Core(真实 PBKDF2/AES-GCM 实现与字节布局)
// 生成——TS 侧必须用同一密码解开信封、还原库密钥、解出本体 XML。
// XML→条目映射依赖 DOMParser(扩展页环境),node 下仅验证解密产物内容。

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import assert from "node:assert/strict";
import { decryptBody, decryptItemBody, encryptBody, envelopeChangedAt, fragmentsToXml, unwrapEnvelope, VaultCryptoError, wrapEnvelope } from "../dist/index.js";

const here = fileURLToPath(new URL(".", import.meta.url));
const fixture = JSON.parse(readFileSync(`${here}fixtures/vault-vector.json`, "utf8"));
const backupFixture = JSON.parse(readFileSync(
    new URL("../../../Contracts/test-vectors/browser-encrypted-snapshot.json", import.meta.url), "utf8",
));
// 行级条目向量由 Persistence 的 ItemVectorTests 生成(RowSyncCipher 真实密文)
const itemFixture = JSON.parse(readFileSync(`${here}fixtures/item-vector.json`, "utf8"));

const envelope = Uint8Array.from(atob(fixture.envelope), (c) => c.charCodeAt(0));
const body = Uint8Array.from(atob(fixture.body), (c) => c.charCodeAt(0));
const expectedVek = Uint8Array.from(atob(fixture.vek), (c) => c.charCodeAt(0));
const itemBody = Uint8Array.from(atob(itemFixture.body), (c) => c.charCodeAt(0));
const itemVek = Uint8Array.from(atob(itemFixture.vek), (c) => c.charCodeAt(0));

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

test("encryptBody: exported snapshot uses the native UPWDB2 header and round-trips", async () => {
    const xml = "<?xml version=\"1.0\"?><database><card id=\"x\"/></database>";
    const body = await encryptBody(xml, expectedVek);
    assert.equal(new TextDecoder().decode(body.slice(0, 8)), "UPWDB2\0\0");
    assert.equal(new DataView(body.buffer, body.byteOffset, body.byteLength).getUint32(8, true), 2);
    assert.equal(await decryptBody(body, expectedVek), xml);
});

test("browser snapshot vector is readable by the shared native container contract", async () => {
    const vek = Uint8Array.from(atob(backupFixture.vaultKey), character => character.charCodeAt(0));
    const body = Uint8Array.from(atob(backupFixture.body), character => character.charCodeAt(0));
    assert.equal(backupFixture.format, "UPWDB2");
    assert.equal(await decryptBody(body, vek), backupFixture.xml);
});

test("envelopeChangedAt: Swift 写入的时间戳按 f64 LE 读回", () => {
    // wrapVaultKey 默认 changedAt=Date(),fixture 生成时刻即期望值——
    // 这里只验证可读且在 2026 年合理范围(结构性校验,不做精确断言)
    const changedAt = envelopeChangedAt(envelope);
    assert.ok(changedAt !== null && changedAt > 1_700_000_000 && changedAt < 4_100_000_000);
});

test("decryptItemBody: Swift RowSyncCipher 密文 + 服务端小写 uuid → 原文片段", async () => {
    // uuid 用服务端归一化形态(小写)——实现须内部还原大写作 AAD
    const xml = await decryptItemBody(itemBody, itemVek, itemFixture.uuid);
    assert.equal(xml, itemFixture.fragment);
    assert.ok(xml.trim().startsWith("<card "), "单条目片段(缩进由序列化器决定,无 prolog/根元素)");
});

test("decryptItemBody: AAD 绑定 uuid——换 uuid 解不开(行搬运防护)", async () => {
    const other = "00000000-0000-4000-8000-000000000000";
    await assert.rejects(
        () => decryptItemBody(itemBody, itemVek, other),
        (error) => error instanceof VaultCryptoError && error.message === "item_decrypt_failed",
    );
});

test("decryptItemBody: 错误库密钥 → item_decrypt_failed", async () => {
    const wrongKey = new Uint8Array(32).fill(0xcd);
    await assert.rejects(
        () => decryptItemBody(itemBody, wrongKey, itemFixture.uuid),
        (error) => error instanceof VaultCryptoError && error.message === "item_decrypt_failed",
    );
});

test("wrapEnvelope: 布局 100B + 与 unwrapEnvelope 往返一致(建库用)", async () => {
    const { envelope, vek } = await wrapEnvelope("e2e-wrap-pass");
    assert.equal(envelope.length, 100);
    // 布局:UPWKEY1 magic + 600k 迭代 + changedAt 为 epoch 秒
    assert.equal(String.fromCharCode(...envelope.slice(0, 7)), "UPWKEY1");
    const iter = new DataView(envelope.buffer, envelope.byteOffset + 12, 4).getUint32(0, true);
    assert.equal(iter, 600_000);
    const changedAt = envelopeChangedAt(envelope);
    assert.ok(changedAt !== null && changedAt > 1_700_000_000 && changedAt < 4_100_000_000);
    // 往返:同密码解出同一库密钥;错密码拒绝
    const unwrapped = await unwrapEnvelope(envelope, "e2e-wrap-pass");
    assert.deepEqual([...unwrapped], [...vek]);
    await assert.rejects(() => unwrapEnvelope(envelope, "wrong"), (e) => e.message === "wrong_password");
});

test("fragmentsToXml: 片段拼成可解析文档(标签包裹,card 可查询)", () => {
    const doc = fragmentsToXml([itemFixture.fragment, itemFixture.fragment]);
    assert.ok(doc.startsWith("<database>") && doc.endsWith("</database>"));
    assert.equal(doc.split("<card ").length - 1, 2);
});
