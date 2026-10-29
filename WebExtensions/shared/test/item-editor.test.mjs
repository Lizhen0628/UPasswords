import { test } from "node:test";
import { JSDOM } from "jsdom";
import assert from "node:assert/strict";
import { itemEditorDomCases } from "./item-editor-dom-cases.mjs";
import {
    analyzeCardConflict,
    composeCardConflict,
    sourceFromFragment,
    updateItemXml,
    VaultCryptoError,
} from "../dist/index.js";

const { window } = new JSDOM("");
globalThis.DOMParser = window.DOMParser;
globalThis.XMLSerializer = window.XMLSerializer;
for (const { name, run } of itemEditorDomCases) {
    test(`item editor DOM: ${name}`, run);
}

test("item editor rejects unsafe declarations even without a DOM", () => {
    assert.throws(() => sourceFromFragment('<!DOCTYPE card [<!ENTITY x "bad">]><card/>', 1),
        (error) => error instanceof VaultCryptoError && error.message === "bad_xml");
});

test("item editor reports unavailable DOM rather than using a lossy fallback parser", () => {
    delete globalThis.DOMParser;
    delete globalThis.XMLSerializer;
    try {
        assert.throws(() => updateItemXml("<card/>", { title: "", fieldValues: [], notes: "" }),
            (error) => error instanceof VaultCryptoError && error.message === "dom_unavailable");
    } finally {
        globalThis.DOMParser = window.DOMParser;
        globalThis.XMLSerializer = window.XMLSerializer;
    }
});

test("conflict composition uses stable field identities and preserves base metadata", () => {
    const itemID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
    const userFieldID = "11111111-2222-4333-8444-555555555555";
    const passwordFieldID = "22222222-3333-4444-8555-666666666666";
    const extraFieldID = "33333333-4444-4555-8666-777777777777";
    const firstID = "a".repeat(32);
    const secondID = "b".repeat(32);
    const candidates = [
        {
            candidateId: firstID, kind: 1, op: "upsert", modifiedMs: 10,
            xml: `<card id="${itemID}" title="Base title" modified="10" future="keep"><field id="${userFieldID}" name="User" type="login">alice</field><field id="${passwordFieldID}" name="Password" type="password">old</field><note>old note</note><future>opaque</future></card>`,
        },
        {
            candidateId: secondID, kind: 1, op: "upsert", modifiedMs: 20,
            xml: `<card id="${itemID}" title="Other title" modified="20"><field id="${userFieldID}" name="User" type="login">alice</field><field id="${passwordFieldID}" name="Password" type="password">new</field><field id="${extraFieldID}" name="Recovery" type="text">recovery-code</field><note>new note</note></card>`,
        },
    ];
    const analysis = analyzeCardConflict(candidates);
    assert.ok(analysis);
    assert.equal(analysis.fieldGroups.find(field => field.fieldId === userFieldID)?.requiresChoice, false);
    assert.equal(analysis.fieldGroups.find(field => field.fieldId === passwordFieldID)?.requiresChoice, true);
    assert.equal(analysis.fieldGroups.find(field => field.fieldId === extraFieldID)?.requiresChoice, true);
    assert.equal(analysis.notesRequireChoice, true);

    const composed = composeCardConflict(candidates, {
        baseCandidateId: firstID,
        fieldSources: { [passwordFieldID]: secondID, [extraFieldID]: secondID },
        notesCandidateId: secondID,
        nowMs: 50,
    });
    const card = new DOMParser().parseFromString(composed.xml, "application/xml").documentElement;
    const fields = Array.from(card.children).filter(element => element.tagName === "field");
    assert.equal(card.getAttribute("title"), "Base title");
    assert.equal(card.getAttribute("future"), "keep");
    assert.deepEqual(fields.map(field => field.getAttribute("id")), [userFieldID, passwordFieldID, extraFieldID]);
    assert.deepEqual(fields.map(field => field.textContent), ["alice", "new", "recovery-code"]);
    assert.equal(card.querySelector("note")?.textContent, "new note");
    assert.equal(card.querySelector("future")?.textContent, "opaque");
    assert.equal(card.getAttribute("modified"), "50");
    assert.equal(composed.modifiedMs, 50);
});

test("conflict composition rejects attachments, unstable field identities and incomplete selections", () => {
    const itemID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
    const fieldID = "11111111-2222-4333-8444-555555555555";
    const candidate = (candidateId, xml) => ({
        candidateId, kind: 1, op: "upsert", modifiedMs: 1, xml,
    });
    const valid = [
        candidate("a".repeat(32), `<card id="${itemID}"><field id="${fieldID}">one</field></card>`),
        candidate("b".repeat(32), `<card id="${itemID}"><field id="${fieldID}">two</field></card>`),
    ];
    assert.ok(analyzeCardConflict(valid));
    assert.throws(() => composeCardConflict(valid, { baseCandidateId: "a".repeat(32), fieldSources: {} }),
        error => error instanceof VaultCryptoError && error.message === "conflict_selection_incomplete");

    const noStableIdentity = valid.map((entry, index) => ({
        ...entry,
        xml: `<card id="${itemID}"><field name="Field">${index}</field></card>`,
    }));
    assert.equal(analyzeCardConflict(noStableIdentity), null);

    const withAttachment = valid.map(entry => ({
        ...entry,
        xml: entry.xml.replace("</card>", "<image name=\"photo\">AAAA</image></card>"),
    }));
    assert.equal(analyzeCardConflict(withAttachment), null);
});
