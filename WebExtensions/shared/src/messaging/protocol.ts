/**
 * Message contract between content script / popup / background and the
 * native app bridge. Every message carries a literal `type` tag.
 */

import type { FillCandidate } from "../core/types.js";

export type RequestMessage =
    | { type: "ping" }
    | { type: "query"; host: string }
    | { type: "fill"; candidate: FillCandidate }
    | { type: "unlock"; password: string };

export type ResponseMessage =
    | { type: "pong" }
    | { type: "items"; candidates: FillCandidate[] }
    | { type: "filled"; ok: boolean }
    | { type: "unlocked"; ok: boolean; count: number }
    | { type: "locked" }
    | { type: "error"; message: string };

export function isRequestMessage(value: unknown): value is RequestMessage {
    if (typeof value !== "object" || value === null) {
        return false;
    }
    const type = (value as { type?: unknown }).type;
    return type === "ping" || type === "query" || type === "fill" || type === "unlock";
}
