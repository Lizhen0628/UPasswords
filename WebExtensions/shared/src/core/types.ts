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
    id: string; // UUID v4 (v7 row-sync item identity)
    title: string;
    symbol: string | null;
    fields: ExtensionField[];
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

export interface FillCandidate {
    item: FillItem;
    username: string;
    password: string;
}
