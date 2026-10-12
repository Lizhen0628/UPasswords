// Chrome/Edge MV3 service worker: answers host queries from the popup using the
// shared domain core (promise-wrapped chrome.* adapter shape).
import { canonicalizeHost, credentialsOf, hostMatches, loadItems, clearItems, purgeIfStale } from "./shared/index.js";

// query 返回含明文密码的候选,只服务扩展自身页面(popup);
// content script 上下文与任何外部来源一律拒绝
const ownOrigin = chrome.runtime.getURL("");
const isOwnPage = (sender) => typeof sender.url === "string" && sender.url.startsWith(ownOrigin);

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (message && message.type === "query") {
        if (!isOwnPage(sender)) {
            sendResponse({ type: "error", message: "forbidden sender" });
            return false;
        }
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

// 浏览器启动/扩展安装更新即视为锁定:清掉上次会话遗留的明文条目
chrome.runtime.onStartup.addListener(() => { void clearItems(); });
chrome.runtime.onInstalled.addListener(() => { void clearItems(); });

// 周期闹钟主动擦除过期明文(不等下次读取;MV3 SW 挂起期间明文会静态驻留)
chrome.alarms.create("upw-purge", { periodInMinutes: 1 });
chrome.alarms.onAlarm.addListener(() => { void purgeIfStale(); });

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
