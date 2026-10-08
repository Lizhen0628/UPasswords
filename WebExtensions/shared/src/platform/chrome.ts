/**
 * Chrome (MV3, callback-style `chrome.*`) adapter wrapped into promises.
 */

import type { BrowserAdapter } from "./adapter.js";

declare const chrome: {
    tabs: { query(info: { active: boolean; currentWindow: boolean }, cb: (tabs: { url?: string }[]) => void): void };
    storage: { local: { get(keys: string[], cb: (bag: Record<string, unknown>) => void): void; set(e: Record<string, unknown>, cb?: () => void): void } };
    runtime: {
        sendMessage(message: unknown, cb: (response: unknown) => void): void;
        onMessage: { addListener(listener: (message: unknown, sender: unknown, sendResponse: (r: unknown) => void) => boolean | undefined): void };
    };
};

export const chromeAdapter: BrowserAdapter = {
    kind: "chrome",
    activeTabURL: () =>
        new Promise((resolve) => {
            chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => resolve(tabs[0]?.url ?? ""));
        }),
    storageArea: () => ({
        get: (keys) => new Promise((resolve) => chrome.storage.local.get(keys, resolve)),
        set: (entries) => new Promise((resolve) => chrome.storage.local.set(entries, () => resolve())),
    }),
    runtime: () => ({
        sendMessage: (message) => new Promise((resolve) => chrome.runtime.sendMessage(message, resolve)),
        onMessage: (listener) =>
            chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
                const result = listener(message, sender);
                if (result instanceof Promise) {
                    result.then(sendResponse);
                    return true;
                }
                return undefined;
            }),
    }),
};
