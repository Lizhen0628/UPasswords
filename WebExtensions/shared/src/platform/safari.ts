/**
 * Safari (WebExtension polyfill: `browser.*`) adapter.
 */

import type { BrowserAdapter } from "./adapter.js";

declare const browser: {
    tabs: { query(info: { active: boolean; currentWindow: boolean }): Promise<{ url?: string }[]> };
    storage: { local: { get(keys: string[]): Promise<Record<string, unknown>>; set(e: Record<string, unknown>): Promise<void> } };
    runtime: {
        sendMessage(message: unknown): Promise<unknown>;
        onMessage: { addListener(listener: (message: unknown, sender: unknown) => unknown): void };
    };
};

export const safariAdapter: BrowserAdapter = {
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
