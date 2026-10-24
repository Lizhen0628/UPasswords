/**
 * Data contract between the extension front end and the native app.
 * Mirrors Contracts/schemas/upw-database.schema.json (Card/Field shapes);
 * 明文只在可信解锁会话与用户主动填充期间使用；持久化缓存仅保存密文。
 */

/** Field types — same vocabulary as the database XML `type` attribute. */
export type ExtensionFieldType =
    | "login"
    | "password"
    | "pin"
    | "number"
    | "date"
    | "phone"
    | "website"
    | "email"
    | "one_time_password"
    | "text"
    | "expiry"
    | "secret";

/** HTML autocomplete tokens — the XML `autofill` attribute vocabulary. */
export type ExtensionAutofill =
    | "off"
    | "username"
    | "current-password"
    | "url"
    | "one-time-code"
    | "given-name"
    | "family-name"
    | "email"
    | "tel"
    | "street-address"
    | "address-line1"
    | "address-line2"
    | "address-level1"
    | "address-level2"
    | "postal-code"
    | "country-name"
    | "cc-number"
    | "cc-name"
    | "cc-exp"
    | "cc-csc";

/** 扩展使用的字段投影，value 为明文，只在可信解锁会话和主动填充时消费。 */
export interface ExtensionField {
    name: string;
    type: ExtensionFieldType;
    value: string;
    autofill: ExtensionAutofill;
}

/** A vault entry handed to the extension for one origin. */
export interface ExtensionItem {
    /** Dedicated encrypted profile record; absent for ordinary password cards. */
    recordType?: "userProfile";
    id: string; // UUID v4 row-sync item identity
    title: string;
    symbol: string | null;
    fields: ExtensionField[];
    /** False disables filling this item even when the site and fields match. */
    autofillEnabled?: boolean;
    /** Website hostname or HTTP(S) URL; empty never matches a page. */
    host: string;
    /** Original decrypted fragment and CAS revision, kept only in the unlocked session; never send for filling. */
    source?: { xml: string; revision: number };
    /** Plain-text/Markdown notes for an in-memory detail view. */
    notes?: string;
    /** Native favorite flag for the unlocked vault's daily-workflow projection. */
    favorite?: boolean;
}

/** Source XML and detail notes are forbidden even when assigning a structurally compatible session item. */
export type FillItem = Omit<ExtensionItem, "source" | "notes"> & {
    source?: never;
    notes?: never;
};

/** 一次主动填充的候选及提取出的登录凭据，不得加入日志。 */
export interface FillCandidate {
    item: FillItem;
    username: string;
    password: string;
}
