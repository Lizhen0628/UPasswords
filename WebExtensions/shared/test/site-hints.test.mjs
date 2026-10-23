import assert from "node:assert/strict";
import test from "node:test";
import { installSiteHints } from "../dist/messaging/site-hints.js";
import { createUnlockSession } from "../dist/storage/unlock-session.js";

const item = (host = "example.com", password = "SECRET-password") => ({
    id: "private-id", title: "SECRET-title", host,
    fields: [{ type: "login", value: "SECRET-user" }, { type: "password", value: password }],
});

function fixture() {
    const listeners = [];
    const events = {};
    const badges = [];
    const tab = { id: 7, active: true, url: "https://login.example.com/signin" };
    let state = { unlocked: true, items: [item(), item("other.example"), item("example.com", "")] };
    let inspections = 0;
    let opens = 0;
    const event = (name) => ({ addListener(listener) { events[name] = listener; } });
    const api = {
        runtime: { id: "own-extension", onMessage: { addListener(fn) { listeners.push(fn); } } },
        tabs: {
            async get(id) { assert.equal(id, 7); return { ...tab }; },
            async query() { return [{ ...tab }]; },
            onActivated: event("activated"), onUpdated: event("updated"), onRemoved: event("removed"),
        },
        storage: { onChanged: event("storage") },
        action: {
            async setBadgeText(value) { badges.push(value); },
            async setBadgeBackgroundColor() {},
            async openPopup() { opens++; },
        },
    };
    const session = { async inspect() { inspections++; return state; } };
    installSiteHints(api, session);
    const sender = { id: "own-extension", tab: { id: 7 }, frameId: 0, url: tab.url };
    const request = (message = { type: "site-hint" }, source = sender) => new Promise((resolve) => {
        assert.equal(listeners[0](message, source, resolve), true);
    });
    return { api, sender, request, listener: listeners[0], events, tab, badges,
        set state(value) { state = value; }, get inspections() { return inspections; },
        get opens() { return opens; },
    };
}
const settle = () => new Promise((resolve) => setImmediate(resolve));

test("site hints derive host from sender and return only count/unlocked", async () => {
    const f = fixture();
    const response = await f.request({ type: "site-hint", host: "other.example" });
    assert.deepEqual(response, { type: "site-hint", count: 1, unlocked: true, profileAvailable: false });
    assert.doesNotMatch(JSON.stringify(response), /SECRET|items|title|username|generation|expiresAt/);
    // Unrelated messages do not share this API or expose inspection to the caller.
    let answered = false;
    assert.equal(f.listener({ type: "inspect" }, f.sender, () => { answered = true; }), false);
    await settle();
    assert.ok(f.badges.some((badge) => badge.text === "1"));
    assert.equal(answered, false);
});

test("registration hints expose profile availability without exposing profile values", async () => {
    const f = fixture();
    const profile = {
        id: "profile-id", title: "SECRET-profile", recordType: "userProfile", host: "",
        autofillEnabled: true,
        fields: [{ autofill: "email", value: "SECRET-email" }],
    };
    f.state = { unlocked: true, items: [profile] };
    const response = await f.request({ type: "site-hint", registration: true });
    assert.deepEqual(response, { type: "site-hint", count: 0, unlocked: true, profileAvailable: true });
    assert.doesNotMatch(JSON.stringify(response), /SECRET|profile-id|items/);
    assert.deepEqual(await f.request({ type: "site-hint" }), {
        type: "site-hint", count: 0, unlocked: true, profileAvailable: false,
    });
    f.state = { unlocked: true, items: [{ ...profile, autofillEnabled: false }] };
    assert.equal((await f.request({ type: "site-hint", registration: true })).profileAvailable, false);
    f.state = { unlocked: true, items: [{ ...profile,
        fields: [{ autofill: "current-password", value: "SECRET-unrelated" }],
    }] };
    assert.equal((await f.request({ type: "site-hint", registration: true })).profileAvailable, false);
});

test("sender guards reject foreign extensions, popup, iframes and stale origins before inspecting", async () => {
    const f = fixture();
    await settle();
    const baseline = f.inspections;
    for (const source of [
        { ...f.sender, id: "other" },
        { ...f.sender, tab: undefined },
        { ...f.sender, tab: { id: "7" } },
        { ...f.sender, frameId: 1 },
        { ...f.sender, frameId: undefined },
        { ...f.sender, url: "https://attacker.example/" },
        { ...f.sender, url: "file:///tmp/page.html" },
        { ...f.sender, url: "https://login.example.com:444/signin" },
    ]) {
        assert.deepEqual(await f.request({ type: "site-hint" }, source), { type: "site-hint", count: 0, unlocked: false, profileAvailable: false });
    }
    assert.equal(f.inspections, baseline);
});

test("locked and zero-match counts clear active-tab badge without touching session", async () => {
    const f = fixture();
    await settle();
    f.state = { unlocked: false, items: [item()] };
    assert.deepEqual(await f.request(), { type: "site-hint", count: 0, unlocked: false, profileAvailable: false });
    f.events.storage({ "upw.unlockSession": {} }, "session");
    await settle();
    assert.equal(f.badges.at(-1).text, "");
    f.state = { unlocked: true, items: [item("other.example")] };
    f.events.activated({ tabId: 7 });
    await settle();
    assert.equal(f.badges.at(-1).text, "");
    f.state = { unlocked: true, items: [item()] };
    f.events.updated(7);
    await settle();
    assert.equal(f.badges.at(-1).text, "1");
});

test("navigation during inspection fails closed and does not expose previous-site count", async () => {
    const f = fixture();
    await settle();
    let calls = 0;
    f.api.tabs.get = async () => {
        calls++;
        return { ...f.tab, url: calls === 1 ? f.tab.url : "https://other.example/" };
    };
    assert.deepEqual(await f.request(), { type: "site-hint", count: 0, unlocked: false, profileAvailable: false });
});

test("open-vault is sender-authorized, opens only popup and provides unsupported fallback", async () => {
    const f = fixture();
    assert.deepEqual(await f.request({ type: "open-vault" }, { ...f.sender, frameId: 1 }), { type: "vault-opened", ok: false });
    assert.equal(f.opens, 0);
    assert.deepEqual(await f.request({ type: "open-vault" }), { type: "vault-opened", ok: true });
    assert.equal(f.opens, 1);
    f.api.action.openPopup = async () => { throw new Error("gesture unavailable"); };
    assert.deepEqual(await f.request({ type: "open-vault" }), { type: "vault-opened", ok: false });
    delete f.api.action.openPopup;
    assert.deepEqual(await f.request({ type: "open-vault" }), { type: "vault-opened", ok: false });
});

test("optional badge-color failure leaves the count intact", async () => {
    const f = fixture();
    await settle();
    f.api.action.setBadgeBackgroundColor = async () => { throw new Error("unsupported"); };
    f.events.activated({ tabId: 7 });
    await settle();
    assert.equal(f.badges.at(-1).text, "1");
});

test("real internal inspection expires without any hint query renewing its deadline", async () => {
    let now = 1000;
    const context = { token: "test-token", vaultId: "test-vault" };
    const local = {
        "relay.session": { token: context.token, expiresAt: now + 60_000 },
        "relay.vault": { id: context.vaultId },
    };
    const session = createUnlockSession({
        now: () => now, makeId: () => "generation", idleMs: 100,
        local: {
            async get(keys) { return Object.fromEntries(keys.map((key) => [key, local[key]])); },
            async set(values) { Object.assign(local, values); },
        },
    });
    const begun = await session.handle({ type: "vault-session", action: "begin", context });
    const committed = await session.handle({ type: "vault-session", action: "commit", context,
        generation: begun.generation, items: [item()] });
    const f = fixture();
    // A second listener lets this request run against the real session implementation.
    let listener;
    f.api.runtime.onMessage.addListener = (value) => { listener = value; };
    installSiteHints(f.api, session);
    const request = () => new Promise((resolve) => listener({ type: "site-hint" }, f.sender, resolve));
    now += 50;
    assert.deepEqual(await request(), { type: "site-hint", count: 1, unlocked: true, profileAvailable: false });
    assert.equal((await session.inspect()).expiresAt, committed.expiresAt);
    now += 51;
    assert.deepEqual(await request(), { type: "site-hint", count: 0, unlocked: false, profileAvailable: false });
    assert.equal(local["vault.items"], null);
});

test("tabs permission failure denies counts and popup opening", async () => {
    const f = fixture();
    await settle();
    f.api.tabs.get = async () => { throw new Error("no permission"); };
    assert.deepEqual(await f.request(), { type: "site-hint", count: 0, unlocked: false, profileAvailable: false });
    assert.deepEqual(await f.request({ type: "open-vault" }), { type: "vault-opened", ok: false });
    assert.equal(f.opens, 0);
});
