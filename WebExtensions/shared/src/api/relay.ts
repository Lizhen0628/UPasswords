/**
 * Relay API client for standalone extension contexts (no native bridge):
 * email-code login, vault registry, key envelope and row-level items (v7).
 * Mirrors the Swift `RelayClient` paths; the session token lives in
 * browser.storage.local managed by the caller.
 *
 * 协议注意(与 Swift 端对齐,曾踩坑):
 * - 全部走 /v2(v1 已下线);条目是行级密文,不是整库 body 副本;
 * - 服务端时间戳一律 Unix epoch 毫秒(expiresAt 直接与 Date.now() 比较);
 * - 服务端会把条目 uuid 归一化为小写,解密 AAD 需还原大写(Swift uuidString)。
 */

export const RELAY_BASE_URL = "https://api.upasswords.com";

/** 网络黑洞兜底:超时后 fetch 以 TimeoutError 拒绝,UI 可恢复(否则按钮永久禁用)。 */
const REQUEST_TIMEOUT_MS = 30_000;

export class RelayApiError extends Error {
    /** rate_limited 时的冷却剩余秒数(服务端 Retry-After;无头时由调用方兜底)。 */
    public readonly retryAfter: number;
    constructor(public status: number, public code: string, retryAfterHeader: string | null = null) {
        super(`relay api ${status}: ${code}`);
        this.name = "RelayApiError";
        const parsed = Number.parseInt(retryAfterHeader ?? "", 10);
        this.retryAfter = Number.isFinite(parsed) && parsed > 0 ? parsed : 0;
    }
}

export interface RelaySession {
    token: string;
    /** Unix epoch 毫秒(服务端契约)。 */
    expiresAt: number;
    userId: string;
}

export interface RelayVaultMeta {
    vaultId: string;
    name: string;
    passwordVersion: number;
    hasEnvelope: boolean;
    headSeq: number;
    itemCount: number;
}

/** 行级条目(§6.3 快照分页);bodyB64 = AES-GCM(VEK, AAD=uuid)。 */
export interface RelayItemRow {
    uuid: string;
    kind: number; // 1=card 2=label
    revision: number;
    bodyB64: string;
    modifiedMs: number;
}

async function call(
    method: string,
    path: string,
    token: string | null,
    body?: unknown,
): Promise<unknown> {
    const headers: Record<string, string> = {};
    if (body !== undefined) headers["content-type"] = "application/json";
    if (token) headers.authorization = `Bearer ${token}`;
    const response = await fetch(RELAY_BASE_URL + path, {
        method,
        headers,
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    });
    if (!response.ok) {
        let code = `http_${response.status}`;
        try {
            code = ((await response.json()) as { error?: string }).error ?? code;
        } catch {
            // keep http_ code
        }
        throw new RelayApiError(response.status, code, response.headers.get("retry-after"));
    }
    return response.json();
}

export function bytesToBase64(bytes: Uint8Array): string {
    let binary = "";
    for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
    return btoa(binary);
}

/** Register a new vault (creation carries the initial key envelope). */
export async function createVault(token: string, name: string, envelopeB64: string): Promise<string> {
    const response = (await call("POST", "/v2/vaults", token, { name, envelope: envelopeB64 })) as { vaultId: string };
    return response.vaultId;
}

export function base64ToBytes(b64: string): Uint8Array {
    const binary = atob(b64);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes;
}

/** Send an email verification code (202 on accepted; rate-limited → 429). */
export async function requestCode(email: string, purpose: "login" | "sensitive" = "login"): Promise<void> {
    await call("POST", "/v2/auth/code", null, { email, purpose });
}

/** Verify the code; registers the account on first login, returns a session. */
export async function verifyCode(
    email: string,
    code: string,
    deviceName: string,
    platform = "ext-chrome",
): Promise<RelaySession> {
    return (await call("POST", "/v2/auth/verify", null, {
        email,
        code,
        deviceName,
        platform,
    })) as RelaySession;
}

/** Vaults of the logged-in account. */
export async function listVaults(token: string): Promise<RelayVaultMeta[]> {
    const response = (await call("GET", "/v2/vaults", token)) as { vaults: RelayVaultMeta[] };
    return response.vaults ?? [];
}

/**
 * Single-vault detail including the key envelope (base64 ciphertext);
 * the unlock data source for the extension.
 */
export async function getVaultEnvelope(token: string, vaultId: string): Promise<{ envelope: string | null; meta: RelayVaultMeta }> {
    const detail = (await call("GET", `/v2/vaults/${vaultId}`, token)) as RelayVaultMeta & { envelope: string | null };
    const { envelope, ...meta } = detail;
    return { envelope, meta };
}

interface ItemsPage {
    items: RelayItemRow[];
    nextCursor: { ms: number; uuid: string } | null;
    headSeq: number;
}

/** One snapshot page of the full-rebuild listing (§6.3). */
export async function listVaultItems(
    token: string,
    vaultId: string,
    cursor?: { ms: number; uuid: string } | null,
): Promise<ItemsPage> {
    const query = cursor
        ? `?cursorMs=${cursor.ms}&cursorUuid=${encodeURIComponent(cursor.uuid)}&limit=500`
        : "?limit=500";
    return (await call("GET", `/v2/vaults/${vaultId}/items${query}`, token)) as ItemsPage;
}

/** Full-rebuild listing across pages (snapshots are paginated by updated_ms+uuid). */
export async function listAllVaultItems(token: string, vaultId: string): Promise<RelayItemRow[]> {
    const rows: RelayItemRow[] = [];
    let cursor: { ms: number; uuid: string } | null = null;
    // 页数上限防御:异常大的库也不至于无限循环(500/页,200 页=10 万条)
    for (let page = 0; page < 200; page++) {
        const result = await listVaultItems(token, vaultId, cursor);
        rows.push(...(result.items ?? []));
        if (!result.nextCursor) return rows;
        cursor = result.nextCursor;
    }
    throw new RelayApiError(0, "too_many_pages");
}

/** Self-revoke the caller's own session (sign-out hygiene; best-effort). */
export async function revokeOwnSession(token: string): Promise<void> {
    await call("DELETE", "/v2/auth/session", token);
}
