/**
 * Site-origin helpers shared by background, popup and the native bridge.
 * Matching is host-based (registrable domain semantics approximated by
 * suffix matching), mirroring the host canonicalization on the app side.
 */
/** Lower-cased hostname of a URL; empty string when unparseable. */
export declare function hostnameOf(url: string): string;
/** Strips common wired/technical prefixes from a hostname. */
export declare function canonicalizeHost(host: string): string;
/** True when an item's host matches the page host (suffix match on labels). */
export declare function hostMatches(pageHost: string, itemHost: string): boolean;
/** Username/password pair for a fill request (empty strings when absent). */
export declare function credentialsOf(item: {
    fields: {
        type: string;
        value: string;
    }[];
}): {
    username: string;
    password: string;
};
