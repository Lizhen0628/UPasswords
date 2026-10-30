import { safeWebsiteUrl } from "./domain.js";
import type { ExtensionItem } from "./types.js";
import { VaultCryptoError } from "./vault-crypto.js";

/** 对现有卡片的可编辑投影；fieldValues 顺序必须与来源字段一致。 */
export interface ItemEdit {
    title: string;
    fieldValues: string[];
    fields?: Array<{ id?: string; name: string; type: string; value: string; autofill: string; siteMatch?: string }>;
    notes: string;
}

/** Decrypted candidate input for a field-level conflict review. */
export interface CardConflictCandidate {
    candidateId: string;
    kind: number;
    op: "upsert" | "delete";
    modifiedMs: number;
    xml?: string;
}

/** One stable field identity and the candidate versions available for it. */
export interface CardConflictFieldGroup {
    fieldId: string;
    title: string;
    requiresChoice: boolean;
    defaultCandidateId?: string;
    options: Array<{ candidateId: string; present: boolean }>;
}

/** Safe field and note choices offered for one conflict candidate set. */
export interface CardConflictComposition {
    fieldGroups: CardConflictFieldGroup[];
    notesRequireChoice: boolean;
    defaultNotesCandidateId?: string;
}

/** Explicit sources selected by the user for a composed card. */
export interface CardConflictSelection {
    baseCandidateId: string;
    fieldSources: Record<string, string>;
    notesCandidateId?: string;
    nowMs?: number;
}

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const INVALID_XML_TEXT = /[^\u0009\u000A\u000D\u0020-\uD7FF\uE000-\uFFFD\u{10000}-\u{10FFFF}]/u;

interface EditableCard {
    document: XMLDocument;
    card: Element;
    fields: Element[];
    note: Element | undefined;
}

interface ParsedConflictCandidate {
    candidate: CardConflictCandidate;
    parsed: EditableCard;
    fields: Map<string, Element>;
    notes: string;
}

/** 创建独立登录卡片所需的明文输入，不包含既有行的版本信息。 */
export interface NewLoginItem {
    id: string;
    title: string;
    username: string;
    password: string;
    url: string;
    siteMatch?: string;
    sites?: Array<{ url: string; mode: string }>;
    notes: string;
    fields?: Array<{ id?: string; name: string; type: string; value: string; autofill: string; siteMatch?: string }>;
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
    const websiteUrl = item.url === "" ? "" : item.siteMatch === "wildcard"
        ? safeWebsiteUrl(item.url.replaceAll("*", "wildcard-token")) : safeWebsiteUrl(item.url);
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
    const associations = [
        { url: item.url, mode: item.siteMatch ?? "domain" },
        ...(item.sites ?? []),
    ].filter(site => site.url.trim());
    for (const association of associations) {
        const safe = safeWebsiteUrl(association.mode === "wildcard" ? association.url.replaceAll("*", "wildcard-token") : association.url);
        if (!safe || !["domain", "wildcard", "exactURL"].includes(association.mode)) throw new VaultCryptoError("bad_item_url");
    }
    const fields: NonNullable<NewLoginItem["fields"]> = item.fields?.length ? item.fields : [
        { name: "@string/login_field", type: "login", autofill: "username", value: item.username },
        { name: "@string/password_field", type: "password", autofill: "current-password", value: item.password },
        ...associations.map((site, index) => ({
            name: index === 0 ? "@string/url_field" : "Website",
            type: "website",
            autofill: "url",
            value: site.mode === "wildcard" ? site.url : safeWebsiteUrl(site.url) ?? site.url,
            siteMatch: site.mode,
        })),
    ];
    if (!fields.some(field => field.type === "website")) fields.push({ name: "@string/url_field", type: "website", autofill: "url", value: "" });
    for (const field of fields) {
        if (field.type === "website" && field.value.trim()
            && !safeWebsiteUrl(field.siteMatch === "wildcard" ? field.value.replaceAll("*", "wildcard-token") : field.value)) {
            throw new VaultCryptoError("bad_item_url");
        }
        const node = document.createElement("field");
        node.setAttribute("id", field.id ?? crypto.randomUUID().toUpperCase());
        node.setAttribute("name", field.name);
        node.setAttribute("type", field.type);
        node.setAttribute("autofill", field.autofill || "off");
        if (field.type === "website" && field.siteMatch) node.setAttribute("site-match", field.siteMatch);
        node.textContent = field.value;
        card.appendChild(node);
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

/**
 * Re-identify a conflict candidate before restoring it after source deletion.
 * The new UUID is part of the row-sync AAD, so the XML identity and timestamp
 * must change together while all unknown attributes and child elements remain.
 */
export function reidentifyItemXml(sourceXml: string, id: string, nowMs = Date.now()): string {
    if (!UUID_PATTERN.test(id)) throw new VaultCryptoError("bad_item_identity");
    if (typeof sourceXml !== "string" || /<!\s*(?:DOCTYPE|ENTITY)\b/i.test(sourceXml)) {
        throw new VaultCryptoError("bad_xml");
    }
    if (!Number.isSafeInteger(nowMs) || nowMs < 0) throw new VaultCryptoError("bad_item_time");
    if (typeof DOMParser === "undefined" || typeof XMLSerializer === "undefined") {
        throw new VaultCryptoError("dom_unavailable");
    }
    const document = new DOMParser().parseFromString(sourceXml, "application/xml");
    const root = document.documentElement;
    if (document.doctype || !root || root.namespaceURI
        || !["card", "label", "user_profile"].includes(root.tagName)
        || document.querySelector("parsererror")) {
        throw new VaultCryptoError("unsupported_item_xml");
    }
    if (root.querySelector("card, user_profile")) {
        throw new VaultCryptoError("unsupported_item_xml");
    }
    root.setAttribute("id", id.toUpperCase());
    if (root.tagName === "label") root.setAttribute("time", String(nowMs));
    else root.setAttribute("modified", String(nowMs));
    return serializePreservingCarriageReturns(document);
}

export interface AttachmentIdentityRemap {
    sourceID: string;
    sourceVersion: string;
    attachmentID: string;
    contentVersion: string;
}

/** Copies a card fragment with new row, field, and attachment identities. */
export function copyCardXmlForNewIdentity(
    sourceXml: string,
    sourceID: string,
    destinationID: string,
    attachmentRemaps: AttachmentIdentityRemap[],
    nowMs = Date.now(),
): string {
    if (!UUID_PATTERN.test(sourceID) || !UUID_PATTERN.test(destinationID)
        || !Number.isSafeInteger(nowMs) || nowMs < 0
        || /<!\s*(?:DOCTYPE|ENTITY)\b/i.test(sourceXml)
        || typeof DOMParser === "undefined" || typeof XMLSerializer === "undefined") {
        throw new VaultCryptoError("bad_item_identity");
    }
    const document = new DOMParser().parseFromString(sourceXml, "application/xml");
    const card = document.documentElement;
    if (document.doctype || !card || card.namespaceURI || card.tagName !== "card"
        || document.querySelector("parsererror")
        || card.getAttribute("id")?.toLowerCase() !== sourceID.toLowerCase()
        || card.querySelector("card, user_profile")) {
        throw new VaultCryptoError("unsupported_item_xml");
    }
    const remaps = new Map(attachmentRemaps.map((entry) => [
        `${entry.sourceID.toLowerCase()}:${entry.sourceVersion.toLowerCase()}`,
        entry,
    ]));
    if (remaps.size !== attachmentRemaps.length) throw new VaultCryptoError("bad_attachment_identity");

    card.setAttribute("id", destinationID.toUpperCase());
    card.setAttribute("modified", String(nowMs));
    for (const field of Array.from(card.children).filter((element) => element.tagName === "field")) {
        if (field.namespaceURI || field.children.length > 0) throw new VaultCryptoError("unsupported_item_xml");
        field.setAttribute("id", crypto.randomUUID().toUpperCase());
    }
    const attachments = Array.from(card.children)
        .filter((element) => element.tagName === "image" || element.tagName === "file");
    if (attachments.length !== remaps.size) throw new VaultCryptoError("attachment_reference_changed");
    for (const attachment of attachments) {
        const sourceAttachmentID = attachment.getAttribute("id");
        const sourceVersion = attachment.getAttribute("version");
        if (attachment.namespaceURI || !sourceAttachmentID || !sourceVersion
            || !UUID_PATTERN.test(sourceAttachmentID) || !UUID_PATTERN.test(sourceVersion)) {
            throw new VaultCryptoError("bad_attachment_identity");
        }
        const remap = remaps.get(`${sourceAttachmentID.toLowerCase()}:${sourceVersion.toLowerCase()}`);
        if (!remap || !UUID_PATTERN.test(remap.attachmentID) || !UUID_PATTERN.test(remap.contentVersion)) {
            throw new VaultCryptoError("attachment_reference_changed");
        }
        attachment.setAttribute("id", remap.attachmentID.toUpperCase());
        attachment.setAttribute("version", remap.contentVersion.toUpperCase());
    }
    return serializePreservingCarriageReturns(document);
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

/** Returns field choices only for readable, attachment-free cards with stable unique field UUIDs. */
export function analyzeCardConflict(
    candidates: CardConflictCandidate[],
): CardConflictComposition | null {
    const parsed = parseConflictCandidates(candidates);
    if (!parsed) return null;

    const fieldIDs = new Set(parsed.flatMap(({ fields }) => [...fields.keys()]));
    const orderedFieldIDs = [
        ...parsed[0].fields.keys(),
        ...[...fieldIDs].filter((fieldId) => !parsed[0].fields.has(fieldId)).sort(),
    ];
    const fieldGroups = orderedFieldIDs.map((fieldId): CardConflictFieldGroup => {
        const options = parsed.map(({ candidate, fields }) => ({
            candidateId: candidate.candidateId,
            field: fields.get(fieldId),
        }));
        const variants = new Set(options.map(({ field }) => field ? fieldFingerprint(field) : "missing"));
        const representative = options.find(({ field }) => field)?.field;
        return {
            fieldId,
            title: representative?.getAttribute("name") || representative?.getAttribute("type") || fieldId,
            requiresChoice: variants.size > 1,
            ...(variants.size === 1 ? { defaultCandidateId: options[0].candidateId } : {}),
            options: options.map(({ candidateId, field }) => ({ candidateId, present: field !== undefined })),
        };
    });
    const notesVariants = new Set(parsed.map(({ notes }) => notes));
    return {
        fieldGroups,
        notesRequireChoice: notesVariants.size > 1,
        ...(notesVariants.size === 1 ? { defaultNotesCandidateId: parsed[0].candidate.candidateId } : {}),
    };
}

/** Builds a card from explicit candidate choices while retaining the chosen base card's opaque metadata. */
export function composeCardConflict(
    candidates: CardConflictCandidate[],
    selection: CardConflictSelection,
): { xml: string; modifiedMs: number } {
    const parsed = parseConflictCandidates(candidates);
    if (!parsed || !selection || !selection.fieldSources || typeof XMLSerializer === "undefined") {
        throw new VaultCryptoError("conflict_not_composable");
    }
    const analysis = analyzeCardConflict(candidates);
    const base = parsed.find(({ candidate }) => candidate.candidateId === selection.baseCandidateId);
    if (!analysis || !base) throw new VaultCryptoError("conflict_selection_invalid");

    const document = base.parsed.document;
    const selectedFields: Element[] = [];
    for (const group of analysis.fieldGroups) {
        const sourceID = group.requiresChoice
            ? selection.fieldSources[group.fieldId]
            : group.defaultCandidateId;
        const source = parsed.find(({ candidate }) => candidate.candidateId === sourceID);
        if (!source) throw new VaultCryptoError("conflict_selection_incomplete");
        const field = source.fields.get(group.fieldId);
        if (field) selectedFields.push(field);
    }

    const notesCandidateID = analysis.notesRequireChoice
        ? selection.notesCandidateId
        : analysis.defaultNotesCandidateId;
    const notesSource = parsed.find(({ candidate }) => candidate.candidateId === notesCandidateID);
    if (!notesSource) throw new VaultCryptoError("conflict_selection_incomplete");

    const baseCard = base.parsed.card;
    const marker = document.createComment("conflict-fields");
    baseCard.insertBefore(marker, base.parsed.fields[0] ?? base.parsed.note ?? null);
    for (const field of base.parsed.fields) baseCard.removeChild(field);
    for (const field of selectedFields) {
        baseCard.insertBefore(base.parsed.document.importNode(field, true), marker);
    }
    baseCard.removeChild(marker);

    const baseNote = base.parsed.note;
    const noteAnchor = baseNote?.nextSibling ?? null;
    if (baseNote) baseCard.removeChild(baseNote);
    const selectedNote = notesSource.parsed.note;
    if (selectedNote) {
        baseCard.insertBefore(base.parsed.document.importNode(selectedNote, true), noteAnchor);
    }

    const nowMs = selection.nowMs ?? Date.now();
    if (!Number.isSafeInteger(nowMs) || nowMs < 0) throw new VaultCryptoError("bad_item_time");
    const maxModifiedMs = Math.max(...parsed.map(({ candidate }) => candidate.modifiedMs));
    const modifiedMs = Math.max(nowMs, maxModifiedMs + 1);
    if (!Number.isSafeInteger(modifiedMs) || modifiedMs < 0) {
        throw new VaultCryptoError("bad_item_time");
    }
    baseCard.setAttribute("modified", String(modifiedMs));
    return { xml: serializePreservingCarriageReturns(document), modifiedMs };
}

function parseConflictCandidates(candidates: CardConflictCandidate[]): ParsedConflictCandidate[] | null {
    if (!Array.isArray(candidates) || candidates.length < 2
        || candidates.some((candidate) => candidate.kind !== 1 || candidate.op !== "upsert"
            || typeof candidate.xml !== "string" || !/^[0-9a-f]{32}$/i.test(candidate.candidateId)
            || !Number.isSafeInteger(candidate.modifiedMs) || candidate.modifiedMs < 0)
        || new Set(candidates.map(({ candidateId }) => candidateId)).size !== candidates.length) {
        return null;
    }
    try {
        const parsed = candidates.map((candidate): ParsedConflictCandidate => {
            const card = parseCard(candidate.xml ?? "");
            if (Array.from(card.card.children).some((element) => ["image", "file"].includes(element.tagName))) {
                throw new VaultCryptoError("conflict_has_attachments");
            }
            const fields = new Map<string, Element>();
            for (const field of card.fields) {
                const id = field.getAttribute("id")?.toLowerCase();
                if (!id || !UUID_PATTERN.test(id) || fields.has(id)) {
                    throw new VaultCryptoError("bad_field_identity");
                }
                fields.set(id, field);
            }
            return {
                candidate,
                parsed: card,
                fields,
                notes: card.note?.textContent ?? "",
            };
        });
        const identity = parsed[0].parsed.card.getAttribute("id")?.toLowerCase();
        return identity && parsed.every(({ parsed: card }) => card.card.getAttribute("id")?.toLowerCase() === identity)
            ? parsed : null;
    } catch {
        return null;
    }
}

function fieldFingerprint(field: Element): string {
    const attributes = Array.from(field.attributes)
        .map(({ name, value }) => [name, value] as const)
        .sort(([left], [right]) => left.localeCompare(right));
    const content = Array.from(field.childNodes).map((node) => [node.nodeType, node.nodeValue]);
    return JSON.stringify([attributes, content]);
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
    if (edit.fields) {
        if (!edit.title.trim() || !Number.isSafeInteger(nowMs) || nowMs < 0) throw new VaultCryptoError("bad_item_edit");
        const byID = new Map(fields.map(field => [field.getAttribute("id")?.toLowerCase(), field]));
        const ordered: Element[] = [];
        for (const field of edit.fields) {
            if (!field.name || !field.type || typeof field.value !== "string") throw new VaultCryptoError("bad_item_field");
            if (field.type === "website" && field.value.trim()
                && !safeWebsiteUrl(field.siteMatch === "wildcard" ? field.value.replaceAll("*", "wildcard-token") : field.value)) {
                throw new VaultCryptoError("bad_item_url");
            }
            const element = field.id ? byID.get(field.id.toLowerCase()) : undefined;
            if (field.id && (!element || element.getAttribute("id") !== field.id)) throw new VaultCryptoError("field_identity_changed");
            const next = element ?? document.createElement("field");
            if (!element) next.setAttribute("id", field.id ?? crypto.randomUUID().toUpperCase());
            replaceValue(next, field.value);
            next.setAttribute("name", field.name);
            next.setAttribute("type", field.type);
            next.setAttribute("autofill", field.autofill || "off");
            if (field.type === "website" && field.siteMatch) next.setAttribute("site-match", field.siteMatch);
            else next.removeAttribute("site-match");
            ordered.push(next);
        }
        for (const field of fields) card.removeChild(field);
        const anchor = Array.from(card.children).find(child => child.tagName !== "note") ?? note ?? null;
        for (const field of ordered) card.insertBefore(field, anchor);
        card.setAttribute("title", edit.title);
        card.setAttribute("modified", String(nowMs));
        if (note) replaceValue(note, edit.notes);
        else if (edit.notes) { const added = document.createElement("note"); added.textContent = edit.notes; card.appendChild(added); }
        return serializePreservingCarriageReturns(document);
    }
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
