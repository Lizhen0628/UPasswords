// Safari background script (standalone): data comes from the relay API via the
// popup (login/unlock/decrypt happen there); background answers "query" from
// the decrypted snapshot in browser.storage.local. Never logs secrets.
import { canonicalizeHost, credentialsOf, hostMatches, loadItems, hostnameOf } from "./shared/index.js";

async function queryItems(host) {
    const items = await loadItems();
    const candidates = items
        .filter((item) => hostMatches(host, item.host))
        .map((item) => ({ item, ...credentialsOf(item) }));
    return { type: "items", candidates };
}

browser.runtime.onMessage.addListener((message, _sender, sendResponse) => {
    if (!message || typeof message.type !== "string") {
        return false;
    }
    if (message.type === "query") {
        queryItems(message.host)
            .then(sendResponse)
            .catch(() => sendResponse({ type: "error", message: "query failed" }));
        return true;
    }
    return false;
});

// Log canonical host of the active tab on startup for debugging.
browser.tabs
    .query({ active: true, currentWindow: true })
    .then((tabs) => {
        const host = hostnameOf(tabs[0]?.url ?? "");
        if (host) {
            console.log(`[upw] background ready, active host: ${canonicalizeHost(host)}`);
        }
    })
    .catch(() => {});
