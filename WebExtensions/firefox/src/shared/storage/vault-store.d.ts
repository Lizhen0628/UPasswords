/**
 * browser.storage.local wrapper holding the last snapshot pushed by the
 * native app (already filtered per-origin; no cross-site payload).
 */
import type { ExtensionItem } from "../core/types.js";
interface BrowserStorageArea {
    get(keys: string[]): Promise<Record<string, unknown>>;
    set(entries: Record<string, unknown>): Promise<void>;
}
/** Injected by the platform adapters (WebExtension polyfill shape). */
export declare function setStorageArea(area: BrowserStorageArea): void;
export declare function saveItems(items: ExtensionItem[]): Promise<void>;
export declare function loadItems(): Promise<ExtensionItem[]>;
export declare function updatedAt(): Promise<number>;
export {};
