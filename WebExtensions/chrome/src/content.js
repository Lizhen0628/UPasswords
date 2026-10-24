// 职责：观察当前顶层 HTTP(S) 页面的表单并展示候选数量提示。
// 页面可见消息不含字段值；实际填充由用户打开可信 popup 后主动触发。
// Pages receive only a match count and profile-availability flag. Values are filled only by the trusted popup.
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

    const profileTokens = new Set([
        "given-name", "family-name", "email", "tel", "street-address",
        "address-line1", "address-line2", "address-level1", "address-level2",
        "postal-code", "country-name",
    ]);

    function autocompleteToken(field) {
        const tokens = (field.autocomplete ?? "").trim().toLowerCase().split(/\s+/);
        return tokens[tokens.length - 1];
    }

    function registrationFields() {
        const fields = Array.from(document.querySelectorAll("input, textarea")).filter(isVisible);
        const contactFields = fields.filter((field) => profileTokens.has(autocompleteToken(field)));
        for (const anchor of contactFields) {
            const scope = anchor.form || anchor.closest('[role="form"]') || anchor.parentElement;
            const nearby = fields.filter((field) => scope?.contains(field));
            const contacts = contactFields.filter((field) => scope?.contains(field));
            const newPassword = nearby.some((field) => (field.type ?? "").toLowerCase() === "password"
                && autocompleteToken(field) === "new-password");
            if (contacts.length >= 2 || (newPassword && contacts.length > 0)) {
                return { fields: contacts, anchor };
            }
        }
        return null;
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

    function showHint(count, field, profileAvailable = false) {
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
        const state = `${count}:${profileAvailable}`;
        if (renderedState !== state) {
            const credentials = count > 0
                ? (chinese ? `${count} 个匹配密码` : `${count} matching password${count === 1 ? "" : "s"}`)
                : "";
            const profile = profileAvailable ? (chinese ? "个人资料可填充" : "Personal info available") : "";
            const details = [credentials, profile].filter(Boolean).join(" · ");
            button.textContent = `UPasswords · ${details}`;
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
        const registration = registrationFields();
        if (!fields && !registration) {
            removeHint();
            return;
        }
        try {
            const response = await api.runtime.sendMessage({ type: "site-hint", registration: Boolean(registration) });
            if (request !== sequence || href !== location.href) return;
            const current = loginFields();
            const currentRegistration = registrationFields();
            if ((!current && !currentRegistration) || response?.type !== "site-hint" || !response.unlocked
                || !Number.isSafeInteger(response.count)
                || (response.count <= 0 && !(currentRegistration && response.profileAvailable))) {
                removeHint();
                return;
            }
            showHint(response.count, currentRegistration?.anchor ?? current?.anchor, Boolean(response.profileAvailable));
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

    function setField(field, value, onlyEmpty = false) {
        if (!field || typeof value !== "string" || !value || !isVisible(field)
            || (onlyEmpty && field.value)) return false;
        const prototype = field.tagName === "TEXTAREA" ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
        const setter = Object.getOwnPropertyDescriptor(prototype, "value")?.set;
        if (!setter) return false;
        setter.call(field, value);
        field.dispatchEvent(new Event("input", { bubbles: true }));
        field.dispatchEvent(new Event("change", { bubbles: true }));
        return true;
    }

    api.runtime.onMessage.addListener((message, sender, sendResponse) => {
        if (message?.type === "registration-check") {
            sendResponse(Boolean(registrationFields()));
            return false;
        }
        if (message?.type !== "fill") return false;
        const trusted = sender?.id === api.runtime.id && sender.url === popupURL && sender.tab == null
            && message.expectedOrigin === location.origin;
        if (!trusted || !message.candidate) {
            sendResponse({ type: "filled", ok: false });
            return false;
        }
        const profile = message.candidate.item?.recordType === "userProfile";
        let ok = false;
        if (profile && message.candidate.item.autofillEnabled !== false) {
            const registration = registrationFields();
            if (registration && Array.isArray(message.candidate.item.fields)) {
                const values = new Map(message.candidate.item.fields
                    .filter((field) => profileTokens.has(field.autofill) && typeof field.value === "string")
                    .map((field) => [field.autofill, field.value]));
                if (!values.has("street-address")) {
                    const address = [values.get("address-line1"), values.get("address-line2")]
                        .filter(Boolean).join("\n");
                    if (address) values.set("street-address", address);
                }
                for (const field of registration.fields) {
                    const token = autocompleteToken(field);
                    const value = values.get(token)
                        || (token === "address-line1" ? values.get("street-address")?.split(/\r?\n/)[0] : "");
                    if (setField(field, value, true)) ok = true;
                }
            }
        } else if (!profile) {
            const fields = loginFields();
            const usernameFilled = setField(fields?.username, message.candidate.username);
            const passwordFilled = setField(fields?.password, message.candidate.password);
            ok = usernameFilled || passwordFilled;
        }
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
