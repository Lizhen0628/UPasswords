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
    if (page === item) {
        return true;
    }
    // 单标签 host(com / io / 2.3 这类)禁止后缀泛匹配:库内存了裸公共后缀
    // 或 IP 尾段的条目时,任意外部域名不能命中拿到候选
    const hasParent = (host: string) => host.split(".").filter(Boolean).length >= 2;
    if (!hasParent(item) || !hasParent(page)) {
        return false;
    }
    // 纯数字标签(IP 字面量或其尾段)只允许全等:后缀匹配会把 1.2.3.4 误配给 2.3.4
    const isNumericHost = (host: string) => host.split(".").every((part) => /^\d+$/.test(part));
    if (isNumericHost(page) || isNumericHost(item)) {
        return false;
    }
    return page.endsWith("." + item) || item.endsWith("." + page);
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
