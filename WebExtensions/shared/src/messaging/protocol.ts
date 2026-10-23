/**
 * Message contract between content script / popup / background and the
 * native app bridge. Every message carries a literal `type` tag.
 */

import type { ExtensionItem, FillCandidate } from "../core/types.js";

/** Encrypted row metadata is preserved unchanged by background decryption. */
export interface VaultSessionRow {
    uuid: string;
    bodyB64: string;
    revision: number;
    kind: 1 | 2 | 3;
    modifiedMs: number;
}

export interface VaultSessionFragment {
    uuid: string;
    xml: string;
    revision: number;
    kind: 1 | 2 | 3;
    modifiedMs: number;
}

/** Popup-only commands; background validates the sender and account binding. */
export interface VaultSessionRequest {
    type: "vault-session";
    action: "read" | "begin" | "commit" | "touch" | "replace" | "lock" | "decrypt" | "refresh";
    context?: { vaultId: string; token: string; userId?: string };
    generation?: string;
    items?: ExtensionItem[];
    item?: ExtensionItem;
    /** Commit only: never included in any response. */
    vaultKey?: number[];
    passwordVersion?: number;
    snapshotVersion?: number;
    expectedSnapshotVersion?: number;
    rows?: VaultSessionRow[];
}

export interface VaultSessionResponse {
    type: "vault-session";
    unlocked: boolean;
    items?: ExtensionItem[];
    generation?: string;
    expiresAt?: number;
    persistent?: boolean;
    snapshotVersion?: number;
    passwordVersion?: number;
    fragments?: VaultSessionFragment[];
    code?: string;
}

export type RequestMessage =
    | VaultSessionRequest
    | { type: "ping" }
    | { type: "query"; host: string }
    | { type: "fill"; candidate: FillCandidate; expectedOrigin: string }
    | { type: "site-hint"; registration?: boolean }
    | { type: "registration-check" }
    | { type: "open-vault" }
    | { type: "unlock"; password: string }
    /** content→bg:登记自身页面地址(popup 无 tabs 权限时的事实来源) */
    | { type: "location"; href: string }
    /** popup→bg:取当前活动页地址(tab.url 不可见时的回落) */
    | { type: "active-location" };

export type ResponseMessage =
    | VaultSessionResponse
    | { type: "pong" }
    | { type: "site-hint"; count: number; unlocked: boolean; profileAvailable: boolean }
    | { type: "vault-opened"; ok: boolean }
    | { type: "active-location"; href: string | null }
    | { type: "items"; candidates: FillCandidate[] }
    | { type: "filled"; ok: boolean }
    | { type: "unlocked"; ok: boolean; count: number }
    | { type: "locked" }
    | { type: "error"; message: string };

export function isRequestMessage(value: unknown): value is RequestMessage {
    if (typeof value !== "object" || value === null) {
        return false;
    }
    const type = (value as { type?: unknown }).type;
    if (type === "vault-session") {
        const action = (value as { action?: unknown }).action;
        return typeof action === "string" && ["read", "begin", "commit", "touch", "replace", "lock", "decrypt", "refresh"].includes(action);
    }
    return type === "ping" || type === "query" || type === "fill" || type === "unlock"
        || type === "location" || type === "active-location"
        || type === "site-hint" || type === "open-vault" || type === "registration-check";
}
