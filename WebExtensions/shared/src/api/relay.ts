/**
 * Relay API client for standalone extension contexts (no native bridge):
 * email-code login, vault registry, key envelope and row-level items.
 * Mirrors the Swift `RelayClient` paths; the session token lives in
 * browser.storage.local managed by the caller.
 *
 * 协议注意(与 Swift 端对齐,曾踩坑):
 * - 请求走 /v1(服务端兼容旧 /v2 路径);条目是行级密文,不是整库 body 副本;
 * - 服务端时间戳一律 Unix epoch 毫秒(expiresAt 直接与 Date.now() 比较);
 * - 服务端会把条目 uuid 归一化为小写,解密 AAD 需还原大写(Swift uuidString)。
 */

/** 生产中继 API 的根地址；自定义来源的缓存须使用独立 scope。 */
export const RELAY_BASE_URL = "https://api.upasswords.com";

/** 网络黑洞兜底:超时后 fetch 以 TimeoutError 拒绝,UI 可恢复(否则按钮永久禁用)。 */
const REQUEST_TIMEOUT_MS = 30_000;

/** 保留 HTTP 状态、机器错误码和重试等待时间的中继请求错误。 */
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

/** 邮箱验证码验证后签发的账户会话；令牌与密码库密钥相互独立。 */
export interface RelaySession {
    token: string;
    /** Unix epoch 毫秒(服务端契约)。 */
    expiresAt: number;
    userId: string;
}

/** 库注册表元数据，不包含卡片或个人资料明文。 */
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
    let response: Response;
    try {
        response = await fetch(RELAY_BASE_URL + path, {
            method,
            headers,
            body: body === undefined ? undefined : JSON.stringify(body),
            signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
        });
    } catch (error) {
        // 网络黑洞/超时定位:只记方法与路径(含库 ID),不记令牌与请求体
        console.warn(`[upw] relay request failed ${method} ${path} error=${error instanceof Error ? error.name : "unknown"}`);
        throw error;
    }
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

/** 将任意字节编码为标准 Base64；此函数不会加密输入。 */
export function bytesToBase64(bytes: Uint8Array): string {
    let binary = "";
    for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
    return btoa(binary);
}

/** Register a new vault (creation carries the initial key envelope). */
export async function createVault(token: string, name: string, envelopeB64: string): Promise<string> {
    const response = (await call("POST", "/v1/vaults", token, { name, envelope: envelopeB64 })) as { vaultId: string };
    return response.vaultId;
}

/** 解码标准 Base64；格式无效时透传 atob 异常。 */
export function base64ToBytes(b64: string): Uint8Array {
    const binary = atob(b64);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes;
}

/** Send an email verification code (202 on accepted; rate-limited → 429).
 * 邮件语言跟随浏览器语言(navigator.language),缺省英文。 */
export async function requestCode(email: string, purpose: "login" | "sensitive" = "login"): Promise<void> {
    const lang = typeof navigator !== "undefined" ? navigator.language : "en";
    await call("POST", "/v1/auth/code", null, { email, purpose, lang });
}

/** Verify the code; registers the account on first login, returns a session. */
export async function verifyCode(
    email: string,
    code: string,
    deviceName: string,
    platform = "ext-chrome",
): Promise<RelaySession> {
    return (await call("POST", "/v1/auth/verify", null, {
        email,
        code,
        deviceName,
        platform,
    })) as RelaySession;
}

/** Vaults of the logged-in account. */
export async function listVaults(token: string): Promise<RelayVaultMeta[]> {
    const response = (await call("GET", "/v1/vaults", token)) as { vaults: RelayVaultMeta[] };
    return response.vaults ?? [];
}

/**
 * Single-vault detail including the key envelope (base64 ciphertext);
 * the unlock data source for the extension.
 */
export async function getVaultEnvelope(token: string, vaultId: string): Promise<{ envelope: string | null; meta: RelayVaultMeta }> {
    const detail: unknown = await call(
        "GET", `/v1/vaults/${encodeURIComponent(vaultId)}`, token,
    );
    if (!isRecord(detail) || typeof detail.envelope !== "string" && detail.envelope !== null
        || typeof detail.vaultId !== "string" || typeof detail.name !== "string"
        || !isSafeNonNegativeInteger(detail.passwordVersion)
        || typeof detail.hasEnvelope !== "boolean"
        || !isSafeNonNegativeInteger(detail.headSeq)
        || !isSafeNonNegativeInteger(detail.itemCount)) {
        throw new RelayApiError(0, "bad_vault_response");
    }
    const { envelope, ...meta } = detail;
    return { envelope, meta: meta as unknown as RelayVaultMeta };
}

/** 增量变更事件；purge 与 rekey 不要求携带条目密文。 */
export interface RelayChange {
    seq: number;
    uuid: string;
    op: "upsert" | "purge" | "rekey";
    revision: number;
    deleted?: boolean;
    bodyB64?: string;
    kind?: number;
    modifiedMs?: number;
}

/** 以库级序列排序的变更页，高水位与返回条目末序列分别处理。 */
export interface RelayChangesPage {
    headSeq: number;
    changes: RelayChange[];
}

/** Current high-water sequence and encryption password version. */
export async function getVaultSeq(
    token: string,
    vaultId: string,
): Promise<{ headSeq: number; passwordVersion: number }> {
    const response: unknown = await call(
        "GET", `/v1/vaults/${encodeURIComponent(vaultId)}/seq`, token,
    );
    if (!isRecord(response) || !isSafeNonNegativeInteger(response.headSeq)
        || !isSafeNonNegativeInteger(response.passwordVersion)) {
        throw new RelayApiError(0, "bad_seq_response");
    }
    return { headSeq: response.headSeq, passwordVersion: response.passwordVersion };
}

/** Fetch a sequence-ordered incremental page (410 means the cursor expired). */
export async function getVaultChanges(
    token: string,
    vaultId: string,
    since: number,
    limit = 200,
): Promise<RelayChangesPage> {
    if (!isSafeNonNegativeInteger(since) || !Number.isSafeInteger(limit) || limit < 1 || limit > 500) {
        throw new RelayApiError(0, "bad_changes_request");
    }
    const response: unknown = await call(
        "GET",
        `/v1/vaults/${encodeURIComponent(vaultId)}/changes?since=${since}&limit=${limit}`,
        token,
    );
    if (!isRecord(response) || !isSafeNonNegativeInteger(response.headSeq)
        || !Array.isArray(response.changes)) {
        throw new RelayApiError(0, "bad_changes_response");
    }
    if (response.headSeq < since || response.changes.length > limit) {
        throw new RelayApiError(0, "bad_changes_response");
    }
    const headSeq = response.headSeq;
    let previousSeq = since;
    const changes = response.changes.map((raw): RelayChange => {
        if (!isRecord(raw) || !isSafeNonNegativeInteger(raw.seq) || raw.seq <= previousSeq
            || typeof raw.uuid !== "string"
            || !["upsert", "purge", "rekey"].includes(String(raw.op))
            || !isSafeNonNegativeInteger(raw.revision) || raw.revision < 1
            || raw.seq > headSeq || (raw.op === "rekey" ? raw.uuid !== ""
                : !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(raw.uuid))) {
            throw new RelayApiError(0, "bad_changes_response");
        }
        previousSeq = raw.seq;
        const change: RelayChange = {
            seq: raw.seq,
            uuid: raw.uuid,
            op: raw.op as RelayChange["op"],
            revision: raw.revision,
        };
        if (raw.deleted !== undefined) {
            if (typeof raw.deleted !== "boolean") throw new RelayApiError(0, "bad_changes_response");
            change.deleted = raw.deleted;
        }
        if (raw.bodyB64 !== undefined) {
            if (typeof raw.bodyB64 !== "string" || !raw.bodyB64) {
                throw new RelayApiError(0, "bad_changes_response");
            }
            change.bodyB64 = raw.bodyB64;
        }
        if (raw.kind !== undefined) {
            if (!isSafeNonNegativeInteger(raw.kind) || (raw.kind !== 1 && raw.kind !== 2 && raw.kind !== 3)) {
                throw new RelayApiError(0, "bad_changes_response");
            }
            change.kind = raw.kind;
        }
        if (raw.modifiedMs !== undefined) {
            if (!isSafeNonNegativeInteger(raw.modifiedMs)) throw new RelayApiError(0, "bad_changes_response");
            change.modifiedMs = raw.modifiedMs;
        }
        return change;
    });
    return { headSeq: response.headSeq, changes };
}

function isRecord(value: unknown): value is Record<string, unknown> {
    return typeof value === "object" && value !== null;
}

function isSafeNonNegativeInteger(value: unknown): value is number {
    return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
}

/** 校验未知对象的 UUID、类型码、版本、毫秒时间与密文编码结构。 */
export function isValidRelayItemRow(value: unknown): value is RelayItemRow {
    if (!isRecord(value) || typeof value.uuid !== "string"
        || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value.uuid)
        || !isSafeNonNegativeInteger(value.kind) || (value.kind !== 1 && value.kind !== 2 && value.kind !== 3)
        || !isSafeNonNegativeInteger(value.revision) || value.revision < 1
        || typeof value.bodyB64 !== "string" || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value.bodyB64)
        || value.bodyB64.length === 0
        || !isSafeNonNegativeInteger(value.modifiedMs)) return false;
    return true;
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
    const response: unknown = await call("GET", `/v1/vaults/${encodeURIComponent(vaultId)}/items${query}`, token);
    if (!isRecord(response) || !Array.isArray(response.items)
        || !isSafeNonNegativeInteger(response.headSeq)
        || response.nextCursor !== null && (!isRecord(response.nextCursor)
            || !isSafeNonNegativeInteger(response.nextCursor.ms)
            || typeof response.nextCursor.uuid !== "string")) {
        throw new RelayApiError(0, "bad_items_response");
    }
    const items = response.items.map((raw): RelayItemRow => {
        if (!isValidRelayItemRow(raw)) throw new RelayApiError(0, "bad_items_response");
        return {
            uuid: raw.uuid,
            kind: raw.kind,
            revision: raw.revision,
            bodyB64: raw.bodyB64,
            modifiedMs: raw.modifiedMs,
        };
    });
    const nextCursor = response.nextCursor as ItemsPage["nextCursor"];
    return { items, nextCursor, headSeq: response.headSeq };
}

/** Full-rebuild listing across pages (snapshots are paginated by updated_ms+uuid). */
export async function listAllVaultItems(token: string, vaultId: string): Promise<RelayItemRow[]> {
    const rows: RelayItemRow[] = [];
    let cursor: { ms: number; uuid: string } | null = null;
    let expectedHead: number | null = null;
    // 页数上限防御:异常大的库也不至于无限循环(500/页,200 页=10 万条)
    for (let page = 0; page < 200; page++) {
        const result = await listVaultItems(token, vaultId, cursor);
        if (expectedHead !== null && result.headSeq !== expectedHead) {
            throw new RelayApiError(0, "unstable_snapshot");
        }
        expectedHead = result.headSeq;
        rows.push(...result.items);
        if (!result.nextCursor) return rows;
        if (result.items.length === 0) throw new RelayApiError(0, "bad_snapshot_response");
        cursor = result.nextCursor;
    }
    throw new RelayApiError(0, "too_many_pages");
}

/** 待写入的条目密文和原始 CAS 版本；密文在调用前完成加密。 */
export interface SaveVaultItem {
    uuid: string;
    revision: number;
    bodyB64: string;
    modifiedMs: number;
}

/**
 * Save one existing card using its original CAS revision. Never retry conflicts or missing rows:
 * retrying against a newer revision would overwrite a concurrent edit or resurrect a deleted card.
 * HTTP errors (including rekey_in_progress) pass through unchanged for the caller to handle.
 */
export async function saveVaultItem(
    token: string,
    vaultId: string,
    item: SaveVaultItem,
): Promise<{ revision: number }> {
    if (!Number.isSafeInteger(item.revision) || item.revision < 1) {
        throw new RelayApiError(0, "bad_item_revision");
    }
    return putItem(token, vaultId, item, item.revision);
}

/** 新 UUID 的创建负载，不接受用于更新现有行的 revision。 */
export type NewVaultItem = Omit<SaveVaultItem, "revision">;

/**
 * Insert one newly generated UUID through the existing items CAS endpoint. Zero is creation only:
 * an occupied UUID conflicts, and neither conflicts nor HTTP failures are retried as updates.
 */
export async function createItem(
    token: string,
    vaultId: string,
    item: NewVaultItem,
): Promise<{ revision: number }> {
    if (!isValidRelayItemRow({ ...item, kind: 1, revision: 1 })) {
        throw new RelayApiError(0, "bad_item_request");
    }
    console.info("[upw] relay item creation started");
    const started = performance.now();
    try {
        const result = await putItem(token, vaultId, item, 0);
        console.info("[upw] relay item creation completed", { durationMs: Math.round(performance.now() - started) });
        return result;
    } catch (error) {
        // Never log tokens, request bodies, titles, secrets or server-provided response values.
        console.warn("[upw] relay item creation failed", { durationMs: Math.round(performance.now() - started) });
        throw error;
    }
}

/** Share strict single-result validation without exposing a zero-revision update API. */
async function putItem(
    token: string,
    vaultId: string,
    item: NewVaultItem,
    baseRevision: number,
): Promise<{ revision: number }> {
    const response = await call("POST", `/v1/vaults/${encodeURIComponent(vaultId)}/items`, token, {
        items: [{
            uuid: item.uuid,
            kind: 1,
            op: "upsert",
            baseRevision,
            bodyB64: item.bodyB64,
            modifiedMs: item.modifiedMs,
        }],
    });
    const malformed = () => new RelayApiError(0, "bad_item_response");
    if (!response || typeof response !== "object" || !("results" in response)
        || !Array.isArray(response.results) || response.results.length !== 1) {
        throw malformed();
    }
    const result: unknown = response.results[0];
    if (!result || typeof result !== "object" || !("uuid" in result)
        || typeof result.uuid !== "string" || result.uuid.toLowerCase() !== item.uuid.toLowerCase()
        || !("status" in result)) {
        throw malformed();
    }
    if (result.status === "conflict") throw new RelayApiError(409, "item_conflict");
    if (result.status === "not_found") throw new RelayApiError(404, "item_deleted");
    if (result.status !== "ok" || !("revision" in result)
        || typeof result.revision !== "number" || !Number.isSafeInteger(result.revision)
        || result.revision !== baseRevision + 1) {
        throw malformed();
    }
    return { revision: result.revision };
}

/** Self-revoke the caller's own session (sign-out hygiene; best-effort). */
export async function revokeOwnSession(token: string): Promise<void> {
    await call("DELETE", "/v1/auth/session", token);
}
