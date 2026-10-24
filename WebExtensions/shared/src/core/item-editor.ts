import { safeWebsiteUrl } from "./domain.js";
import type { ExtensionItem } from "./types.js";
import { VaultCryptoError } from "./vault-crypto.js";

/** 对现有卡片的可编辑投影；fieldValues 顺序必须与来源字段一致。 */
export interface ItemEdit {
    title: string;
    fieldValues: string[];
    notes: string;
}

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const INVALID_XML_TEXT = /[^\u0009\u000A\u000D\u0020-\uD7FF\uE000-\uFFFD\u{10000}-\u{10FFFF}]/u;

interface EditableCard {
    document: XMLDocument;
    card: Element;
    fields: Element[];
    note: Element | undefined;
}

/** 创建独立登录卡片所需的明文输入，不包含既有行的版本信息。 */
export interface NewLoginItem {
    id: string;
    title: string;
    username: string;
    password: string;
    url: string;
    notes: string;
}

/**
 * Build a standalone native DatabaseItemCodec card with DOM escaping, stable database label keys,
 * explicit fill tokens and millisecond timestamps. Empty credential fields remain editable.
 * This is creation only; existing cards must use updateItemXml to preserve opaque metadata.
 */
export function createLoginItemXml(item: NewLoginItem, nowMs = Date.now()): string {
    if (!item || typeof item.id !== "string" || !UUID_PATTERN.test(item.id)) {
        throw new VaultCryptoError("bad_item_identity");
    }
    if (!Number.isSafeInteger(nowMs) || nowMs < 0) throw new VaultCryptoError("bad_item_time");
    const values = [item.title, item.username, item.password, item.url, item.notes];
    if (values.some((value) => typeof value !== "string" || INVALID_XML_TEXT.test(value))) {
        throw new VaultCryptoError("bad_xml_text");
    }
    if (!item.title.trim()) throw new VaultCryptoError("bad_item_title");
    const websiteUrl = item.url === "" ? "" : safeWebsiteUrl(item.url);
    if (item.url !== "" && !websiteUrl) throw new VaultCryptoError("bad_item_url");
    if (typeof DOMParser === "undefined" || typeof XMLSerializer === "undefined") {
        throw new VaultCryptoError("dom_unavailable");
    }
    const document = new DOMParser().parseFromString("<card/>", "application/xml");
    const card = document.documentElement;
    card.setAttribute("id", item.id.toUpperCase());
    card.setAttribute("title", item.title);
    card.setAttribute("symbol", "key");
    card.setAttribute("color", "gray");
    card.setAttribute("autofill", "on");
    card.setAttribute("created", String(nowMs));
    card.setAttribute("modified", String(nowMs));
    const fields = [
        { name: "@string/login_field", type: "login", autofill: "username", value: item.username },
        { name: "@string/password_field", type: "password", autofill: "current-password", value: item.password },
        { name: "@string/url_field", type: "website", autofill: "url", value: websiteUrl },
    ];
    for (const { name, type, autofill, value } of fields) {
        const field = document.createElement("field");
        field.setAttribute("name", name);
        field.setAttribute("type", type);
        field.setAttribute("autofill", autofill);
        field.textContent = value;
        card.appendChild(field);
    }
    if (item.notes !== "") {
        const note = document.createElement("note");
        note.textContent = item.notes;
        card.appendChild(note);
    }
    const xml = serializePreservingCarriageReturns(document);
    console.info("[upw] login item XML created", { fields: fields.length });
    return xml;
}

/** Parse only standalone card fragments; never expand entities or flatten unfamiliar value markup. */
function parseCard(xml: string): EditableCard {
    // Reject declarations before parsing, including internal/external subsets. No network resolution is allowed.
    if (/<!\s*(?:DOCTYPE|ENTITY)\b/i.test(xml)) throw new VaultCryptoError("bad_xml");
    if (typeof DOMParser === "undefined") throw new VaultCryptoError("dom_unavailable");
    const document = new DOMParser().parseFromString(xml, "application/xml");
    const card = document.documentElement;
    if (document.doctype || !card || document.getElementsByTagNameNS("*", "parsererror").length > 0) {
        throw new VaultCryptoError("bad_xml");
    }
    if (card.tagName !== "card" || card.namespaceURI || !UUID_PATTERN.test(card.getAttribute("id") ?? "")) {
        throw new VaultCryptoError("unsupported_item_xml");
    }
    const fields: Element[] = [];
    let note: Element | undefined;
    if (Array.from(card.getElementsByTagName("*")).some((element) => element.localName === "card")) {
        throw new VaultCryptoError("unsupported_item_xml");
    }
    for (const element of Array.from(card.children)) {
        if (element.localName !== "field" && element.localName !== "note") continue;
        if (element.namespaceURI || element.children.length > 0) {
            throw new VaultCryptoError("unsupported_item_xml");
        }
        if (element.localName === "field") {
            fields.push(element);
        } else {
            if (note) throw new VaultCryptoError("unsupported_item_xml");
            note = element;
        }
    }
    return { document, card, fields, note };
}

/** Capture the original decrypted fragment and CAS revision in memory only; never persist this source. */
export function sourceFromFragment(xml: string, rowRevision: number): NonNullable<ExtensionItem["source"]> {
    parseCard(xml);
    if (!Number.isSafeInteger(rowRevision) || rowRevision < 1) {
        throw new VaultCryptoError("bad_item_revision");
    }
    return { xml, revision: rowRevision };
}

/** Read native plain-text/Markdown notes, preserving XML-decoded line breaks rather than trimming them. */
export function readItemDetail(item: ExtensionItem): { notes: string } {
    if (!item.source) return { notes: item.notes ?? "" };
    const { card, note } = parseCard(item.source.xml);
    if (card.getAttribute("id")?.toLowerCase() !== item.id.toLowerCase()) {
        throw new VaultCryptoError("item_id_mismatch");
    }
    return { notes: note?.textContent ?? "" };
}

/** Replace value text only, retaining comments, processing instructions and all element attributes. */
function replaceValue(element: Element, value: string): void {
    // Avoid reserializing unchanged CDATA/text unnecessarily. Unknown child elements were rejected by parseCard.
    if (element.textContent === value) return;
    const textNodes = Array.from(element.childNodes).filter((node) => node.nodeType === 3 || node.nodeType === 4);
    const text = element.ownerDocument.createTextNode(value);
    element.insertBefore(text, textNodes[0] ?? element.firstChild);
    for (const node of textNodes) element.removeChild(node);
}

/**
 * Preserve CR text/attribute values when XMLSerializer emits literal carriage returns.
 * XML parsers normalize literal CR/CRLF to LF; references retain the original semantic text.
 * Entity references are not interpreted in CDATA, comments or processing instructions.
 */
function serializePreservingCarriageReturns(document: XMLDocument): string {
    const xml = new XMLSerializer().serializeToString(document);
    const protectedMarkupOrCR = /<!\[CDATA\[[\s\S]*?\]\]>|<!--[\s\S]*?-->|<\?[\s\S]*?\?>|\r/g;
    return xml.replace(protectedMarkupOrCR, (match) => match === "\r" ? "&#13;" : match);
}

/**
 * Change only title, ordered field values, note text and the native `modified` millisecond attribute.
 * Unknown attributes (including field type/autofill/history tokens), attachments, labels and other children
 * stay in the DOM. XMLSerializer may normalize lexical escaping/quotes; it does not rebuild the card model.
 * Unsupported nested card/value structures are rejected instead of silently losing their data.
 */
export function updateItemXml(sourceXml: string, edit: ItemEdit, nowMs = Date.now()): string {
    const { document, card, fields, note } = parseCard(sourceXml);
    if (fields.length !== edit.fieldValues.length) throw new VaultCryptoError("field_count_mismatch");
    if (!Number.isSafeInteger(nowMs) || nowMs < 0) throw new VaultCryptoError("bad_item_time");
    const values = [edit.title, ...edit.fieldValues, edit.notes];
    if (values.some((value) => typeof value !== "string" || INVALID_XML_TEXT.test(value))) {
        throw new VaultCryptoError("bad_xml_text");
    }
    if (typeof XMLSerializer === "undefined") throw new VaultCryptoError("dom_unavailable");
    card.setAttribute("title", edit.title);
    card.setAttribute("modified", String(nowMs));
    fields.forEach((field, index) => replaceValue(field, edit.fieldValues[index]));
    // Native XML uses <note> with escaped plain text, not HTML <br> elements or a `notes` attribute.
    if (note) {
        replaceValue(note, edit.notes);
    } else if (edit.notes !== "") {
        const newNote = document.createElement("note");
        newNote.textContent = edit.notes;
        card.appendChild(newNote);
    }
    return serializePreservingCarriageReturns(document);
}
