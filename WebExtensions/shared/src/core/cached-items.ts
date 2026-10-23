import type { ExtensionItem } from "./types.js";
import { fragmentsToXml, parseVaultXml, VaultCryptoError } from "./vault-crypto.js";

export interface VaultFragment {
    uuid: string;
    xml: string;
    kind: number;
    revision: number;
    modifiedMs: number;
}

/** Validate identity even for labels and inactive cards that have no visible projection. */
export function projectVaultFragment(fragment: VaultFragment): ExtensionItem | null {
    const canonicalUuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
    if (!canonicalUuid.test(fragment.uuid) || ![1, 2, 3].includes(fragment.kind)
        || !Number.isSafeInteger(fragment.modifiedMs) || fragment.modifiedMs < 0) {
        throw new VaultCryptoError("bad_item_identity");
    }
    if (/<!DOCTYPE|<!ENTITY/i.test(fragment.xml)) throw new VaultCryptoError("bad_xml");
    if (typeof DOMParser === "undefined") throw new VaultCryptoError("dom_unavailable");
    const document = new DOMParser().parseFromString(fragment.xml, "application/xml");
    const root = document.documentElement;
    if (document.querySelector("parsererror") || !root || root.namespaceURI
        || root.tagName !== (fragment.kind === 1 ? "card" : fragment.kind === 2 ? "label" : "user_profile")
        || root.getAttribute("id")?.toLowerCase() !== fragment.uuid.toLowerCase()
        || !Number.isSafeInteger(fragment.revision) || fragment.revision < 1) {
        throw new VaultCryptoError("bad_item_identity");
    }
    if (fragment.kind === 2) return null;
    if (root.querySelector("card, user_profile")) throw new VaultCryptoError("bad_item_identity");
    if (["trashed", "archived", "template"].some(
        name => root.getAttribute(name) === "true")) return null;
    const items = parseVaultXml(fragmentsToXml([fragment.xml]));
    if (items.length !== 1 || items[0].id.toLowerCase() !== fragment.uuid.toLowerCase()) {
        throw new VaultCryptoError("bad_item_identity");
    }
    return { ...items[0], source: { xml: fragment.xml, revision: fragment.revision } };
}
