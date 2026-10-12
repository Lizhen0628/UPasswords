/**
 * WebCrypto helpers. Used for fingerprinting/comparison only — the master
 * key never leaves the native app; the extension just receives fill payloads.
 */
/** SHA-256 of a string, hex-encoded. */
export async function sha256Hex(text) {
    const data = new TextEncoder().encode(text);
    const digest = await crypto.subtle.digest("SHA-256", data);
    return Array.from(new Uint8Array(digest))
        .map((b) => b.toString(16).padStart(2, "0"))
        .join("");
}
/** Stable fingerprint of an item (id + title + host), for change detection. */
export async function itemFingerprint(item) {
    return sha256Hex(`${item.id}:${item.title}:${item.host}`);
}
