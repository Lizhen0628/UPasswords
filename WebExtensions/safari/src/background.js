// Safari/Firefox background: owns the unlock session and count-only site hints.
import { canonicalizeHost, installSessionBackground, installSiteHints, hostnameOf } from "./shared/index.js";

// Session contents remain popup-only; pages receive safe counts through site hints.
const session = installSessionBackground(browser);
installSiteHints(browser, session);


// 页面地址登记表:content script 在自身上下文可读 location(零权限),
// popup 在 activeTab 拿不到 tab.url 时向这里回落取当前页地址
const pageLocations = new Map();
browser.tabs.onRemoved.addListener((tabId) => { pageLocations.delete(tabId); });

browser.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (!message || typeof message.type !== "string") {
        return false;
    }
    if (message.type === "location") {
        if (sender.tab?.id != null) {
            pageLocations.set(sender.tab.id, typeof message.href === "string" ? message.href : "");
        }
        return false;
    }
    if (message.type === "active-location") {
        (async () => {
            let href = null;
            try {
                const [tab] = await browser.tabs.query({ active: true, currentWindow: true });
                href = tab?.url ?? pageLocations.get(tab?.id) ?? null;
            } catch { href = null; }
            sendResponse({ type: "active-location", href });
        })();
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
