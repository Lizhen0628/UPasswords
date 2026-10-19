import { test } from "node:test";
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";
import { projectVaultFragment, VaultCryptoError } from "../dist/index.js";

const dom = new JSDOM("");
globalThis.DOMParser = dom.window.DOMParser;
const uuid = "12345678-abcd-1234-abcd-123456789abc";
const fragment = (xml, extra = {}) => ({ uuid, xml, kind: 1, revision: 3, modifiedMs: 1000, ...extra });
const rejected = value => assert.throws(() => projectVaultFragment(value), VaultCryptoError);

test("cached projection preserves source revision and decodes the card fields", () => {
    const xml = `<card id="${uuid.toUpperCase()}" title="Work"><field name="User" type="login">Alice &amp; Bob</field><field type="website">https://example.com</field></card>`;
    const item = projectVaultFragment(fragment(xml));
    assert.equal(item.title, "Work");
    assert.equal(item.fields[0].value, "Alice & Bob");
    assert.equal(item.host, "https://example.com");
    assert.deepEqual(item.source, { xml, revision: 3 });
});

test("cached labels and inactive cards remain verified but are not fill candidates", () => {
    assert.equal(projectVaultFragment(fragment(`<label id="${uuid}" name="Work"/>`, { kind: 2 })), null);
    for (const attribute of ["trashed", "archived", "template"]) {
        assert.equal(projectVaultFragment(fragment(`<card id="${uuid}" ${attribute}="true"/>`)), null);
        rejected(fragment(`<card id="00000000-0000-0000-0000-000000000000" ${attribute}="true"/>`));
    }
});

test("cached projection rejects identity, metadata and XML shape corruption", () => {
    const xml = `<card id="${uuid}"/>`;
    for (const extra of [{ uuid: "bad" }, { revision: 0 }, { revision: 1.1 }, { kind: 3 },
        { modifiedMs: -1 }, { modifiedMs: NaN }]) rejected(fragment(xml, extra));
    for (const invalid of [
        `<label id="${uuid}"/>`,
        `<card id="${uuid}" xmlns="urn:other"/>`,
        `<card id="${uuid}"><card id="${uuid}"/></card>`,
        `<card id="${uuid}">`,
        `<!DOCTYPE card [<!ENTITY secret "value">]><card id="${uuid}"/>`,
        `<card id="${uuid}"/><card id="${uuid}"/>`,
    ]) rejected(fragment(invalid));
    rejected(fragment(`<label id="${uuid}"/>`, { kind: 1 }));
    rejected(fragment(`<label id="bad"/>`, { kind: 2 }));
});
