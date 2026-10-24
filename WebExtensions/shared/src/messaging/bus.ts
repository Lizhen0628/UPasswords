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

/** 注入当前浏览器的消息传输端口；测试可使用内存桩。 */
export function setRuntime(port: RuntimePort): void {
    runtime = port;
}

/** 发送普通请求并验证响应形状；未配置端口或无效响应会拒绝 Promise。 */
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

/** 注册异步消息处理器，响应的授权范围由处理器负责验证。 */
export function respondWith(handler: (message: unknown, sender: unknown) => Promise<ResponseMessage>): void {
    if (!runtime) {
        return;
    }
    runtime.onMessage(async (message, sender) => {
        const response = await handler(message, sender);
        return response as unknown;
    });
}
