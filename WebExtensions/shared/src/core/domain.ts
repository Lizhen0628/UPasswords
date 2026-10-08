/**
 * Site-origin helpers shared by background, popup and the native bridge.
 * Matching is host-based (registrable domain semantics approximated by
 * suffix matching), mirroring the host canonicalization on the app side.
 */

const wiredHosts = new Set(["www", "m", "mobile", "account", "accounts", "login", "signin", "auth"]);

/** Lower-cased hostname of a URL; empty string when unparseable. */
export function hostnameOf(url: string): string {
    try {
        return new URL(url).hostname.toLowerCase();
    } catch {
        return "";
    }
}

/** Strips common wired/technical prefixes from a hostname. */
export function canonicalizeHost(host: string): string {
    if (!host) {
        return "";
    }
    const parts = host.split(".");
    while (parts.length > 2 && wiredHosts.has(parts[0])) {
        parts.shift();
    }
    return parts.join(".");
}

/** True when an item's host matches the page host (suffix match on labels). */
export function hostMatches(pageHost: string, itemHost: string): boolean {
    const page = canonicalizeHost(pageHost);
    const item = canonicalizeHost(itemHost);
    if (!page || !item) {
        return false;
    }
    return page === item || page.endsWith("." + item) || item.endsWith("." + page);
}

/** Username/password pair for a fill request (empty strings when absent). */
export function credentialsOf(item: { fields: { type: string; value: string }[] }): {
    username: string;
    password: string;
} {
    let username = "";
    let password = "";
    for (const f of item.fields) {
        if (!username && (f.type === "login" || f.type === "email")) {
            username = f.value;
        }
        if (!password && f.type === "password") {
            password = f.value;
        }
    }
    return { username, password };
}
