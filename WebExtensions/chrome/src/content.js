// Pages receive only a match count. Credentials are filled solely by the trusted popup.
(function () {
    "use strict";
    const api = globalThis.browser ?? globalThis.chrome;
    if (!api?.runtime || window.top !== window || !/^https?:$/.test(location.protocol)) return;

    const POLL_MS = 30_000;
    const DEBOUNCE_MS = 180;
    const HINT_GAP = 6;
    const VIEWPORT_MARGIN = 8;
    const HINT_WIDTH = 280;
    const HINT_HEIGHT = 80;
    const ownedHosts = new WeakSet();
    const popupURL = api.runtime.getURL("src/popup.html");
    const chinese = /^zh/i.test(document.documentElement.lang || navigator.language || "en");
    let host = null;
    let button = null;
    let fallback = null;
    let renderedState = "";
    let position = "";
    let anchor = null;
    let sequence = 0;
    let debounce = null;
    let pageHref = location.href;

    function isVisible(field) {
        if (field.type === "hidden" || field.disabled || field.readOnly || field.getClientRects().length === 0) return false;
        const rect = field.getBoundingClientRect();
        if (rect.width <= 1 || rect.height <= 1) return false;
        for (let element = field; element; element = element.parentElement) {
            const style = window.getComputedStyle(element);
            if (style.display === "none" || style.visibility === "hidden"
                || style.visibility === "collapse" || Number(style.opacity) === 0) return false;
        }
        return true;
    }

    function loginFields() {
        const inputs = Array.from(document.querySelectorAll("input")).filter(isVisible);
        const passwords = inputs.filter((field) => field.type.toLowerCase() === "password");
        const password = passwords.find((field) => field.autocomplete === "current-password")
            || (passwords.length === 1 && passwords[0].autocomplete !== "new-password" ? passwords[0] : null);
        if (password) {
            const scope = password.form || password.closest('[role="form"]') || password.parentElement;
            const nearby = inputs.filter((field) => scope?.contains(field));
            const username = nearby.find((field) => field.autocomplete === "username")
                || nearby.find((field) => /^(email|text|tel)$/.test(field.type));
            return { password, username, anchor: password };
        }
        // Username-first sign-in steps must explicitly identify a username and a form.
        const username = inputs.find((field) => field.autocomplete === "username" && field.form
            && !field.form.querySelector('input[type="password"], input[autocomplete="new-password"]'));
        return username ? { username, password: null, anchor: username } : null;
    }

    function removeHint() {
        if (host) host.remove();
        host = null;
        button = null;
        fallback = null;
        anchor = null;
        renderedState = "";
        position = "";
    }

    function reposition() {
        if (!host || !anchor) return;
        const rect = anchor.getBoundingClientRect();
        const left = Math.max(VIEWPORT_MARGIN, Math.min(rect.left, window.innerWidth - HINT_WIDTH - VIEWPORT_MARGIN));
        const top = Math.max(VIEWPORT_MARGIN, Math.min(rect.bottom + HINT_GAP, window.innerHeight - HINT_HEIGHT));
        const next = `${left}:${top}`;
        if (position === next) return;
        position = next;
        host.style.left = `${left}px`;
        host.style.top = `${top}px`;
    }

    function showHint(count, field) {
        anchor = field;
        if (host && !host.isConnected) removeHint();
        anchor = field;
        if (!host) {
            host = document.createElement("div");
            ownedHosts.add(host);
            host.style.cssText = "all:initial;position:fixed;z-index:2147483647;max-width:280px;";
            const shadow = host.attachShadow({ mode: "closed" });
            const style = document.createElement("style");
            style.textContent = ":host{font:12px/1.4 system-ui,sans-serif;color-scheme:light dark}button{font:inherit;font-weight:600;color:#2f6cc0;background:#fff;border:1px solid #cfdff2;border-radius:10px;padding:7px 12px;cursor:pointer;max-width:280px;text-align:start;box-shadow:0 4px 14px rgb(31 68 120/.14)}button:focus-visible{outline:2px solid #3f7fd4;outline-offset:2px}p{font:inherit;color:#2f6cc0;background:#fff;border:1px solid #cfdff2;border-radius:10px;padding:7px 11px;margin:4px 0 0;max-width:260px;box-shadow:0 4px 14px rgb(31 68 120/.12)}@media(prefers-color-scheme:dark){button,p{color:#8fbcee;background:#2b2c28;border-color:#465870}button{box-shadow:0 4px 14px rgb(0 0 0/.4)}}";
            button = document.createElement("button");
            button.type = "button";
            fallback = document.createElement("p");
            fallback.hidden = true;
            button.addEventListener("click", async (event) => {
                if (!event.isTrusted) return;
                const currentHost = host;
                try {
                    const response = await api.runtime.sendMessage({ type: "open-vault" });
                    if (currentHost !== host) return;
                    if (response?.type === "vault-opened" && response.ok) return;
                } catch {
                    console.warn("[upw] site hint popup unavailable");
                }
                if (currentHost !== host || !fallback) return;
                fallback.textContent = chinese ? "请点击浏览器工具栏中的 UPasswords 图标。" : "Click the UPasswords icon in your browser toolbar.";
                fallback.hidden = false;
            });
            shadow.append(style, button, fallback);
            document.documentElement.append(host);
        }
        const state = String(count);
        if (renderedState !== state) {
            button.textContent = chinese ? `UPasswords · ${count} 个匹配密码` : `UPasswords · ${count} matching password${count === 1 ? "" : "s"}`;
            fallback.hidden = true;
            renderedState = state;
            console.info("[upw] site hint updated");
        }
        reposition();
    }

    async function refresh() {
        const request = ++sequence;
        const href = location.href;
        if (pageHref !== href) {
            pageHref = href;
            removeHint();
            reportLocation();
        }
        const fields = loginFields();
        if (!fields) {
            removeHint();
            return;
        }
        try {
            const response = await api.runtime.sendMessage({ type: "site-hint" });
            if (request !== sequence || href !== location.href) return;
            const current = loginFields();
            if (!current || response?.type !== "site-hint" || !response.unlocked
                || !Number.isSafeInteger(response.count) || response.count <= 0) {
                removeHint();
                return;
            }
            showHint(response.count, current.anchor);
        } catch {
            if (request === sequence) removeHint();
        }
    }

    function schedule() {
        clearTimeout(debounce);
        debounce = setTimeout(() => { void refresh(); }, DEBOUNCE_MS);
    }

    function reportLocation() {
        try {
            Promise.resolve(api.runtime.sendMessage({ type: "location", href: location.href })).catch(() => undefined);
        } catch { /* Extension reload invalidates this content context. */ }
    }

    function setField(field, value) {
        if (!field || typeof value !== "string" || !value || !isVisible(field)) return false;
        const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")?.set;
        if (!setter) return false;
        setter.call(field, value);
        field.dispatchEvent(new Event("input", { bubbles: true }));
        field.dispatchEvent(new Event("change", { bubbles: true }));
        return true;
    }

    api.runtime.onMessage.addListener((message, sender, sendResponse) => {
        if (message?.type !== "fill") return false;
        const trusted = sender?.id === api.runtime.id && sender.url === popupURL && sender.tab == null
            && message.expectedOrigin === location.origin;
        if (!trusted || !message.candidate) {
            sendResponse({ type: "filled", ok: false });
            return false;
        }
        const fields = loginFields();
        const usernameFilled = setField(fields?.username, message.candidate.username);
        const passwordFilled = setField(fields?.password, message.candidate.password);
        const ok = usernameFilled || passwordFilled;
        console.info(`[upw] popup fill dispatched, ok=${ok}`);
        sendResponse({ type: "filled", ok });
        return false;
    });

    const observer = new MutationObserver((records) => {
        // The closed shadow root is not observed. Ignore insertion/removal/position of our host too.
        const external = records.some((record) => !ownedHosts.has(record.target)
            && !(record.type === "childList" && [...record.addedNodes, ...record.removedNodes].every((node) => ownedHosts.has(node))));
        if (external) schedule();
    });
    observer.observe(document.documentElement, {
        childList: true, subtree: true, attributes: true,
        attributeFilter: ["type", "autocomplete", "hidden", "style", "class", "disabled", "readonly"],
    });
    window.addEventListener("popstate", schedule);
    window.addEventListener("hashchange", schedule);
    window.addEventListener("pageshow", schedule);
    window.addEventListener("resize", reposition);
    window.addEventListener("scroll", reposition, true);
    setInterval(() => { void refresh(); }, POLL_MS);
    reportLocation();
    void refresh();
})();
