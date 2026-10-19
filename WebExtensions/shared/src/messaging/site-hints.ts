import { hostMatches } from "../core/domain.js";
import type { ExtensionItem } from "../core/types.js";

/** Background-only inspection never extends the unlock timeout or accepts page context. */
interface HintSession {
    inspect(): Promise<{
        unlocked: boolean;
        items?: ExtensionItem[];
        generation?: string;
        expiresAt?: number;
    }>;
}

type SiteHint = { type: "site-hint"; count: number; unlocked: boolean };
const lockedHint = (): SiteHint => ({ type: "site-hint", count: 0, unlocked: false });

function webURL(value: unknown): URL | null {
    if (typeof value !== "string") return null;
    try {
        const url = new URL(value);
        return url.protocol === "https:" || url.protocol === "http:" ? url : null;
    } catch {
        return null;
    }
}

/** Installs count-only page hints and tab badges; plaintext stays inside the background. */
export function installSiteHints(api: any, session: HintSession): void {
    const badgeVersions = new Map<number, number>();

    async function countFor(url: URL): Promise<SiteHint> {
        const snapshot = await session.inspect();
        if (!snapshot.unlocked) return lockedHint();
        const count = (snapshot.items ?? []).filter((item) => {
            return Boolean(item.host) && hostMatches(url.hostname, item.host)
                && item.fields.some((field) => field.type === "password" && Boolean(field.value));
        }).length;
        return { type: "site-hint", count, unlocked: true };
    }

    async function authorizedPage(sender: any): Promise<URL | null> {
        if (sender?.id !== api.runtime.id || typeof sender.tab?.id !== "number"
            || sender.frameId !== 0) return null;
        const page = webURL(sender.url);
        if (!page) return null;
        const tab = await api.tabs.get(sender.tab.id);
        const current = webURL(tab?.url);
        return current?.origin === page.origin ? page : null;
    }

    async function refreshBadge(tabId: number): Promise<void> {
        if (!api.action?.setBadgeText) return;
        const version = (badgeVersions.get(tabId) ?? 0) + 1;
        badgeVersions.set(tabId, version);
        try {
            const tab = await api.tabs.get(tabId);
            if (!tab?.active) return;
            const url = webURL(tab.url);
            const hint = url ? await countFor(url) : lockedHint();
            if (badgeVersions.get(tabId) !== version) return;
            // Recheck navigation after asynchronous session inspection.
            const current = await api.tabs.get(tabId);
            if (!current?.active || current.url !== tab.url) {
                if (badgeVersions.get(tabId) === version) await refreshBadge(tabId);
                return;
            }
            if (badgeVersions.get(tabId) !== version) return;
            await api.action.setBadgeText({ tabId, text: hint.unlocked && hint.count > 0 ? String(hint.count) : "" });
            if (hint.count > 0 && api.action.setBadgeBackgroundColor) {
                try { await api.action.setBadgeBackgroundColor({ tabId, color: "#356B62" }); }
                catch { console.warn("[upw] site badge color unavailable"); }
            }
        } catch {
            // Missing tab permissions and closed tabs fail closed, never reuse an old count.
            if (badgeVersions.get(tabId) === version) {
                try { await api.action.setBadgeText({ tabId, text: "" }); }
                catch { console.warn("[upw] site badge unavailable"); }
            }
        }
    }

    function refreshActive(): void {
        void Promise.resolve(api.tabs.query({ active: true })).then((tabs: any[]) => {
            for (const tab of tabs) {
                if (typeof tab.id === "number") void refreshBadge(tab.id);
            }
        }, () => console.warn("[upw] site hint tabs unavailable"));
    }

    api.runtime.onMessage.addListener((message: any, sender: any, sendResponse: (value: unknown) => void) => {
        if (message?.type !== "site-hint" && message?.type !== "open-vault") return false;
        const denied = () => message.type === "site-hint" ? lockedHint() : { type: "vault-opened", ok: false };
        void (async () => {
            const page = await authorizedPage(sender);
            if (!page) return denied();
            if (message.type === "site-hint") {
                const hint = await countFor(page);
                // Do not return stale counts after a cross-origin navigation during inspection.
                if (!await authorizedPage(sender)) return lockedHint();
                void refreshBadge(sender.tab.id);
                return hint;
            }
            if (!api.action?.openPopup) return denied();
            await api.action.openPopup();
            console.info("[upw] site hint opened vault");
            return { type: "vault-opened", ok: true };
        })().then(sendResponse, () => {
            console.warn("[upw] site hint request unavailable");
            sendResponse(denied());
        });
        return true;
    });

    api.tabs.onActivated?.addListener(({ tabId }: { tabId: number }) => { void refreshBadge(tabId); });
    api.tabs.onUpdated?.addListener((tabId: number) => { void refreshBadge(tabId); });
    api.tabs.onRemoved?.addListener((tabId: number) => { badgeVersions.delete(tabId); });
    api.storage.onChanged?.addListener((_changes: unknown, area: string) => {
        if (area === "session" || area === "local") refreshActive();
    });
    refreshActive();
    console.info("[upw] count-only site hints installed");
}
