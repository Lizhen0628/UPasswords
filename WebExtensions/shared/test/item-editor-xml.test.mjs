import { test } from "node:test";
import { JSDOM } from "jsdom";
import { itemEditorDomCases } from "./item-editor-dom-cases.mjs";

const { window } = new JSDOM("");
globalThis.DOMParser = window.DOMParser;
globalThis.XMLSerializer = window.XMLSerializer;

for (const { name, run } of itemEditorDomCases) {
    test(`item editor XML DOM: ${name}`, run);
}
