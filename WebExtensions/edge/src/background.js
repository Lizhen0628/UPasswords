// Chrome/Edge MV3 service worker: owns the unlock session and count-only site hints.
import { canonicalizeHost, installSessionBackground, installSiteHints } from "./shared/index.js";

// Session contents remain popup-only; pages receive safe counts through site hints.
const session = installSessionBackground(chrome);
installSiteHints(chrome, session);

// 页面地址登记表:content script 在自身上下文可读 location(零权限),
// popup 在 activeTab 拿不到 tab.url 时向这里回落取当前页地址
const pageLocations = new Map();
chrome.tabs.onRemoved.addListener((tabId) => { pageLocations.delete(tabId); });

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (message && message.type === "location") {
        if (sender.tab?.id != null) {
            pageLocations.set(sender.tab.id, typeof message.href === "string" ? message.href : "");
        }
        return false;
    }
    if (message && message.type === "active-location") {
        (async () => {
            let href = null;
            try {
                const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
                href = tab?.url ?? pageLocations.get(tab?.id) ?? null;
            } catch { href = null; }
            sendResponse({ type: "active-location", href });
        })();
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
