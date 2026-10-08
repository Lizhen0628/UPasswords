/**
 * Platform seam: the shared core depends only on this narrow interface.
 * safari.ts / chrome.ts bind it to the concrete global APIs.
 */

export interface BrowserAdapter {
    readonly kind: "safari" | "chrome";
    /** Current tab URL (active tab), empty string when unavailable. */
    activeTabURL(): Promise<string>;
    /** Local storage area (browser.storage.local). */
    storageArea(): {
        get(keys: string[]): Promise<Record<string, unknown>>;
        set(entries: Record<string, unknown>): Promise<void>;
    };
    /** Runtime messaging port for request/response. */
    runtime(): {
        sendMessage(message: unknown): Promise<unknown>;
        onMessage(listener: (message: unknown, sender: unknown) => unknown): void;
    };
}
