/**
 * WebCrypto helpers. Used for fingerprinting/comparison only — the master
 * key never leaves the native app; the extension just receives fill payloads.
 */
/** SHA-256 of a string, hex-encoded. */
export declare function sha256Hex(text: string): Promise<string>;
/** Stable fingerprint of an item (id + title + host), for change detection. */
export declare function itemFingerprint(item: {
    id: number;
    title: string;
    host: string;
}): Promise<string>;
