// Safari/Firefox background (standalone): data comes from the relay API via the
// popup (login/unlock/decrypt happen there); background answers "query" from the
// decrypted snapshot in browser.storage.local. Never logs secrets.
import { canonicalizeHost, credentialsOf, hostMatches, loadItems, clearItems, purgeIfStale, hostnameOf } from "./shared/index.js";

// query 返回含明文密码的候选,只服务扩展自身页面(popup);
// content script 上下文与任何外部来源一律拒绝
const ownOrigin = browser.runtime.getURL("");
const isOwnPage = (sender) => typeof sender.url === "string" && sender.url.startsWith(ownOrigin);

async function queryItems(host) {
    const items = await loadItems();
    const candidates = items
        .filter((item) => hostMatches(host, item.host))
        .map((item) => ({ item, ...credentialsOf(item) }));
    return { type: "items", candidates };
}

browser.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (!message || typeof message.type !== "string") {
        return false;
    }
    if (message.type === "query") {
        if (!isOwnPage(sender)) {
            sendResponse({ type: "error", message: "forbidden sender" });
            return false;
        }
        queryItems(message.host)
            .then(sendResponse)
            .catch(() => sendResponse({ type: "error", message: "query failed" }));
        return true;
    }
    return false;
});

// 浏览器启动/扩展安装更新即视为锁定:清掉上次会话遗留的明文条目
browser.runtime.onStartup?.addListener(() => { void clearItems(); });
browser.runtime.onInstalled?.addListener(() => { void clearItems(); });

// 周期闹钟主动擦除过期明文(不等下次读取;事件页挂起期间明文会静态驻留)
browser.alarms?.create("upw-purge", { periodInMinutes: 1 });
browser.alarms?.onAlarm?.addListener(() => { void purgeIfStale(); });

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
