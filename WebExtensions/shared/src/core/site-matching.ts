import { canonicalizeHost, hostnameOf, safeWebsiteUrl } from "./domain.js";
import type { SiteAssociation, SiteMatchMode } from "./types.js";

const MATCH_MODES = new Set<SiteMatchMode>(["domain", "wildcard", "exactURL"]);

/** Parse and validate one persisted site association. */
export function parseSiteAssociation(value: unknown): SiteAssociation | null {
    if (!value || typeof value !== "object") return null;
    const association = value as Record<string, unknown>;
    if (typeof association.url !== "string" || typeof association.mode !== "string"
        || !MATCH_MODES.has(association.mode as SiteMatchMode)) return null;
    const raw = association.url.trim();
    if (!raw || raw.length > 2048 || /[\u0000-\u001f\\]/.test(raw)) return null;
    const wildcard = association.mode === "wildcard";
    if (wildcard !== raw.includes("*")) return null;
    const safe = safeWebsiteUrl(wildcard ? raw.replaceAll("*", "wildcard-token") : raw);
    if (!safe) return null;
    return { url: wildcard ? raw : safe, mode: association.mode as SiteMatchMode };
}

/** Parse a wildcard URL into an anchored, escaped, case-insensitive expression. */
function wildcardExpression(pattern: string): RegExp | null {
    if (pattern.length > 2048 || /[\u0000-\u001f\\]/.test(pattern)) return null;
    const escaped = pattern.split("*").map(part => part.replace(/[.+?^${}()|[\]\\]/g, "\\$&")).join(".*");
    try {
        return new RegExp(`^${escaped}$`, "i");
    } catch {
        return null;
    }
}

/** Match a top-level HTTP(S) page against one association without broad suffix guessing. */
export function siteAssociationMatches(pageURL: string, association: SiteAssociation): boolean {
    const parsed = parseSiteAssociation(association);
    if (!parsed) return false;
    let page: URL;
    try {
        page = new URL(pageURL);
    } catch {
        return false;
    }
    if (page.protocol !== "http:" && page.protocol !== "https:") return false;
    if (parsed.mode === "exactURL") {
        try {
            return new URL(page.href).href === new URL(parsed.url).href;
        } catch {
            return false;
        }
    }
    if (parsed.mode === "wildcard") return wildcardExpression(parsed.url)?.test(page.href) ?? false;
    const targetHost = hostnameOf(parsed.url);
    const pageHost = canonicalizeHost(page.hostname);
    const domain = canonicalizeHost(targetHost);
    return Boolean(pageHost && domain && (pageHost === domain || pageHost.endsWith(`.${domain}`)));
}

/** Match any explicit website association, or the legacy single website value as a domain. */
export function itemMatchesPage(pageURL: string, item: { host: string; sites?: SiteAssociation[] }): boolean {
    const sites = item.sites?.length ? item.sites : item.host ? [{ url: item.host, mode: "domain" as const }] : [];
    return sites.some(site => siteAssociationMatches(pageURL, site));
}

/** Match a page hostname and the stored URL for callers that only retain an origin host. */
export function siteMatchesHost(pageHost: string, item: { host: string; sites?: SiteAssociation[] }): boolean {
    return itemMatchesPage(`https://${pageHost}/`, item);
}

export function isSiteMatchMode(value: unknown): value is SiteMatchMode {
    return typeof value === "string" && MATCH_MODES.has(value as SiteMatchMode);
}
