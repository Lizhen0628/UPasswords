import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";

const root = new URL("../../", import.meta.url);
const variants = ["chrome", "safari", "edge", "firefox"];
const source = readFileSync(new URL("chrome/src/content.js", root), "utf8");

function fixture({ password = true, autocomplete = "current-password", topFrame = true, protocol = "https:", language = "en" } = {}) {
    const callbacks = new Map();
    const messages = [];
    const listeners = [];
    const timers = new Map();
    const intervals = [];
    const allElements = [];
    const observers = [];
    let timerID = 0;
    let hint = { type: "site-hint", count: 2, unlocked: true };
    let popup = { type: "vault-opened", ok: false };
    class Element {
        constructor(tag) {
            this.tagName = tag;
            this.type = "";
            this.autocomplete = "";
            this.children = [];
            this.events = new Map();
            this.style = {};
            this.hidden = false;
            this.textContent = "";
            this.parentElement = null;
            this.visible = true;
            this.connected = false;
            allElements.push(this);
        }
        get isConnected() { return this.connected || Boolean(this.parentElement?.isConnected); }
        append(...children) {
            for (const child of children) {
                child.parentElement = this;
                this.children.push(child);
            }
        }
        remove() {
            if (this.parentElement) this.parentElement.children = this.parentElement.children.filter((child) => child !== this);
            this.parentElement = null;
            this.connected = false;
        }
        contains(node) { return this === node || this.children.some((child) => child.contains(node)); }
        closest() { return this.form ?? null; }
        addEventListener(type, listener) { this.events.set(type, listener); }
        dispatchEvent(event) { this.events.get(event.type)?.(event); return true; }
        attachShadow(options) { this.shadowOptions = options; this.shadow = new Element("shadow"); return this.shadow; }
        getClientRects() { return this.visible && !this.hidden ? [{}] : []; }
        getBoundingClientRect() { return { left: 80, bottom: 120, width: this.visible ? 200 : 0, height: 25 }; }
        querySelector() { return this.children.find((field) => field.type === "password" || field.autocomplete === "new-password") ?? null; }
    }
    let nativeSets = 0;
    class Input extends Element {
        constructor(type, autocomplete) {
            super("input");
            this.type = type;
            this.autocomplete = autocomplete;
            this.currentValue = "";
            this.emitted = [];
        }
        get value() { return this.currentValue; }
        set value(value) { nativeSets++; this.currentValue = value; }
        dispatchEvent(event) { this.emitted.push(event.type); return super.dispatchEvent(event); }
    }
    const html = new Element("html");
    html.connected = true;
    html.lang = language;
    const form = new Element("form");
    html.append(form);
    const username = new Input("text", "username");
    username.form = form;
    form.append(username);
    const pass = new Input("password", autocomplete);
    pass.form = form;
    if (password) form.append(pass);
    const document = {
        documentElement: html,
        createElement(tag) { return new Element(tag); },
        querySelectorAll(selector) {
            assert.equal(selector, "input");
            return form.children.filter((field) => field.tagName === "input");
        },
        addEventListener(type, listener) { callbacks.set(`document:${type}`, listener); },
    };
    const location = { protocol, origin: `${protocol}//example.com`, href: `${protocol}//example.com/login` };
    const api = {
        runtime: {
            id: "extension-id",
            getURL(path) { return `moz-extension://id/${path}`; },
            onMessage: { addListener(listener) { listeners.push(listener); } },
            async sendMessage(message) {
                messages.push(message);
                if (message.type === "site-hint") return structuredClone(hint);
                if (message.type === "open-vault") return popup;
            },
        },
    };
    const context = {
        browser: api, document, location, navigator: { language }, HTMLInputElement: Input,
        Event: class { constructor(type, options) { this.type = type; Object.assign(this, options); } },
        console: { info() {}, warn() {} },
        MutationObserver: class {
            constructor(callback) { observers.push(callback); }
            observe() {}
        },
        setTimeout(callback, delay) { const id = ++timerID; timers.set(id, { callback, delay }); return id; },
        clearTimeout(id) { timers.delete(id); },
        setInterval(callback, delay) { intervals.push({ callback, delay }); },
        innerWidth: 1000, innerHeight: 800,
        getComputedStyle() { return { visibility: "visible", opacity: "1", display: "block" }; },
        addEventListener(type, listener) { callbacks.set(type, listener); },
    };
    context.window = context;
    context.top = topFrame ? context : {};
    vm.runInNewContext(source, context);
    const popupSender = { id: "extension-id", url: "moz-extension://id/src/popup.html" };
    const sendFill = (change = {}, sender = popupSender) => {
        let response;
        listeners[0]({ type: "fill", expectedOrigin: location.origin,
            candidate: { username: "SECRET-user", password: "SECRET-password" }, ...change }, sender, (value) => { response = value; });
        return response;
    };
    return {
        api, callbacks, messages, listeners, timers, intervals, observers, html, form, username, pass,
        location, popupSender, sendFill,
        get nativeSets() { return nativeSets; },
        get hintHost() { return html.children.find((element) => element !== form); },
        get button() { return allElements.findLast((element) => element.tagName === "button"); },
        get fallback() { return allElements.findLast((element) => element.tagName === "p"); },
        set hint(value) { hint = value; }, set popup(value) { popup = value; },
        async flush() {
            const pending = [...timers.values()];
            timers.clear();
            for (const { callback } of pending) callback();
            await settle();
        },
    };
}
const settle = async () => { await new Promise((resolve) => setImmediate(resolve)); };

test("all browser content scripts remain byte-identical", () => {
    for (const browser of variants) assert.equal(readFileSync(new URL(`${browser}/src/content.js`, root), "utf8"), source);
});

test("login page displays only localized count in closed ShadowDOM and never auto-fills", async () => {
    const f = fixture();
    await settle();
    assert.ok(f.hintHost);
    assert.equal(f.hintHost.shadowOptions.mode, "closed");
    assert.equal(f.button.textContent, "UPasswords · 2 matching passwords");
    assert.equal(f.nativeSets, 0);
    assert.equal(f.username.value, "");
    assert.equal(f.pass.value, "");
    assert.ok(!f.callbacks.has("document:upasswords-fill"));
    const text = f.hintHost.shadow.children.map((element) => element.textContent).join(" ");
    assert.doesNotMatch(text, /SECRET|username|title/);
    const zh = fixture({ language: "zh-CN" });
    await settle();
    assert.equal(zh.button.textContent, "UPasswords · 2 个匹配密码");
});

test("frames, non-web URLs, signup and hidden inputs do not show a hint", async () => {
    for (const options of [{ topFrame: false }, { protocol: "file:" }, { autocomplete: "new-password" }]) {
        const f = fixture(options);
        await settle();
        assert.equal(f.hintHost, undefined);
        assert.ok(!f.messages.some((message) => message.type === "site-hint"));
    }
    const f = fixture();
    await settle();
    f.pass.visible = false;
    f.username.visible = false;
    f.intervals[0].callback();
    await settle();
    assert.equal(f.hintHost, undefined);
});

test("trusted popup sender and exact origin required; native input setter and events fill visible fields", async () => {
    const f = fixture();
    await settle();
    for (const sender of [
        { ...f.popupSender, id: "other-extension" },
        { ...f.popupSender, url: `${f.popupSender.url}?forged` },
        { ...f.popupSender, url: "https://example.com/login", tab: { id: 1 } },
        { ...f.popupSender, tab: { id: 1 } },
    ]) assert.equal(f.sendFill({}, sender).ok, false);
    assert.equal(f.sendFill({ expectedOrigin: "https://other.example" }).ok, false);
    assert.equal(f.sendFill({ expectedOrigin: undefined }).ok, false);
    assert.equal(f.nativeSets, 0);
    // A framework's own value property must not intercept the native setter.
    Object.defineProperty(f.pass, "value", { get() { return this.currentValue; }, set() { throw new Error("framework setter"); } });
    assert.equal(f.sendFill().ok, true);
    assert.equal(f.nativeSets, 2);
    assert.equal(f.pass.value, "SECRET-password");
    assert.deepEqual(f.pass.emitted, ["input", "change"]);
    f.pass.visible = false;
    f.username.visible = false;
    assert.equal(f.sendFill().ok, false);
    assert.equal(f.nativeSets, 2);
});

test("hint opens only on trusted clicks and falls back to localized toolbar instruction", async () => {
    const f = fixture();
    await settle();
    await f.button.events.get("click")({ isTrusted: false });
    assert.ok(!f.messages.some((message) => message.type === "open-vault"));
    await f.button.events.get("click")({ isTrusted: true });
    assert.equal(f.messages.filter((message) => message.type === "open-vault").length, 1);
    assert.equal(f.fallback.hidden, false);
    assert.match(f.fallback.textContent, /browser toolbar/);
    const zh = fixture({ language: "zh-Hans" });
    await settle();
    await zh.button.events.get("click")({ isTrusted: true });
    assert.match(zh.fallback.textContent, /工具栏/);
});

test("polling removes hints on lock and zero count without touch or secret requests", async () => {
    const f = fixture();
    await settle();
    assert.equal(f.intervals[0].delay, 30_000);
    f.hint = { type: "site-hint", count: 0, unlocked: false };
    f.intervals[0].callback();
    await settle();
    assert.equal(f.hintHost, undefined);
    f.hint = { type: "site-hint", count: 0, unlocked: true };
    f.intervals[0].callback();
    await settle();
    assert.equal(f.hintHost, undefined);
    assert.ok(f.messages.every((message) => ["location", "site-hint"].includes(message.type)));
});

test("dynamic forms debounce refresh; own host mutations do not loop; SPA route is re-reported", async () => {
    const f = fixture();
    await settle();
    const host = f.hintHost;
    f.observers[0]([{ type: "childList", target: f.html, addedNodes: [host], removedNodes: [] }]);
    f.observers[0]([{ type: "attributes", target: host }]);
    assert.equal(f.timers.size, 0);
    f.form.children = [];
    f.observers[0]([{ type: "childList", target: f.form, addedNodes: [], removedNodes: [f.pass] }]);
    assert.equal(f.timers.size, 1);
    await f.flush();
    assert.equal(f.hintHost, undefined);
    f.observers[0]([{ type: "childList", target: f.html, addedNodes: [], removedNodes: [host] }]);
    assert.equal(f.timers.size, 0);
    f.form.append(f.username, f.pass);
    f.observers[0]([{ type: "childList", target: f.form, addedNodes: [f.pass], removedNodes: [] }]);
    await f.flush();
    assert.ok(f.hintHost);
    f.location.href = "https://example.com/another-login";
    f.callbacks.get("popstate")();
    await f.flush();
    assert.equal(f.messages.filter((message) => message.type === "location").at(-1).href, f.location.href);
    assert.equal(f.nativeSets, 0);
});
