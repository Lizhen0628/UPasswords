/**
 * Data contract between the extension front end and the native app.
 * Mirrors Contracts/schemas/upw-database.schema.json (Card/Field shapes);
 * never carry plaintext secrets beyond the fill moment.
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
    | "cc-number"
    | "cc-name"
    | "cc-exp"
    | "cc-csc";

export interface ExtensionField {
    name: string;
    type: ExtensionFieldType;
    value: string;
    autofill: ExtensionAutofill;
}

/** A vault entry handed to the extension for one origin. */
export interface ExtensionItem {
    id: number;
    title: string;
    symbol: string | null;
    fields: ExtensionField[];
    /** Canonical site this item belongs to (empty = any origin). */
    host: string;
}

export interface FillCandidate {
    item: ExtensionItem;
    username: string;
    password: string;
}
