/**
 * Relay API client for standalone extension contexts (no native bridge):
 * email-code login, vault registry, key envelope and vault body (R2 replica).
 * Mirrors the Swift `RelayClient` paths; the session token lives in
 * browser.storage.local managed by the caller.
 */
export declare const RELAY_BASE_URL = "https://api.upasswords.com";
export declare class RelayApiError extends Error {
    status: number;
    code: string;
    constructor(status: number, code: string);
}
export interface RelaySession {
    token: string;
    expiresAt: number;
    userId: string;
}
export interface RelayVaultMeta {
    vaultId: string;
    name: string;
    passwordVersion: number;
    hasEnvelope: boolean;
    cipherSha256: string | null;
    xmlSha256: string | null;
    bodySha256: string | null;
    bodyBytes: number | null;
    bodyUpdatedAt: number | null;
}
export declare function base64ToBytes(b64: string): Uint8Array;
/** Send an email verification code (202 on accepted; rate-limited → 429). */
export declare function requestCode(email: string, purpose?: "login" | "sensitive"): Promise<void>;
/** Verify the code; registers the account on first login, returns a session. */
export declare function verifyCode(email: string, code: string, deviceName: string): Promise<RelaySession>;
/** Vaults of the logged-in account. */
export declare function listVaults(token: string): Promise<RelayVaultMeta[]>;
/**
 * Single-vault detail including the key envelope (base64 ciphertext);
 * the unlock data source for the extension.
 */
export declare function getVaultEnvelope(token: string, vaultId: string): Promise<{
    envelope: string | null;
    meta: RelayVaultMeta;
}>;
/** Download the vault body replica (encrypted container bytes). */
export declare function getVaultBody(token: string, vaultId: string): Promise<Uint8Array>;
