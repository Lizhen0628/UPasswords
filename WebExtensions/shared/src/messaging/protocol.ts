/**
 * Message contract between content script / popup / background and the
 * native app bridge. Every message carries a literal `type` tag.
 */

import type { ExtensionItem, FillCandidate } from "../core/types.js";
import type { RelayItemRow } from "../api/relay.js";
import type {
    EncryptedSyncQuarantineItem,
    SyncQuarantineIdentity,
    SyncQuarantineReason,
} from "../core/sync-quarantine.js";
import type {
    BackupAttachmentDescriptor,
    BackupConflictDescriptor,
    BackupInfo,
    BackupIssue,
} from "../core/portable-backup-package.js";

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

export interface VaultSessionBackupMetadata {
    createdAtMs: number;
    headSequence?: number;
    attachments: BackupAttachmentDescriptor[];
    conflicts: BackupConflictDescriptor[];
    issues: BackupIssue[];
}

/** Popup-only commands; background validates the sender and account binding. */
export interface VaultSessionRequest {
    type: "vault-session";
    action: "read" | "begin" | "commit" | "touch" | "replace" | "lock" | "decrypt" | "decrypt-attachment" | "encrypt" | "encrypt-attachment" | "refresh" | "seal-quarantine" | "open-quarantine" | "seal-backup";
    context?: { vaultId: string; token: string; userId?: string };
    generation?: string;
    items?: ExtensionItem[];
    item?: ExtensionItem;
    /** Commit only: never included in any response. */
    vaultKey?: number[];
    /** Public password-protected key envelope paired with the committed key. */
    envelopeB64?: string;
    passwordVersion?: number;
    snapshotVersion?: number;
    expectedSnapshotVersion?: number;
    rows?: VaultSessionRow[];
    /** Encrypt one reviewed conflict candidate without exposing the vault key. */
    uuid?: string;
    xml?: string;
    attachmentID?: string;
    contentVersion?: string;
    cipherB64?: string;
    dekWrappedB64?: string;
    plaintextB64?: string;
    quarantineIdentity?: SyncQuarantineIdentity;
    quarantineRow?: RelayItemRow;
    quarantine?: EncryptedSyncQuarantineItem;
    backupXml?: string;
    backupMetadata?: VaultSessionBackupMetadata;
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
    bodyB64?: string;
    attachmentB64?: string;
    cipherB64?: string;
    dekWrappedB64?: string;
    failures?: { uuid: string; reason: SyncQuarantineReason }[];
    quarantineCipherB64?: string;
    quarantineRow?: RelayItemRow;
    backupManifestB64?: string;
    backupInfo?: BackupInfo;
    code?: string;
}

/** 扩展普通请求的判别联合；解锁会话消息使用独立的 VaultSessionRequest。 */
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

/** 普通扩展消息的响应联合；敏感内容仅向获准的扩展上下文返回。 */
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

/** 对普通消息入口做最小标签检查；每个处理器仍须验证负载与发送方。 */
export function isRequestMessage(value: unknown): value is RequestMessage {
    if (typeof value !== "object" || value === null) {
        return false;
    }
    const type = (value as { type?: unknown }).type;
    if (type === "vault-session") {
        const action = (value as { action?: unknown }).action;
        return typeof action === "string" && ["read", "begin", "commit", "touch", "replace", "lock", "decrypt", "decrypt-attachment", "encrypt", "encrypt-attachment", "refresh", "seal-quarantine", "open-quarantine", "seal-backup"].includes(action);
    }
    return type === "ping" || type === "query" || type === "fill" || type === "unlock"
        || type === "location" || type === "active-location"
        || type === "site-hint" || type === "open-vault" || type === "registration-check";
}
