/**
 * browser.storage.local wrapper holding the last snapshot pushed by the
 * native app (already filtered per-origin; no cross-site payload).
 */

import type { ExtensionItem } from "../core/types.js";

const itemsKey = "vault.items";
const updatedAtKey = "vault.updatedAt";

interface BrowserStorageArea {
    get(keys: string[]): Promise<Record<string, unknown>>;
    set(entries: Record<string, unknown>): Promise<void>;
}

/** Injected by the platform adapters (WebExtension polyfill shape). */
export function setStorageArea(area: BrowserStorageArea): void {
    storageArea = area;
}

let storageArea: BrowserStorageArea | null = null;

export async function saveItems(items: ExtensionItem[]): Promise<void> {
    if (!storageArea) {
        throw new Error("storage area not configured");
    }
    await storageArea.set({ [itemsKey]: items, [updatedAtKey]: Date.now() });
}

export async function loadItems(): Promise<ExtensionItem[]> {
    if (!storageArea) {
        return [];
    }
    const bag = await storageArea.get([itemsKey]);
    const value = bag[itemsKey];
    return Array.isArray(value) ? (value as ExtensionItem[]) : [];
}

export async function updatedAt(): Promise<number> {
    if (!storageArea) {
        return 0;
    }
    const bag = await storageArea.get([updatedAtKey]);
    return typeof bag[updatedAtKey] === "number" ? (bag[updatedAtKey] as number) : 0;
}
