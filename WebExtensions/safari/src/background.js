// Safari background script: answers host queries from the popup using the
// shared domain core. Vault payload arrives via the native bridge later.
import { canonicalizeHost, credentialsOf, hostMatches, loadItems, hostnameOf } from "./shared/index.js";

browser.runtime.onMessage.addListener((message, _sender, sendResponse) => {
    if (message && message.type === "query") {
        loadItems()
            .then((items) => {
                const candidates = items
                    .filter((item) => hostMatches(message.host, item.host))
                    .map((item) => ({ item, ...credentialsOf(item) }));
                sendResponse({ type: "items", candidates });
            })
            .catch(() => sendResponse({ type: "error", message: "query failed" }));
        return true;
    }
    if (message && message.type === "ping") {
        sendResponse({ type: "pong" });
        return false;
    }
    return false;
});

// Log canonical host of the active tab on install-ish startup for debugging.
browser.tabs
    .query({ active: true, currentWindow: true })
    .then((tabs) => {
        const host = hostnameOf(tabs[0]?.url ?? "");
        if (host) {
            console.log(`[upw] background ready, active host: ${canonicalizeHost(host)}`);
        }
    })
    .catch(() => {});
