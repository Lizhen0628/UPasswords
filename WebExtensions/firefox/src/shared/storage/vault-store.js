/**
 * browser.storage.local wrapper holding the last snapshot pushed by the
 * native app (already filtered per-origin; no cross-site payload).
 */
const itemsKey = "vault.items";
const updatedAtKey = "vault.updatedAt";
/** Injected by the platform adapters (WebExtension polyfill shape). */
export function setStorageArea(area) {
    storageArea = area;
}
let storageArea = null;
export async function saveItems(items) {
    if (!storageArea) {
        throw new Error("storage area not configured");
    }
    await storageArea.set({ [itemsKey]: items, [updatedAtKey]: Date.now() });
}
export async function loadItems() {
    if (!storageArea) {
        return [];
    }
    const bag = await storageArea.get([itemsKey]);
    const value = bag[itemsKey];
    return Array.isArray(value) ? value : [];
}
export async function updatedAt() {
    if (!storageArea) {
        return 0;
    }
    const bag = await storageArea.get([updatedAtKey]);
    return typeof bag[updatedAtKey] === "number" ? bag[updatedAtKey] : 0;
}
