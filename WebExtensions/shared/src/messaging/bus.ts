/**
 * Promise-based request/response over runtime messaging, agnostic of the
 * concrete browser API (injected by platform adapters).
 */

import type { RequestMessage, ResponseMessage } from "./protocol.js";

interface RuntimePort {
    sendMessage(message: RequestMessage): Promise<unknown>;
    onMessage(listener: (message: unknown, sender: unknown) => Promise<unknown> | unknown): void;
}

let runtime: RuntimePort | null = null;

export function setRuntime(port: RuntimePort): void {
    runtime = port;
}

export async function request(message: RequestMessage): Promise<ResponseMessage> {
    if (!runtime) {
        return { type: "error", message: "runtime not configured" };
    }
    const response = await runtime.sendMessage(message);
    if (
        typeof response === "object" &&
        response !== null &&
        "type" in (response as Record<string, unknown>)
    ) {
        return response as ResponseMessage;
    }
    return { type: "error", message: "malformed response" };
}

export function respondWith(handler: (message: unknown, sender: unknown) => Promise<ResponseMessage>): void {
    if (!runtime) {
        return;
    }
    runtime.onMessage(async (message, sender) => {
        const response = await handler(message, sender);
        return response as unknown;
    });
}
