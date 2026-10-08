// Content script: listens for fill requests dispatched from the popup and
// writes credentials into the first matching login form on the page.
(function () {
    "use strict";

    const FILL_EVENT = "upasswords-fill";

    document.addEventListener(FILL_EVENT, (event) => {
        const detail = event.detail || {};
        const forms = Array.from(document.querySelectorAll("form"));
        const inputs = Array.from(document.querySelectorAll("input"));
        const userField =
            inputs.find((i) => i.autocomplete === "username") ||
            inputs.find((i) => /email|text|tel/i.test(i.type || ""));
        const passField = inputs.find((i) => (i.type || "").toLowerCase() === "password");
        if (userField && detail.username) {
            userField.value = detail.username;
            userField.dispatchEvent(new Event("input", { bubbles: true }));
        }
        if (passField && detail.password) {
            passField.value = detail.password;
            passField.dispatchEvent(new Event("input", { bubbles: true }));
        }
        window.dispatchEvent(new CustomEvent("upasswords-filled", { detail: { ok: !!(userField || passField) } }));
        // 表单存在性仅作诊断日志,不携带任何字段值
        console.log(`[upw] fill dispatched, forms=${forms.length}`);
    });
})();
