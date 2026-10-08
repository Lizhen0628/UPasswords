// Chrome MV3 service worker: answers host queries from the popup using the
// shared domain core (promise-wrapped chrome.* adapter shape).
import { canonicalizeHost, credentialsOf, hostMatches, loadItems } from "./shared/index.js";

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
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
    }
    return false;
});

// 启动诊断:打印当前标签页的规范化 host,不携带任何凭据
chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
    try {
        const url = tabs[0]?.url ?? "";
        const host = url ? new URL(url).hostname : "";
        if (host) {
            console.log(`[upw] service worker ready, active host: ${canonicalizeHost(host)}`);
        }
    } catch {
        // URL 不可解析(如 chrome:// 页面)时保持沉默
    }
});
