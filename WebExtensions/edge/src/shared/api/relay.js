/**
 * Relay API client for standalone extension contexts (no native bridge):
 * email-code login, vault registry, key envelope and vault body (R2 replica).
 * Mirrors the Swift `RelayClient` paths; the session token lives in
 * browser.storage.local managed by the caller.
 */
export const RELAY_BASE_URL = "https://api.upasswords.com";
/** 网络黑洞兜底:超时后 fetch 以 TimeoutError 拒绝,UI 可恢复(否则按钮永久禁用)。 */
const REQUEST_TIMEOUT_MS = 30_000;
export class RelayApiError extends Error {
    status;
    code;
    constructor(status, code) {
        super(`relay api ${status}: ${code}`);
        this.status = status;
        this.code = code;
        this.name = "RelayApiError";
    }
}
async function call(method, path, token, body) {
    const headers = {};
    if (body !== undefined)
        headers["content-type"] = "application/json";
    if (token)
        headers.authorization = `Bearer ${token}`;
    const response = await fetch(RELAY_BASE_URL + path, {
        method,
        headers,
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    });
    if (!response.ok) {
        let code = `http_${response.status}`;
        try {
            code = (await response.json()).error ?? code;
        }
        catch {
            // keep http_ code
        }
        throw new RelayApiError(response.status, code);
    }
    return response.json();
}
export function base64ToBytes(b64) {
    const binary = atob(b64);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++)
        bytes[i] = binary.charCodeAt(i);
    return bytes;
}
/** Send an email verification code (202 on accepted; rate-limited → 429). */
export async function requestCode(email, purpose = "login") {
    await call("POST", "/v1/auth/code", null, { email, purpose });
}
/** Verify the code; registers the account on first login, returns a session. */
export async function verifyCode(email, code, deviceName) {
    return (await call("POST", "/v1/auth/verify", null, {
        email,
        code,
        deviceName,
    }));
}
/** Vaults of the logged-in account. */
export async function listVaults(token) {
    const response = (await call("GET", "/v1/vaults", token));
    return response.vaults ?? [];
}
/**
 * Single-vault detail including the key envelope (base64 ciphertext);
 * the unlock data source for the extension.
 */
export async function getVaultEnvelope(token, vaultId) {
    const detail = (await call("GET", `/v1/vaults/${vaultId}`, token));
    const { envelope, ...meta } = detail;
    return { envelope, meta };
}
/** Download the vault body replica (encrypted container bytes). */
export async function getVaultBody(token, vaultId) {
    const response = await fetch(`${RELAY_BASE_URL}/v1/vaults/${vaultId}/body`, {
        headers: { authorization: `Bearer ${token}` },
        signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    });
    if (!response.ok) {
        throw new RelayApiError(response.status, "body_not_found");
    }
    return new Uint8Array(await response.arrayBuffer());
}
