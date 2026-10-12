/**
 * Promise-based request/response over runtime messaging, agnostic of the
 * concrete browser API (injected by platform adapters).
 */
let runtime = null;
export function setRuntime(port) {
    runtime = port;
}
export async function request(message) {
    if (!runtime) {
        return { type: "error", message: "runtime not configured" };
    }
    const response = await runtime.sendMessage(message);
    if (typeof response === "object" &&
        response !== null &&
        "type" in response) {
        return response;
    }
    return { type: "error", message: "malformed response" };
}
export function respondWith(handler) {
    if (!runtime) {
        return;
    }
    runtime.onMessage(async (message, sender) => {
        const response = await handler(message, sender);
        return response;
    });
}
