// Safari background script: native-bridge first (live vault in the host app),
// falling back to the browser.storage.local snapshot. Never logs secrets.
import { canonicalizeHost, credentialsOf, hostMatches, loadItems, hostnameOf } from "./shared/index.js";

const NATIVE_APP_ID = "com.upasswords.UPasswords";

// 原生桥调用;Safari 要求携带宿主 App 的 bundle id。
async function nativeCall(message) {
    return await browser.runtime.sendNativeMessage(NATIVE_APP_ID, message);
}

async function queryItems(host) {
    try {
        const response = await nativeCall({ type: "query", host });
        if (response && (response.type === "items" || response.type === "locked")) {
            return response;
        }
    } catch {
        // 原生桥不可用(主 App 未装/未签名):回落本地快照
        console.log("[upw] native bridge unavailable, falling back to snapshot");
    }
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
    if (message.type === "unlock" || message.type === "ping") {
        nativeCall(message)
            .then(sendResponse)
            .catch(() => sendResponse({ type: "error", message: "native bridge unavailable" }));
        return true;
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
