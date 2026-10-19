import { test } from "node:test";
import assert from "node:assert/strict";
import { itemEditorDomCases } from "./item-editor-dom-cases.mjs";
import { sourceFromFragment, updateItemXml, VaultCryptoError } from "../dist/index.js";

const hasDom = typeof DOMParser !== "undefined" && typeof XMLSerializer !== "undefined";
for (const { name, run } of itemEditorDomCases) {
    test(`item editor DOM: ${name}`, { skip: !hasDom && "Requires real browser XML DOM; run itemEditorDomCases in browser harness" }, run);
}

test("item editor rejects unsafe declarations even without a DOM", () => {
    assert.throws(() => sourceFromFragment('<!DOCTYPE card [<!ENTITY x "bad">]><card/>', 1),
        (error) => error instanceof VaultCryptoError && error.message === "bad_xml");
});

test("item editor reports unavailable DOM rather than using a lossy fallback parser", { skip: hasDom }, () => {
    assert.throws(() => updateItemXml("<card/>", { title: "", fieldValues: [], notes: "" }),
        (error) => error instanceof VaultCryptoError && error.message === "dom_unavailable");
});
