/**
 * Message contract between content script / popup / background and the
 * native app bridge. Every message carries a literal `type` tag.
 */
export function isRequestMessage(value) {
    if (typeof value !== "object" || value === null) {
        return false;
    }
    const type = value.type;
    return type === "ping" || type === "query" || type === "fill" || type === "unlock";
}
