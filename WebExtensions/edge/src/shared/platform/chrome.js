/**
 * Chrome (MV3, callback-style `chrome.*`) adapter wrapped into promises.
 */
export const chromeAdapter = {
    kind: "chrome",
    activeTabURL: () => new Promise((resolve) => {
        chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => resolve(tabs[0]?.url ?? ""));
    }),
    storageArea: () => ({
        get: (keys) => new Promise((resolve) => chrome.storage.local.get(keys, resolve)),
        set: (entries) => new Promise((resolve) => chrome.storage.local.set(entries, () => resolve())),
    }),
    runtime: () => ({
        // 回调式 API 必须触碰 lastError,否则接收端缺席时控制台刷
        // "Unchecked runtime.lastError" 且 Promise 静默 resolve(undefined)
        sendMessage: (message) => new Promise((resolve) => chrome.runtime.sendMessage(message, (response) => {
            void chrome.runtime.lastError;
            resolve(response);
        })),
        onMessage: (listener) => chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
            const result = listener(message, sender);
            if (result instanceof Promise) {
                result.then(sendResponse);
                return true;
            }
            return undefined;
        }),
    }),
};
