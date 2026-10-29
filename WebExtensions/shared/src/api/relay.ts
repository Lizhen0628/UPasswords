/**
 * Relay API client for standalone extension contexts (no native bridge):
 * email-code login, vault registry, key envelope and row-level items.
 * Mirrors the Swift `RelayClient` paths; the session token lives in
 * browser.storage.local managed by the caller.
 *
 * 协议注意(与 Swift 端对齐,曾踩坑):
 * - 只使用 /v1;行同步请求统一声明协议 5，卡片写入携带完整附件版本引用;
 * - 条目是行级密文,不是整库 body 副本;
 * - 服务端时间戳一律 Unix epoch 毫秒(expiresAt 直接与 Date.now() 比较);
 * - 服务端会把条目 uuid 归一化为小写,解密 AAD 需还原大写(Swift uuidString)。
 */

/** 生产中继 API 的根地址；自定义来源的缓存须使用独立 scope。 */
export const RELAY_BASE_URL = "https://api.upasswords.com";

/** Row-sync capability version required by the server for attachment-safe card writes. */
export const SYNC_PROTOCOL_VERSION = 5;

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
    headers["X-UPW-Sync-Protocol"] = String(SYNC_PROTOCOL_VERSION);
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

/** 增量变更事件；裁决事件在一个游标步骤内替换原身份和最终身份。 */
export interface RelayChange {
    seq: number;
    uuid: string;
    op: "upsert" | "purge" | "resolve" | "rekey";
    revision: number;
    deleted?: boolean;
    bodyB64?: string;
    kind?: number;
    modifiedMs?: number;
    resolvedItemUuid?: string;
    resolvedRevision?: number;
    conflictId?: string;
    baseRevision?: number;
    winnerCandidateId?: string;
    winnerKind?: number;
    winnerOp?: "upsert" | "delete";
    resolutionType?: "candidate" | "composed";
    sha256?: string;
}

/** 以库级序列排序的变更页，高水位与返回条目末序列分别处理。 */
export interface RelayChangesPage {
    headSeq: number;
    changes: RelayChange[];
}

/** Encrypted candidate retained by the server for a manual conflict decision. */
export interface RelayConflictCandidate {
    candidateId: string;
    kind: number;
    op: "upsert" | "delete";
    revision: number;
    modifiedMs: number;
    committedMs: number;
    deviceName: string;
    platform: string;
    sourceSessionId?: string;
    bodyB64?: string;
    sha256?: string;
}

/** Complete candidate set and compare-and-swap state for one unresolved item. */
export interface RelayConflict {
    conflictId: string;
    itemUuid: string;
    baseRevision: number;
    currentRevision: number;
    currentDeletedSeq: number;
    generation: number;
    createdMs: number;
    updatedMs: number;
    candidates: RelayConflictCandidate[];
}

/** Candidate ciphertext retained after a conflict was resolved. */
export interface RelayRetainedConflict {
    conflictId: string;
    itemUuid: string;
    baseRevision: number;
    currentRevision: number;
    currentDeletedSeq: number;
    generation: number;
    createdMs: number;
    updatedMs: number;
    resolvedMs: number;
    expiresMs: number;
    selectedCandidateId?: string;
    candidates: RelayConflictCandidate[];
}

/** Input for an atomic server-side candidate resolution. */
export interface ResolveVaultConflictInput {
    conflictId: string;
    generation: number;
    candidateIds: string[];
    winnerCandidateId: string;
    expectedCurrentRevision: number;
    expectedDeletedSeq: number;
    attachmentRefs: RelayAttachmentReference[];
    restoreItemUuid?: string;
    bodyB64?: string;
    mergedBodyB64?: string;
    mergedModifiedMs?: number;
}

export interface RelayConflictResolutionResult {
    status: "resolved";
    itemUuid: string | null;
    itemCount: number;
    headSeq: number;
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
            || !["upsert", "purge", "resolve", "rekey"].includes(String(raw.op))
            || !isSafeNonNegativeInteger(raw.revision) || raw.revision < 1
            || raw.seq > headSeq || (raw.op === "rekey" ? raw.uuid !== ""
                : !isUUID(raw.uuid))) {
            throw new RelayApiError(0, "bad_changes_response");
        }
        if (raw.op === "resolve" && !isResolutionChange(raw)) {
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
        if (raw.resolvedItemUuid !== undefined) {
            if (!isUUID(raw.resolvedItemUuid)) throw new RelayApiError(0, "bad_changes_response");
            change.resolvedItemUuid = raw.resolvedItemUuid;
        }
        if (raw.resolvedRevision !== undefined) {
            if (!isSafeNonNegativeInteger(raw.resolvedRevision) || raw.resolvedRevision < 1) {
                throw new RelayApiError(0, "bad_changes_response");
            }
            change.resolvedRevision = raw.resolvedRevision;
        }
        if (raw.conflictId !== undefined) {
            if (!isCandidateId(raw.conflictId)) throw new RelayApiError(0, "bad_changes_response");
            change.conflictId = raw.conflictId;
        }
        if (raw.baseRevision !== undefined) {
            if (!isSafeNonNegativeInteger(raw.baseRevision)) throw new RelayApiError(0, "bad_changes_response");
            change.baseRevision = raw.baseRevision;
        }
        if (raw.winnerCandidateId !== undefined) {
            if (!isCandidateId(raw.winnerCandidateId)) throw new RelayApiError(0, "bad_changes_response");
            change.winnerCandidateId = raw.winnerCandidateId;
        }
        if (raw.winnerKind !== undefined) {
            if (!isKind(raw.winnerKind)) throw new RelayApiError(0, "bad_changes_response");
            change.winnerKind = raw.winnerKind;
        }
        if (raw.winnerOp !== undefined) {
            if (raw.winnerOp !== "upsert" && raw.winnerOp !== "delete") {
                throw new RelayApiError(0, "bad_changes_response");
            }
            change.winnerOp = raw.winnerOp;
        }
        if (raw.resolutionType !== undefined) {
            if (raw.resolutionType !== "candidate" && raw.resolutionType !== "composed") {
                throw new RelayApiError(0, "bad_changes_response");
            }
            change.resolutionType = raw.resolutionType;
        }
        if (raw.sha256 !== undefined) {
            if (typeof raw.sha256 !== "string" || !/^[0-9a-f]{64}$/.test(raw.sha256)) {
                throw new RelayApiError(0, "bad_changes_response");
            }
            change.sha256 = raw.sha256;
        }
        return change;
    });
    return { headSeq: response.headSeq, changes };
}

/** Read all unresolved encrypted candidate sets for a vault. */
export async function listVaultConflicts(token: string, vaultId: string): Promise<RelayConflict[]> {
    const response: unknown = await call(
        "GET", `/v1/vaults/${encodeURIComponent(vaultId)}/conflicts`, token,
    );
    if (!isRecord(response) || !Array.isArray(response.conflicts)) {
        throw new RelayApiError(0, "bad_conflicts_response");
    }
    return response.conflicts.map(parseConflict);
}

/** Read every retained candidate using a fixed, authenticated keyset cursor. */
export async function listVaultConflictHistory(
    token: string,
    vaultId: string,
): Promise<RelayRetainedConflict[]> {
    const path = `/v1/vaults/${encodeURIComponent(vaultId)}/conflict-history`;
    const conflicts = new Map<string, RelayRetainedConflict>();
    const candidateIDs = new Set<string>();
    const cursors = new Set<string>();
    let cursor: string | undefined;
    let snapshotMs: number | undefined;
    let totalCandidates: number | undefined;
    let receivedCandidates = 0;
    let pageCount = 0;

    while (true) {
        const query = new URLSearchParams({ limit: "50" });
        if (cursor !== undefined) query.set("cursor", cursor);
        const response: unknown = await call("GET", `${path}?${query}`, token);
        if (!isRecord(response) || !isSafeNonNegativeInteger(response.snapshotMs)
            || !isSafeNonNegativeInteger(response.totalCandidates)
            || !Array.isArray(response.candidates)
            || response.nextCursor !== null && typeof response.nextCursor !== "string") {
            throw new RelayApiError(0, "bad_conflict_history_response");
        }
        if (snapshotMs !== undefined && response.snapshotMs !== snapshotMs
            || totalCandidates !== undefined && response.totalCandidates !== totalCandidates) {
            throw new RelayApiError(0, "bad_conflict_history_response");
        }
        snapshotMs = response.snapshotMs;
        totalCandidates = response.totalCandidates;
        if (totalCandidates > 1_600_000 || response.candidates.length > totalCandidates - receivedCandidates) {
            throw new RelayApiError(0, "bad_conflict_history_response");
        }

        for (const raw of response.candidates) {
            const entry = parseRetainedConflictCandidate(raw, snapshotMs);
            const candidateKey = `${entry.conflictId}:${entry.candidate.candidateId}`;
            if (!candidateIDs.add(candidateKey)) {
                throw new RelayApiError(0, "bad_conflict_history_response");
            }
            const { candidate, ...metadata } = entry;
            let conflict = conflicts.get(entry.conflictId);
            if (conflict === undefined) {
                conflict = { ...metadata, candidates: [] };
                conflicts.set(entry.conflictId, conflict);
            } else if (!sameRetainedConflictMetadata(conflict, metadata)) {
                throw new RelayApiError(0, "bad_conflict_history_response");
            }
            conflict.candidates.push(candidate);
            receivedCandidates += 1;
        }

        const nextCursor = response.nextCursor as string | null;
        if (nextCursor === null) {
            if (receivedCandidates !== totalCandidates) {
                throw new RelayApiError(0, "bad_conflict_history_response");
            }
            for (const conflict of conflicts.values()) {
                if (conflict.selectedCandidateId !== undefined
                    && !conflict.candidates.some(candidate => candidate.candidateId === conflict.selectedCandidateId)) {
                    throw new RelayApiError(0, "bad_conflict_history_response");
                }
            }
            return [...conflicts.values()].sort((left, right) => left.conflictId.localeCompare(right.conflictId));
        }
        if (nextCursor.length === 0 || nextCursor === cursor || !cursors.add(nextCursor)
            || response.candidates.length === 0 || receivedCandidates >= totalCandidates) {
            throw new RelayApiError(0, "bad_conflict_history_response");
        }
        cursor = nextCursor;
        pageCount += 1;
        if (pageCount > totalCandidates) throw new RelayApiError(0, "bad_conflict_history_response");
    }
}

/** Submit a complete candidate set for one atomic manual resolution. */
export async function resolveVaultConflict(
    token: string,
    vaultId: string,
    input: ResolveVaultConflictInput,
): Promise<RelayConflictResolutionResult> {
    if (!input || !Array.isArray(input.candidateIds)
        || !isCandidateId(input.conflictId) || !isSafeNonNegativeInteger(input.generation)
        || input.generation < 1 || !isSafeNonNegativeInteger(input.expectedCurrentRevision)
        || !isSafeNonNegativeInteger(input.expectedDeletedSeq)
        || input.candidateIds.length < 2 || input.candidateIds.length > 32
        || new Set(input.candidateIds).size !== input.candidateIds.length
        || input.candidateIds.some((id) => !isCandidateId(id))
        || !input.candidateIds.includes(input.winnerCandidateId)) {
        throw new RelayApiError(0, "bad_conflict_request");
    }
    if (input.restoreItemUuid !== undefined && !isUUID(input.restoreItemUuid)) {
        throw new RelayApiError(0, "bad_conflict_request");
    }
    const attachmentIDs = new Set<string>();
    const validAttachmentRefs = Array.isArray(input.attachmentRefs)
        && input.attachmentRefs.length <= 500
        && input.attachmentRefs.every(reference => {
            if (!reference || !isUUID(reference.attachmentId) || reference.attachmentId === ZERO_UUID
                || !isUUID(reference.contentVersion) || reference.contentVersion === ZERO_UUID
                || reference.restoreDeleted !== undefined && typeof reference.restoreDeleted !== "boolean") {
                return false;
            }
            const id = reference.attachmentId.toLowerCase();
            if (attachmentIDs.has(id)) return false;
            attachmentIDs.add(id);
            return true;
        });
    if (!validAttachmentRefs) throw new RelayApiError(0, "bad_conflict_request");
    for (const value of [input.bodyB64, input.mergedBodyB64]) {
        if (value !== undefined && !isBase64(value)) {
            throw new RelayApiError(0, "bad_conflict_request");
        }
    }
    if (input.mergedModifiedMs !== undefined
        && (!isSafeNonNegativeInteger(input.mergedModifiedMs) || input.mergedModifiedMs > 253402300799999)) {
        throw new RelayApiError(0, "bad_conflict_request");
    }
    if ((input.restoreItemUuid === undefined) !== (input.bodyB64 === undefined)
        || (input.mergedBodyB64 === undefined) !== (input.mergedModifiedMs === undefined)
        || input.restoreItemUuid !== undefined && input.mergedBodyB64 !== undefined) {
        throw new RelayApiError(0, "bad_conflict_request");
    }
    const response: unknown = await call(
        "POST",
        `/v1/vaults/${encodeURIComponent(vaultId)}/conflicts/${input.conflictId}/resolve`,
        token,
        {
            generation: input.generation,
            candidateIds: input.candidateIds,
            winnerCandidateId: input.winnerCandidateId,
            expectedCurrentRevision: input.expectedCurrentRevision,
            expectedDeletedSeq: input.expectedDeletedSeq,
            attachmentRefs: input.attachmentRefs.map(reference => ({
                attachmentId: reference.attachmentId.toLowerCase(),
                contentVersion: reference.contentVersion.toLowerCase(),
                ...(reference.restoreDeleted ? { restoreDeleted: true } : {}),
            })),
            ...(input.restoreItemUuid === undefined ? {} : {
                restoreItemUuid: input.restoreItemUuid,
                bodyB64: input.bodyB64,
            }),
            ...(input.mergedBodyB64 === undefined ? {} : {
                mergedBodyB64: input.mergedBodyB64,
                mergedModifiedMs: input.mergedModifiedMs,
            }),
        },
    );
    if (!isRecord(response) || response.status !== "resolved"
        || (response.itemUuid !== null && !isUUID(response.itemUuid))
        || !isSafeNonNegativeInteger(response.itemCount)
        || !isSafeNonNegativeInteger(response.headSeq)) {
        throw new RelayApiError(0, "bad_conflict_response");
    }
    return {
        status: "resolved",
        itemUuid: response.itemUuid as string | null,
        itemCount: response.itemCount,
        headSeq: response.headSeq,
    };
}

function isRecord(value: unknown): value is Record<string, unknown> {
    return typeof value === "object" && value !== null;
}

function isSafeNonNegativeInteger(value: unknown): value is number {
    return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
}

function isUUID(value: unknown): value is string {
    return typeof value === "string"
        && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
}

function isKind(value: unknown): value is number {
    return value === 1 || value === 2 || value === 3;
}

function isCandidateId(value: unknown): value is string {
    return typeof value === "string" && /^[0-9a-f]{32}$/.test(value);
}

function isBase64(value: unknown): value is string {
    return typeof value === "string" && value.length > 0
        && /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value);
}

function parseConflict(value: unknown): RelayConflict {
    if (!isRecord(value) || !isCandidateId(value.conflictId) || !isUUID(value.itemUuid)
        || !isSafeNonNegativeInteger(value.baseRevision)
        || !isSafeNonNegativeInteger(value.currentRevision) || value.currentRevision < 1
        || !isSafeNonNegativeInteger(value.currentDeletedSeq)
        || !isSafeNonNegativeInteger(value.generation) || value.generation < 1
        || !isSafeNonNegativeInteger(value.createdMs) || !isSafeNonNegativeInteger(value.updatedMs)
        || !Array.isArray(value.candidates) || value.candidates.length < 2
        || value.candidates.length > 32) {
        throw new RelayApiError(0, "bad_conflicts_response");
    }
    const candidates = value.candidates.map(candidate => parseConflictCandidate(candidate, "bad_conflicts_response"));
    const ids = new Set(candidates.map((candidate) => candidate.candidateId));
    if (ids.size !== candidates.length) throw new RelayApiError(0, "bad_conflicts_response");
    return {
        conflictId: value.conflictId,
        itemUuid: value.itemUuid,
        baseRevision: value.baseRevision,
        currentRevision: value.currentRevision,
        currentDeletedSeq: value.currentDeletedSeq,
        generation: value.generation,
        createdMs: value.createdMs,
        updatedMs: value.updatedMs,
        candidates,
    };
}

interface ParsedRetainedConflictCandidate extends Omit<RelayRetainedConflict, "candidates"> {
    candidate: RelayConflictCandidate;
}

function parseRetainedConflictCandidate(value: unknown, snapshotMs: number): ParsedRetainedConflictCandidate {
    if (!isRecord(value) || !isCandidateId(value.conflictId) || !isUUID(value.itemUuid)
        || !isSafeNonNegativeInteger(value.baseRevision)
        || !isSafeNonNegativeInteger(value.currentRevision) || value.currentRevision < 1
        || value.baseRevision >= value.currentRevision
        || !isSafeNonNegativeInteger(value.currentDeletedSeq)
        || !isSafeNonNegativeInteger(value.generation) || value.generation < 1
        || !isSafeNonNegativeInteger(value.createdMs) || !isSafeNonNegativeInteger(value.updatedMs)
        || !isSafeNonNegativeInteger(value.resolvedMs) || value.resolvedMs > snapshotMs
        || !isSafeNonNegativeInteger(value.expiresMs) || value.expiresMs <= snapshotMs
        || value.selectedCandidateId !== undefined && !isCandidateId(value.selectedCandidateId)) {
        throw new RelayApiError(0, "bad_conflict_history_response");
    }
    const candidate = parseConflictCandidate(value.candidate, "bad_conflict_history_response");
    if (candidate.revision > value.currentRevision) {
        throw new RelayApiError(0, "bad_conflict_history_response");
    }
    return {
        conflictId: value.conflictId,
        itemUuid: value.itemUuid,
        baseRevision: value.baseRevision,
        currentRevision: value.currentRevision,
        currentDeletedSeq: value.currentDeletedSeq,
        generation: value.generation,
        createdMs: value.createdMs,
        updatedMs: value.updatedMs,
        resolvedMs: value.resolvedMs,
        expiresMs: value.expiresMs,
        ...(value.selectedCandidateId === undefined ? {} : { selectedCandidateId: value.selectedCandidateId }),
        candidate,
    };
}

function parseConflictCandidate(value: unknown, errorCode: string): RelayConflictCandidate {
    if (!isRecord(value) || !isCandidateId(value.candidateId)
        || !isKind(value.kind) || (value.op !== "upsert" && value.op !== "delete")
        || !isSafeNonNegativeInteger(value.revision)
        || !isSafeNonNegativeInteger(value.modifiedMs)
        || !isSafeNonNegativeInteger(value.committedMs)
        || typeof value.deviceName !== "string" || typeof value.platform !== "string") {
        throw new RelayApiError(0, errorCode);
    }
    if (value.op === "upsert"
        && (!isBase64(value.bodyB64) || typeof value.sha256 !== "string"
            || !/^[0-9a-f]{64}$/.test(value.sha256))) {
        throw new RelayApiError(0, errorCode);
    }
    if (value.op === "delete" && (value.bodyB64 !== undefined || value.sha256 !== undefined)) {
        throw new RelayApiError(0, errorCode);
    }
    if (value.sourceSessionId !== undefined && typeof value.sourceSessionId !== "string") {
        throw new RelayApiError(0, errorCode);
    }
    const bodyB64 = typeof value.bodyB64 === "string" ? value.bodyB64 : undefined;
    const sha256 = typeof value.sha256 === "string" ? value.sha256 : undefined;
    return {
        candidateId: value.candidateId,
        kind: value.kind,
        op: value.op,
        revision: value.revision,
        modifiedMs: value.modifiedMs,
        committedMs: value.committedMs,
        deviceName: value.deviceName,
        platform: value.platform,
        ...(value.sourceSessionId === undefined ? {} : { sourceSessionId: value.sourceSessionId }),
        ...(bodyB64 === undefined ? {} : { bodyB64 }),
        ...(sha256 === undefined ? {} : { sha256 }),
    };
}

function sameRetainedConflictMetadata(
    left: RelayRetainedConflict,
    right: Omit<RelayRetainedConflict, "candidates">,
): boolean {
    return left.conflictId === right.conflictId
        && left.itemUuid === right.itemUuid
        && left.baseRevision === right.baseRevision
        && left.currentRevision === right.currentRevision
        && left.currentDeletedSeq === right.currentDeletedSeq
        && left.generation === right.generation
        && left.createdMs === right.createdMs
        && left.updatedMs === right.updatedMs
        && left.resolvedMs === right.resolvedMs
        && left.expiresMs === right.expiresMs
        && left.selectedCandidateId === right.selectedCandidateId;
}

function isResolutionChange(value: Record<string, unknown>): boolean {
    if (!isCandidateId(value.conflictId) || !isSafeNonNegativeInteger(value.baseRevision)
        || !isCandidateId(value.winnerCandidateId) || !isKind(value.winnerKind)
        || (value.winnerOp !== "upsert" && value.winnerOp !== "delete")
        || (value.resolutionType !== "candidate" && value.resolutionType !== "composed")) {
        return false;
    }
    if (value.winnerOp === "delete") {
        return value.deleted === true && value.resolvedItemUuid === undefined
            && value.resolvedRevision === undefined && value.kind === undefined
            && value.bodyB64 === undefined && value.modifiedMs === undefined;
    }
    if (!isUUID(value.resolvedItemUuid)) return false;
    if (value.deleted === true) {
        return value.resolvedRevision === undefined && value.kind === undefined
            && value.bodyB64 === undefined && value.modifiedMs === undefined;
    }
    return isSafeNonNegativeInteger(value.resolvedRevision) && value.resolvedRevision >= 1
        && isKind(value.kind) && typeof value.bodyB64 === "string" && value.bodyB64.length > 0
        && isSafeNonNegativeInteger(value.modifiedMs)
        && typeof value.sha256 === "string" && /^[0-9a-f]{64}$/.test(value.sha256);
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

/** One current or retained encrypted attachment content version. */
export interface RelayAttachmentVersion {
    attachmentId: string;
    cardUuid: string;
    createdMs: number;
    contentVersion: string;
    dekWrapped: string;
    retiredMs?: number;
    sha256: string;
    bytes: number;
    isCurrent: boolean;
}

/** List attachment versions for a vault or one card, following bounded offset pages. */
export async function listVaultAttachmentVersions(
    token: string,
    vaultId: string,
    cardUuid?: string,
): Promise<RelayAttachmentVersion[]> {
    const versions: RelayAttachmentVersion[] = [];
    const identities = new Set<string>();
    const currentAttachmentIDs = new Set<string>();
    let offset = 0;
    for (let page = 0; page < 250; page += 1) {
        const query = new URLSearchParams({ limit: "200", offset: String(offset) });
        if (cardUuid !== undefined) query.set("cardUuid", cardUuid);
        const response: unknown = await call(
            "GET", `/v1/vaults/${encodeURIComponent(vaultId)}/attachment-versions?${query}`, token,
        );
        if (!isRecord(response) || !Array.isArray(response.versions)
            || !isSafeNonNegativeInteger(response.nextOffset)
            || typeof response.hasMore !== "boolean") {
            throw new RelayApiError(0, "bad_attachment_versions_response");
        }
        const pageVersions = response.versions.map((value): RelayAttachmentVersion => {
            const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
            if (!isRecord(value) || typeof value.attachmentId !== "string" || !uuid.test(value.attachmentId)
                || typeof value.cardUuid !== "string" || !uuid.test(value.cardUuid)
                || !isSafeNonNegativeInteger(value.createdMs)
                || typeof value.contentVersion !== "string" || !uuid.test(value.contentVersion)
                || typeof value.dekWrapped !== "string" || value.dekWrapped.length === 0
                || value.dekWrapped.length % 4 !== 0
                || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value.dekWrapped)
                || typeof value.sha256 !== "string" || !/^[0-9a-f]{64}$/i.test(value.sha256)
                || !isSafeNonNegativeInteger(value.bytes) || value.bytes < 1
                || typeof value.isCurrent !== "boolean"
                || value.retiredMs !== undefined && !isSafeNonNegativeInteger(value.retiredMs)) {
                throw new RelayApiError(0, "bad_attachment_versions_response");
            }
            let wrappedKeyBytes: number;
            try {
                wrappedKeyBytes = atob(value.dekWrapped).length;
            } catch {
                throw new RelayApiError(0, "bad_attachment_versions_response");
            }
            const attachmentId = value.attachmentId.toLowerCase();
            const contentVersion = value.contentVersion.toLowerCase();
            const identity = `${attachmentId}:${contentVersion}`;
            if (wrappedKeyBytes < 28 || wrappedKeyBytes > 256
                || identities.has(identity)
                || value.isCurrent && currentAttachmentIDs.has(attachmentId)) {
                throw new RelayApiError(0, "bad_attachment_versions_response");
            }
            identities.add(identity);
            if (value.isCurrent) currentAttachmentIDs.add(attachmentId);
            return {
                attachmentId,
                cardUuid: value.cardUuid.toLowerCase(),
                createdMs: value.createdMs,
                contentVersion,
                dekWrapped: value.dekWrapped,
                ...(value.retiredMs === undefined ? {} : { retiredMs: value.retiredMs }),
                sha256: value.sha256.toLowerCase(),
                bytes: value.bytes,
                isCurrent: value.isCurrent,
            };
        });
        if (response.nextOffset !== offset + pageVersions.length
            || response.hasMore && pageVersions.length === 0) {
            throw new RelayApiError(0, "bad_attachment_versions_response");
        }
        versions.push(...pageVersions);
        offset = response.nextOffset;
        if (!response.hasMore) return versions;
    }
    throw new RelayApiError(0, "too_many_attachment_versions");
}

/** Download and verify one exact ciphertext version against its authenticated catalogue metadata. */
export async function getVaultAttachment(
    token: string,
    vaultId: string,
    version: RelayAttachmentVersion,
    signal?: AbortSignal,
): Promise<Uint8Array> {
    const controller = new AbortController();
    const abort = () => controller.abort(signal?.reason);
    if (signal?.aborted) abort();
    else signal?.addEventListener("abort", abort, { once: true });
    const timer = setTimeout(() => controller.abort(new DOMException("Attachment request timed out", "TimeoutError")), REQUEST_TIMEOUT_MS);
    try {
        let response: Response;
        const path = `/v1/vaults/${encodeURIComponent(vaultId)}/attachments/${encodeURIComponent(version.attachmentId)}?version=${encodeURIComponent(version.contentVersion)}`;
        try {
            response = await fetch(RELAY_BASE_URL + path, {
                method: "GET",
                headers: {
                    authorization: `Bearer ${token}`,
                    "X-UPW-Sync-Protocol": String(SYNC_PROTOCOL_VERSION),
                },
                signal: controller.signal,
            });
        } catch (error) {
            console.warn(`[upw] relay attachment download failed id=${version.attachmentId} error=${error instanceof Error ? error.name : "unknown"}`);
            throw error;
        }
        if (!response.ok) {
            let code = `http_${response.status}`;
            try {
                code = ((await response.json()) as { error?: string }).error ?? code;
            } catch {
                // Keep the HTTP status as the machine-readable fallback.
            }
            throw new RelayApiError(response.status, code, response.headers.get("retry-after"));
        }
        if (!Number.isSafeInteger(version.bytes) || version.bytes < 1) {
            throw new RelayApiError(0, "bad_attachment_versions_response");
        }
        const contentLength = response.headers.get("content-length");
        if (contentLength !== null && (!/^\d+$/.test(contentLength)
            || Number(contentLength) !== version.bytes)) {
            throw new RelayApiError(0, "attachment_integrity_failure");
        }
        const reader = response.body?.getReader();
        let cipher: Uint8Array;
        if (!reader) {
            cipher = new Uint8Array(await response.arrayBuffer());
        } else {
            const chunks: Uint8Array[] = [];
            let totalBytes = 0;
            try {
                while (true) {
                    const chunk = await reader.read();
                    if (chunk.done) break;
                    totalBytes += chunk.value.byteLength;
                    if (totalBytes > version.bytes) {
                        await reader.cancel();
                        throw new RelayApiError(0, "attachment_integrity_failure");
                    }
                    chunks.push(chunk.value);
                }
            } finally {
                reader.releaseLock();
            }
            cipher = new Uint8Array(totalBytes);
            let offset = 0;
            for (const chunk of chunks) {
                cipher.set(chunk, offset);
                offset += chunk.byteLength;
            }
        }
        const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", cipher as BufferSource));
        const sha256 = Array.from(digest, byte => byte.toString(16).padStart(2, "0")).join("");
        if (cipher.length !== version.bytes || sha256 !== version.sha256) {
            cipher.fill(0);
            throw new RelayApiError(0, "attachment_integrity_failure");
        }
        return cipher;
    } finally {
        clearTimeout(timer);
        signal?.removeEventListener("abort", abort);
    }
}

/** Uploads one encrypted attachment version before its new card row references it. */
export async function putVaultAttachment(
    token: string,
    vaultId: string,
    attachmentID: string,
    contentVersion: string,
    cardUuid: string,
    cipher: Uint8Array,
    dekWrapped: Uint8Array,
): Promise<void> {
    const validUUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
    if (!validUUID.test(attachmentID) || !validUUID.test(contentVersion)
        || !validUUID.test(cardUuid) || cipher.length < 28 || dekWrapped.length < 28) {
        throw new RelayApiError(0, "bad_attachment_upload");
    }
    const digestBytes = new Uint8Array(await crypto.subtle.digest("SHA-256", cipher as BufferSource));
    const sha256 = Array.from(digestBytes, byte => byte.toString(16).padStart(2, "0")).join("");
    const uploadId = crypto.randomUUID();
    const attachmentPath = `/v1/vaults/${encodeURIComponent(vaultId)}/attachments/${encodeURIComponent(attachmentID)}`;
    let response: Response;
    try {
        response = await fetch(RELAY_BASE_URL + `${attachmentPath}?upload=${uploadId}&version=${contentVersion}`, {
            method: "PUT",
            headers: {
                authorization: `Bearer ${token}`,
                "content-type": "application/octet-stream",
                "X-UPW-Sync-Protocol": String(SYNC_PROTOCOL_VERSION),
            },
            body: cipher.slice().buffer,
            signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
        });
    } catch (error) {
        console.warn(`[upw] relay attachment upload failed id=${attachmentID} error=${error instanceof Error ? error.name : "unknown"}`);
        throw error;
    }
    if (!response.ok) {
        let code = `http_${response.status}`;
        try {
            code = ((await response.json()) as { error?: string }).error ?? code;
        } catch {
            // Keep the HTTP status as the machine-readable fallback.
        }
        throw new RelayApiError(response.status, code, response.headers.get("retry-after"));
    }
    await call("POST", `${attachmentPath}/commit`, token, {
        uploadId,
        sha256,
        cardUuid,
        contentVersion,
        dekWrapped: bytesToBase64(dekWrapped),
    });
    console.info("[upw] relay attachment version copied", { bytes: cipher.length });
}

/** Deletes a newly uploaded, still-unreferenced attachment after an aborted item copy. */
export async function deleteVaultAttachment(
    token: string,
    vaultId: string,
    attachmentID: string,
): Promise<void> {
    if (!UUID_PATTERN.test(attachmentID) || attachmentID === ZERO_UUID) {
        throw new RelayApiError(0, "bad_attachment_identity");
    }
    await call(
        "DELETE",
        `/v1/vaults/${encodeURIComponent(vaultId)}/attachments/${encodeURIComponent(attachmentID)}`,
        token,
    );
    console.info("[upw] relay orphan attachment removed");
}

/** 待写入的条目密文和原始 CAS 版本；密文在调用前完成加密。 */
export interface RelayAttachmentReference {
    attachmentId: string;
    contentVersion: string;
    restoreDeleted?: boolean;
}

export interface SaveVaultItem {
    uuid: string;
    revision: number;
    bodyB64: string;
    modifiedMs: number;
    attachmentRefs: RelayAttachmentReference[];
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
    const attachmentIDs = new Set<string>();
    const validAttachmentRefs = Array.isArray(item.attachmentRefs)
        && item.attachmentRefs.every(reference => {
            if (!reference || typeof reference.attachmentId !== "string"
                || !UUID_PATTERN.test(reference.attachmentId)
                || reference.attachmentId === ZERO_UUID
                || typeof reference.contentVersion !== "string"
                || !UUID_PATTERN.test(reference.contentVersion)
                || reference.contentVersion === ZERO_UUID
                || reference.restoreDeleted !== undefined && typeof reference.restoreDeleted !== "boolean") {
                return false;
            }
            const id = reference.attachmentId.toLowerCase();
            if (attachmentIDs.has(id)) return false;
            attachmentIDs.add(id);
            return true;
        });
    if (!validAttachmentRefs) throw new RelayApiError(0, "bad_attachment_reference");
    const response = await call("POST", `/v1/vaults/${encodeURIComponent(vaultId)}/items`, token, {
        items: [{
            uuid: item.uuid,
            kind: 1,
            op: "upsert",
            baseRevision,
            bodyB64: item.bodyB64,
            modifiedMs: item.modifiedMs,
            attachmentRefs: item.attachmentRefs.map(reference => ({
                attachmentId: reference.attachmentId.toLowerCase(),
                contentVersion: reference.contentVersion.toLowerCase(),
                ...(reference.restoreDeleted ? { restoreDeleted: true } : {}),
            })),
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

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ZERO_UUID = "00000000-0000-0000-0000-000000000000";

/** Self-revoke the caller's own session (sign-out hygiene; best-effort). */
export async function revokeOwnSession(token: string): Promise<void> {
    await call("DELETE", "/v1/auth/session", token);
}
