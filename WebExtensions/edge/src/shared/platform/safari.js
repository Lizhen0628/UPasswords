/**
 * Safari (WebExtension polyfill: `browser.*`) adapter.
 */
export const safariAdapter = {
    kind: "safari",
    activeTabURL: async () => {
        const tabs = await browser.tabs.query({ active: true, currentWindow: true });
        return tabs[0]?.url ?? "";
    },
    storageArea: () => browser.storage.local,
    runtime: () => ({
        sendMessage: (message) => browser.runtime.sendMessage(message),
        onMessage: (listener) => browser.runtime.onMessage.addListener(listener),
    }),
};
