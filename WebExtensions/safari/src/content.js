// Content script: fills credentials into the first matching login form.
// Triggers: popup 经 runtime.onMessage(主路径),或遗留的 DOM CustomEvent。
(function () {
    "use strict";

    const FILL_EVENT = "upasswords-fill";

    function fillIntoPage(detail) {
        const forms = Array.from(document.querySelectorAll("form"));
        const inputs = Array.from(document.querySelectorAll("input"));
        const userField =
            inputs.find((i) => i.autocomplete === "username") ||
            inputs.find((i) => /email|text|tel/i.test(i.type || ""));
        const passField = inputs.find((i) => (i.type || "").toLowerCase() === "password");
        if (userField && detail.username) {
            userField.value = detail.username;
            userField.dispatchEvent(new Event("input", { bubbles: true }));
            userField.dispatchEvent(new Event("change", { bubbles: true }));
        }
        if (passField && detail.password) {
            passField.value = detail.password;
            passField.dispatchEvent(new Event("input", { bubbles: true }));
            passField.dispatchEvent(new Event("change", { bubbles: true }));
        }
        const ok = Boolean((userField && detail.username) || (passField && detail.password));
        window.dispatchEvent(new CustomEvent("upasswords-filled", { detail: { ok } }));
        // 表单存在性仅作诊断日志,不携带任何字段值
        console.log(`[upw] fill dispatched, forms=${forms.length} ok=${ok}`);
        return ok;
    }

    browser.runtime.onMessage.addListener((message, _sender, sendResponse) => {
        if (message && message.type === "fill" && message.candidate) {
            const ok = fillIntoPage({
                username: message.candidate.username || "",
                password: message.candidate.password || "",
            });
            sendResponse({ type: "filled", ok });
            return false;
        }
        return false;
    });

    document.addEventListener(FILL_EVENT, (event) => {
        fillIntoPage(event.detail || {});
    });
})();
