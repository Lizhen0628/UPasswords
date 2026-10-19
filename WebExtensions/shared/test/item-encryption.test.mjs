import { test } from "node:test";
import assert from "node:assert/strict";
import { encryptItemBody, decryptItemBody, VaultCryptoError } from "../dist/index.js";

const uuid = "abcdefab-1234-4abc-8def-0123456789ab";
const xml = `<card id="${uuid}" title="测试 &amp; notes"><note>line 1\nline 2</note></card>`;

test("encryptItemBody: combined nonce12 + ciphertext + tag16 roundtrips Unicode XML", async () => {
    const vek = crypto.getRandomValues(new Uint8Array(32));
    const originalKey = vek.slice();
    const first = await encryptItemBody(xml, vek, uuid);
    const second = await encryptItemBody(xml, vek, uuid.toUpperCase());
    assert.equal(first.length, new TextEncoder().encode(xml).length + 12 + 16);
    assert.notDeepEqual(first.slice(0, 12), second.slice(0, 12));
    assert.equal(await decryptItemBody(first, vek, uuid.toUpperCase()), xml);
    assert.equal(await decryptItemBody(second, vek, uuid), xml);
    assert.deepEqual(vek, originalKey, "Caller retains responsibility for clearing its key");
    // Independent decrypt pins the AAD representation rather than relying solely on paired helpers.
    const key = await crypto.subtle.importKey("raw", vek, "AES-GCM", false, ["decrypt"]);
    const clear = await crypto.subtle.decrypt({ name: "AES-GCM", iv: first.slice(0, 12),
        additionalData: new TextEncoder().encode(uuid.toUpperCase()) }, key, first.slice(12));
    assert.equal(new TextDecoder().decode(clear), xml);
    await assert.rejects(() => crypto.subtle.decrypt({ name: "AES-GCM", iv: first.slice(0, 12),
        additionalData: new TextEncoder().encode(uuid) }, key, first.slice(12)));
});

test("encryptItemBody: authentication binds UUID, key and ciphertext", async () => {
    const vek = new Uint8Array(32).fill(13);
    const body = await encryptItemBody(xml, vek, uuid);
    await assert.rejects(() => decryptItemBody(body, vek, "00000000-0000-4000-8000-000000000000"));
    await assert.rejects(() => decryptItemBody(body, new Uint8Array(32).fill(14), uuid));
    body[body.length - 1] ^= 1;
    await assert.rejects(() => decryptItemBody(body, vek, uuid));
});

test("encryptItemBody: refuses malformed identities and non-256-bit vault keys", async () => {
    const safeError = (error) => error instanceof VaultCryptoError && error.message === "item_encrypt_failed";
    for (const id of ["", "not-a-uuid", `{${uuid}}`, uuid.replaceAll("-", ""), ` ${uuid}`]) {
        await assert.rejects(() => encryptItemBody(xml, new Uint8Array(32), id), safeError);
    }
    for (const length of [0, 16, 24, 31, 33]) {
        await assert.rejects(() => encryptItemBody(xml, new Uint8Array(length), uuid), safeError);
    }
});
