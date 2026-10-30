import assert from "node:assert/strict";
import { test } from "node:test";
import { readFile } from "node:fs/promises";
import { JSDOM } from "jsdom";
import {
    createItem,
    createLoginItemXml,
    generatePassword,
    hostMatches,
    itemMatchesPage,
    parseVaultXml,
    projectVaultFragment,
    RelayApiError,
    safeWebsiteUrl,
    saveVaultItem,
    VaultCryptoError,
} from "../dist/index.js";

const { window } = new JSDOM("");
globalThis.DOMParser = window.DOMParser;
globalThis.XMLSerializer = window.XMLSerializer;
const uuid = "abcdefab-1234-4abc-8def-0123456789ab";

test("generatePassword rejection sampling discards out-of-range bytes deterministically", (t) => {
    let calls = 0;
    t.mock.method(crypto, "getRandomValues", (array) => {
        calls++;
        array.fill(0);
        // Digits use buckets [0, 250); 250 and 255 must not map to 0 or 5.
        array.set([255, 250, 0, 1, 2, 3, 4, 5, 6, 249]);
        return array;
    });
    const password = generatePassword({ length: 8, uppercase: false, lowercase: false, digits: true, symbols: false });
    assert.equal(password, "01234569");
    assert.equal(calls, 1);
});

test("generatePassword validates options, length and enforces selected classes", () => {
    for (const length of [7, 129, 1.5, NaN]) {
        assert.throws(() => generatePassword({ length, uppercase: true, lowercase: true, digits: true, symbols: true }), /bad_password_length/);
    }
    assert.throws(() => generatePassword({ length: 16, uppercase: false, lowercase: false, digits: false, symbols: false }), /no_password_classes/);
    const options = { length: 48, uppercase: true, lowercase: true, digits: true, symbols: true };
    for (let attempt = 0; attempt < 20; attempt++) {
        const password = generatePassword(options);
        assert.equal(password.length, options.length);
        assert.match(password, /[A-Z]/);
        assert.match(password, /[a-z]/);
        assert.match(password, /[0-9]/);
        assert.match(password, /[!"#$%&'()*+,-./:;<=>?@[\\\]^_`{|}~]/);
    }
});

test("createLoginItemXml creates native-compatible typed fields, timestamps and escaped values", () => {
    const xml = createLoginItemXml({
        id: uuid, title: `A & <B> \"site\"`, username: "user<&", password: "p&<\"'", url: "https://example.com/login?a=1&b=2", notes: "line 1\nline <2>&",
    }, 1_800_000_000_123);
    const card = new DOMParser().parseFromString(xml, "application/xml").documentElement;
    assert.equal(card.tagName, "card");
    assert.equal(card.getAttribute("id"), uuid.toUpperCase());
    assert.equal(card.getAttribute("created"), "1800000000123");
    assert.equal(card.getAttribute("modified"), "1800000000123");
    assert.equal(card.getAttribute("autofill"), "on");
    const fields = Array.from(card.children).filter((child) => child.tagName === "field");
    assert.deepEqual(fields.map((field) => [field.getAttribute("type"), field.getAttribute("autofill")]), [
        ["login", "username"], ["password", "current-password"], ["website", "url"],
    ]);
    assert.deepEqual(fields.map((field) => field.textContent), ["user<&", "p&<\"'", "https://example.com/login?a=1&b=2"]);
    const fieldIDs = fields.map((field) => field.getAttribute("id"));
    assert.equal(new Set(fieldIDs).size, 3);
    for (const id of fieldIDs) {
        assert.match(id, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i);
    }
    assert.equal(card.querySelector("note")?.textContent, "line 1\nline <2>&");
    const parsedFields = parseVaultXml(`<passworddatabase>${xml}</passworddatabase>`)[0].fields;
    assert.equal(parsedFields.length, 3);
    assert.deepEqual(parsedFields.map((field) => field.id), fieldIDs);
    assert.match(xml, /&amp;/);
});

test("createLoginItemXml rejects bad ids, title, URL, time and XML characters", () => {
    const item = { id: uuid, title: "Title", username: "", password: "", url: "", notes: "" };
    for (const id of ["", "bad"]) assert.throws(() => createLoginItemXml({ ...item, id }, 0), VaultCryptoError);
    for (const title of ["", "  "]) assert.throws(() => createLoginItemXml({ ...item, title }, 0), /bad_item_title/);
    for (const url of ["javascript:alert(1)", "//evil.example", "https://user:pass@example.com"]) {
        assert.throws(() => createLoginItemXml({ ...item, url }, 0), /bad_item_url/);
    }
    assert.throws(() => createLoginItemXml({ ...item, notes: "bad\u0001text" }, 0), /bad_xml_text/);
    assert.throws(() => createLoginItemXml(item, -1), /bad_item_time/);
});

test("created item interoperates with native fixture and normalizes schemeless website paths", async () => {
    const fixture = JSON.parse(await readFile(new URL("./fixtures/item-vector.json", import.meta.url), "utf8"));
    const existing = projectVaultFragment({ uuid: fixture.uuid, xml: fixture.fragment, kind: 1, revision: 1, modifiedMs: 0 });
    assert.equal(existing?.fields[0].type, "login");
    assert.equal(existing?.fields[1].type, "password");
    assert.equal(existing?.fields[2].type, "website");

    const created = createLoginItemXml({ id: uuid, title: "Native", username: "u", password: "p", url: "example.com/path", notes: "" }, 123);
    const projected = projectVaultFragment({ uuid, xml: created, kind: 1, revision: 1, modifiedMs: 123 });
    assert.deepEqual(projected?.fields.map((field) => field.type), ["login", "password", "website"]);
    assert.equal(projected?.fields[2].value, "https://example.com/path");
    assert.equal(projected?.host, "https://example.com/path");
    assert.equal(hostMatches("login.example.com", projected.host), true);
    const bare = createLoginItemXml({ id: uuid, title: "Native", username: "u", password: "p", url: "example.com", notes: "" }, 123);
    const bareProjection = projectVaultFragment({ uuid, xml: bare, kind: 1, revision: 1, modifiedMs: 123 });
    assert.equal(bareProjection.host, "https://example.com/");
});

test("created login preserves multiple website associations and their match modes", async () => {
    const xml = createLoginItemXml({ id: uuid, title: "Multi-site", username: "u", password: "p",
        url: "example.com/login", siteMatch: "exactURL", sites: [{ url: "https://*.example.org/*", mode: "wildcard" }], notes: "" }, 123);
    const projected = projectVaultFragment({ uuid, xml, kind: 1, revision: 1, modifiedMs: 123 });
    assert.deepEqual(projected?.sites, [
        { url: "https://example.com/login", mode: "exactURL" },
        { url: "https://*.example.org/*", mode: "wildcard" },
    ]);
    assert.equal(itemMatchesPage("https://login.example.org/sign-in", projected), true);
    assert.equal(itemMatchesPage("https://example.com/other", projected), false);
});
test("favorite metadata is projected only for favorited cards", () => {
    const favorite = parseVaultXml(`<passworddatabase><card id="${uuid}" favorite="true"/></passworddatabase>`)[0];
    const ordinary = parseVaultXml(`<passworddatabase><card id="${uuid}"/></passworddatabase>`)[0];
    assert.equal(favorite.favorite, true);
    assert.equal(Object.hasOwn(ordinary, "favorite"), false);
});

test("safeWebsiteUrl allows HTTP(S) and bare hosts but rejects unsafe URLs", () => {
    assert.equal(safeWebsiteUrl("example.com/path"), "https://example.com/path");
    assert.equal(safeWebsiteUrl("http://example.com"), "http://example.com/");
    for (const value of ["javascript:alert(1)", "file:///etc/passwd", "//example.com", "https://user@example.com", "https://a.com\\@evil.com", "https://a.com\n@evil.com"]) {
        assert.equal(safeWebsiteUrl(value), null);
    }
});

function mock(t, body, status = 200) {
    const calls = [];
    t.mock.method(globalThis, "fetch", async (url, init) => {
        calls.push({ url: String(url), init });
        return new Response(JSON.stringify(body), { status });
    });
    return calls;
}

test("createItem sends baseRevision zero via CAS insert and expects revision one", async (t) => {
    const calls = mock(t, { results: [{ uuid, status: "ok", revision: 1 }] });
    assert.deepEqual(await createItem("token", "vault", {
        uuid, bodyB64: "AQ==", modifiedMs: 12, attachmentRefs: [],
    }), { revision: 1 });
    assert.deepEqual(JSON.parse(calls[0].init.body), { items: [{
        uuid, kind: 1, op: "upsert", baseRevision: 0, bodyB64: "AQ==", modifiedMs: 12, attachmentRefs: [],
    }] });
    t.mock.restoreAll();
});

test("createItem conflicts are never retried and existing save rejects revision zero", async (t) => {
    const calls = mock(t, { results: [{ uuid, status: "conflict" }] });
    await assert.rejects(() => createItem("token", "vault", {
        uuid, bodyB64: "AQ==", modifiedMs: 12, attachmentRefs: [],
    }),
        (error) => error instanceof RelayApiError && error.code === "item_conflict");
    assert.equal(calls.length, 1);
    await assert.rejects(() => saveVaultItem("token", "vault", {
        uuid, revision: 0, bodyB64: "AQ==", modifiedMs: 12, attachmentRefs: [],
    }),
        (error) => error instanceof RelayApiError && error.code === "bad_item_revision");
});

test("createItem rejects malformed response UUIDs and revisions", async (t) => {
    for (const response of [
        { uuid: "different-uuid", status: "ok", revision: 1 },
        { uuid, status: "ok", revision: 2 },
        { uuid, status: "ok", revision: "1" },
    ]) {
        const calls = mock(t, { results: [response] });
        await assert.rejects(() => createItem("token", "vault", {
            uuid, bodyB64: "AQ==", modifiedMs: 12, attachmentRefs: [],
        }),
            (error) => error instanceof RelayApiError && error.code === "bad_item_response");
        assert.equal(calls.length, 1);
        t.mock.restoreAll();
    }
});
