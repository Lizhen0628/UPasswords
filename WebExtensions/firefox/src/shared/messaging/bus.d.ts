/**
 * Promise-based request/response over runtime messaging, agnostic of the
 * concrete browser API (injected by platform adapters).
 */
import type { RequestMessage, ResponseMessage } from "./protocol.js";
interface RuntimePort {
    sendMessage(message: RequestMessage): Promise<unknown>;
    onMessage(listener: (message: unknown, sender: unknown) => Promise<unknown> | unknown): void;
}
export declare function setRuntime(port: RuntimePort): void;
export declare function request(message: RequestMessage): Promise<ResponseMessage>;
export declare function respondWith(handler: (message: unknown, sender: unknown) => Promise<ResponseMessage>): void;
export {};
