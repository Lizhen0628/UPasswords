import type { ExtensionAutofill, ExtensionItem } from "./types.js";

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const POLICY_VERSION = 1;
const AUTOFILL_TOKENS = new Set<ExtensionAutofill>([
    "off", "username", "current-password", "url", "one-time-code",
    "given-name", "family-name", "email", "tel", "street-address",
    "address-line1", "address-line2", "address-level1", "address-level2",
    "postal-code", "country-name", "cc-number", "cc-name", "cc-exp", "cc-csc",
]);

/** Non-secret field-level block recorded after an authoritative conflict read. */
export interface AutofillConflictGateEntry {
    itemID: string;
    fieldTokens: ExtensionAutofill[];
    wholeItem: boolean;
}

/** Account/vault-scoped, non-secret state used while the extension is offline. */
export interface StoredAutofillConflictGate {
    version: 1;
    userId: string;
    vaultId: string;
    checkedAt: number;
    entries: AutofillConflictGateEntry[];
}

interface ConflictGateInput {
    itemID: string;
    currentItem?: ExtensionItem;
    candidateItems: Array<ExtensionItem | null>;
    hasUnreadableCandidate: boolean;
    hasDeleteCandidate: boolean;
    currentDeleted: boolean;
}

function isUUID(value: unknown): value is string {
    return typeof value === "string" && UUID_PATTERN.test(value);
}

function effectiveTokens(field: ExtensionItem["fields"][number]): ExtensionAutofill[] {
    if (field.autofill !== "off") return [field.autofill];
    if (field.type === "login" || field.type === "email") return ["username"];
    if (field.type === "password") return ["current-password"];
    return [];
}

function fieldMap(item: ExtensionItem): Map<string, ExtensionItem["fields"][number]> | null {
    const fields = new Map<string, ExtensionItem["fields"][number]>();
    for (const field of item.fields) {
        if (!isUUID(field.id)) return null;
        const id = field.id.toLowerCase();
        if (fields.has(id)) return null;
        fields.set(id, field);
    }
    return fields;
}

function fieldSignature(field: ExtensionItem["fields"][number]): string {
    return JSON.stringify([field.name, field.type, field.autofill, field.value]);
}

/** Build the smallest safe autofill block for one unresolved row conflict. */
export function buildAutofillConflictGateEntry(input: ConflictGateInput): AutofillConflictGateEntry {
    const itemID = input.itemID.toLowerCase();
    if (!isUUID(input.itemID) || input.hasUnreadableCandidate || input.hasDeleteCandidate
        || input.currentDeleted || !input.currentItem
        || input.currentItem.id.toLowerCase() !== itemID
        || input.candidateItems.some((item) => item !== null && item.id.toLowerCase() !== itemID)) {
        return { itemID, fieldTokens: [], wholeItem: true };
    }
    const items = [input.currentItem, ...input.candidateItems];
    const maps = items.map((item) => item ? fieldMap(item) : null);
    if (maps.some((fields) => fields === null)) {
        return { itemID, fieldTokens: [], wholeItem: true };
    }
    const fieldIDs = new Set<string>();
    for (const fields of maps) {
        for (const id of fields?.keys() ?? []) fieldIDs.add(id);
    }
    const blocked = new Set<ExtensionAutofill>();
    for (const id of fieldIDs) {
        const values = maps.map((fields) => fields?.get(id));
        const signatures = new Set(values.map((field) => field ? fieldSignature(field) : "<missing>"));
        if (signatures.size < 2) continue;
        for (const field of values) {
            for (const token of field ? effectiveTokens(field) : []) blocked.add(token);
        }
    }
    return {
        itemID,
        fieldTokens: [...blocked].sort(),
        wholeItem: false,
    };
}

/** Validate persisted state without accepting arbitrary local-storage shapes. */
export function parseAutofillConflictGate(value: unknown): StoredAutofillConflictGate | null {
    if (typeof value !== "object" || value === null) return null;
    const record = value as Record<string, unknown>;
    if (record.version !== POLICY_VERSION || typeof record.userId !== "string" || !record.userId
        || typeof record.vaultId !== "string" || !record.vaultId
        || !Number.isSafeInteger(record.checkedAt) || (record.checkedAt as number) < 0
        || !Array.isArray(record.entries)) return null;
    const entries: AutofillConflictGateEntry[] = [];
    const seen = new Set<string>();
    for (const value of record.entries) {
        if (typeof value !== "object" || value === null) return null;
        const entry = value as Record<string, unknown>;
        if (!isUUID(entry.itemID) || seen.has(entry.itemID.toLowerCase())
            || typeof entry.wholeItem !== "boolean" || !Array.isArray(entry.fieldTokens)) return null;
        const fieldTokens = entry.fieldTokens.filter((token): token is ExtensionAutofill =>
            typeof token === "string" && AUTOFILL_TOKENS.has(token as ExtensionAutofill)
            && token !== "off");
        if (fieldTokens.length !== entry.fieldTokens.length || new Set(fieldTokens).size !== fieldTokens.length) {
            return null;
        }
        const itemID = entry.itemID.toLowerCase();
        seen.add(itemID);
        entries.push({ itemID, fieldTokens: [...fieldTokens].sort(), wholeItem: entry.wholeItem });
    }
    return {
        version: 1,
        userId: record.userId,
        vaultId: record.vaultId,
        checkedAt: record.checkedAt as number,
        entries,
    };
}

/** Return true when this fill request includes a known conflicted token. */
export function autofillConflictBlocks(
    gate: StoredAutofillConflictGate | null,
    itemID: string,
    fieldTokens: ExtensionAutofill[],
): boolean {
    if (!gate || !isUUID(itemID)) return false;
    const entry = gate.entries.find((candidate) => candidate.itemID === itemID.toLowerCase());
    if (!entry) return false;
    return entry.wholeItem || fieldTokens.some((token) => entry.fieldTokens.includes(token));
}
