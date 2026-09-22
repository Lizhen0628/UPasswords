// Core data model — mirrors Models/CoreModels.swift (XItem/XCard/XField/…
// of the original SafeInCloud app). Field/attribute names match the original
// database XML one-to-one.
import { db, resolve } from "./i18n";

export const FIELD_TYPES = [
  "login",
  "password",
  "pin",
  "number",
  "date",
  "phone",
  "website",
  "email",
  "one_time_password",
  "text",
  "expiry",
  "secret",
] as const;
export type FieldType = (typeof FIELD_TYPES)[number];

export const AUTOFILLS = [
  "off",
  "username",
  "current-password",
  "url",
  "one-time-code",
  "cc-number",
  "cc-name",
  "cc-exp",
  "cc-csc",
] as const;
export type Autofill = (typeof AUTOFILLS)[number];

export interface HistoryEntry {
  value: string;
  time: number; // millis since epoch
}

export interface Field {
  id: string; // uuid
  name: string;
  type: FieldType;
  value: string;
  autofill: Autofill;
  history: HistoryEntry[];
}

export interface Attachment {
  id: string; // uuid
  name: string;
  /** base64 payload (decoded bytes live in the Rust side / XML) */
  data: string;
}

export interface CardLabel {
  id: number;
  name: string;
  color?: string | null;
  type?: string | null;
  pinToTop: boolean;
  timeStamp: number; // millis
}

export interface Ghost {
  id: number;
  time: number;
}

export interface Card {
  id: number;
  title: string;
  symbol?: string | null;
  color?: string | null;
  customIconName?: string | null;
  template: boolean;
  autofillEnabled: boolean;
  favorite: boolean;
  archived: boolean;
  trashed: boolean;
  expiration?: number | null;
  reminder?: number | null;
  created: number;
  modified: number;
  useWebsiteIcon: boolean;
  watch: boolean;
  fields: Field[];
  notes: string;
  labelIds: number[];
  images: Attachment[];
  files: Attachment[];
}

export interface PasswordDatabase {
  labels: CardLabel[];
  cards: Card[];
  ghosts: Ghost[];
}

export function emptyDatabase(): PasswordDatabase {
  return { labels: [], cards: [], ghosts: [] };
}

export function uuid(): string {
  if (typeof crypto.randomUUID === "function") return crypto.randomUUID();
  // RFC 4122 v4 fallback
  const b = new Uint8Array(16);
  crypto.getRandomValues(b);
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  const h = [...b].map((x) => x.toString(16).padStart(2, "0")).join("");
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}

export function newField(name = "", type: FieldType = "text"): Field {
  return { id: uuid(), name, type, value: "", autofill: "off", history: [] };
}

export function newCard(id: number, now = Date.now()): Card {
  return {
    id,
    title: "",
    symbol: null,
    color: null,
    customIconName: null,
    template: false,
    autofillEnabled: false,
    favorite: false,
    archived: false,
    trashed: false,
    expiration: null,
    reminder: null,
    created: now,
    modified: now,
    useWebsiteIcon: false,
    watch: false,
    fields: [],
    notes: "",
    labelIds: [],
    images: [],
    files: [],
  };
}

// ----- FieldType predicates (XField.h) -----

export function isHiddenType(t: FieldType): boolean {
  return t === "password" || t === "pin" || t === "one_time_password" || t === "secret";
}
export function isPasswordType(t: FieldType): boolean {
  return t === "password" || t === "pin" || t === "secret";
}
export function isLoginType(t: FieldType): boolean {
  return t === "login" || t === "email";
}
export function isSearchableType(t: FieldType): boolean {
  return t !== "one_time_password";
}
export function needsScoring(t: FieldType): boolean {
  return t === "password";
}

export function fieldTypeLocalizedName(t: FieldType): string {
  return db(`${t}_type`);
}

export function autofillLocalizedName(a: Autofill): string {
  return db(`${a}_autofill`);
}

// ----- Card derived accessors (XCard.h) -----

export function loginField(c: Card): Field | undefined {
  return c.fields.find((f) => isLoginType(f.type));
}
export function passwordField(c: Card): Field | undefined {
  return c.fields.find((f) => f.type === "password");
}
export function oneTimePasswordField(c: Card): Field | undefined {
  return c.fields.find((f) => f.type === "one_time_password");
}
export function websiteField(c: Card): Field | undefined {
  return c.fields.find((f) => f.type === "website");
}

export function cardLogin(c: Card): string {
  return loginField(c)?.value ?? "";
}
export function cardPassword(c: Card): string {
  return passwordField(c)?.value ?? "";
}
export function cardWebsite(c: Card): string {
  return websiteField(c)?.value ?? "";
}

export function days(fromMillis: number, to = Date.now()): number {
  return Math.floor((fromMillis - to) / 86_400_000);
}
export function isExpiring(c: Card): boolean {
  if (c.expiration == null) return false;
  const d = days(c.expiration);
  return d >= 0 && d <= 30;
}
export function expiringInDays(c: Card): number {
  return c.expiration != null ? days(c.expiration) : 0;
}
export function isExpired(c: Card): boolean {
  if (c.expiration == null) return false;
  return days(c.expiration) < 0;
}

/** XCard.size — total byte size of the card payload. */
export function cardSize(c: Card): number {
  const enc = new TextEncoder();
  return (
    enc.encode(c.notes).length +
    c.fields.reduce((s, f) => s + enc.encode(f.value).length, 0) +
    c.images.reduce((s, a) => s + base64Bytes(a.data), 0) +
    c.files.reduce((s, a) => s + base64Bytes(a.data), 0)
  );
}
function base64Bytes(b64: string): number {
  const pad = b64.endsWith("==") ? 2 : b64.endsWith("=") ? 1 : 0;
  return Math.max(0, Math.floor((b64.length * 3) / 4) - pad);
}

/** XCard.asPlainText — plain-text dump used by TXT export. */
export function asPlainText(c: Card): string {
  const lines = [c.title];
  for (const f of c.fields) lines.push(`${f.name}: ${f.value}`);
  if (c.notes) lines.push(c.notes);
  return lines.join("\n");
}

// ----- PasswordDatabase adapter accessors (DatabaseAdapter.h) -----

export function cardById(dbase: PasswordDatabase, id: number): Card | undefined {
  return dbase.cards.find((c) => c.id === id);
}
export function labelById(dbase: PasswordDatabase, id: number): CardLabel | undefined {
  return dbase.labels.find((l) => l.id === id);
}
export function activeCards(dbase: PasswordDatabase): Card[] {
  return dbase.cards.filter((c) => !c.template && !c.trashed);
}
export function templateCards(dbase: PasswordDatabase): Card[] {
  return dbase.cards.filter((c) => c.template);
}

export function isUsedItemId(dbase: PasswordDatabase, id: number): boolean {
  return (
    dbase.cards.some((c) => c.id === id) ||
    dbase.labels.some((l) => l.id === id) ||
    dbase.ghosts.some((g) => g.id === id)
  );
}

/** DatabaseAdapter fresh item id (max + 1, skipping used ids). */
export function nextItemId(dbase: PasswordDatabase): number {
  let id = 1;
  while (isUsedItemId(dbase, id)) id += 1;
  return id;
}

/** XField history bookkeeping: values + modification times, capped at 20. */
export function putHistoryValue(field: Field, v: string, time: number) {
  if (!v || v === field.value) return;
  field.history = field.history.filter((h) => h.value !== v);
  field.history.push({ value: v, time });
  if (field.history.length > 20) field.history = field.history.slice(-20);
}

// ----- Merge (XDatabase.mergeWithDatabase:) — used by WebDAV sync -----

export function mergeDatabase(
  target: PasswordDatabase,
  other: PasswordDatabase,
): PasswordDatabase {
  const ghostIds = new Set([...other.ghosts, ...target.ghosts].map((g) => g.id));

  const byLabel = new Map(target.labels.map((l) => [l.id, l]));
  for (const l of other.labels) {
    if (ghostIds.has(l.id)) continue;
    const mine = byLabel.get(l.id);
    if (mine && mine.timeStamp >= l.timeStamp) continue;
    byLabel.set(l.id, l);
  }
  const labels = [...byLabel.values()].sort((a, b) => a.id - b.id);

  const byCard = new Map(target.cards.map((c) => [c.id, c]));
  for (const c of other.cards) {
    if (ghostIds.has(c.id)) continue;
    const mine = byCard.get(c.id);
    if (mine && mine.modified >= c.modified) continue;
    byCard.set(c.id, c);
  }
  const cards = [...byCard.values()].sort((a, b) => a.id - b.id);

  const byGhost = new Map(target.ghosts.map((g) => [g.id, g]));
  for (const g of other.ghosts) byGhost.set(g.id, g);
  const ghosts = [...byGhost.values()].sort((a, b) => a.id - b.id);

  return { labels, cards, ghosts };
}

/** Registers a tombstone and removes the item (deleteCardWithId:). */
export function deleteCardPermanently(
  dbase: PasswordDatabase,
  id: number,
  now = Date.now(),
) {
  dbase.cards = dbase.cards.filter((c) => c.id !== id);
  const g = dbase.ghosts.find((x) => x.id === id);
  if (g) g.time = now;
  else dbase.ghosts.push({ id, time: now });
}

/** Walks a freshly loaded database resolving `@string/` refs (XSanitizer-adjacent
 * behavior of the original parser, which localizes at parse time). */
export function resolveStringRefs(dbase: PasswordDatabase) {
  for (const l of dbase.labels) l.name = resolve(l.name);
  for (const c of dbase.cards) {
    c.title = resolve(c.title);
    for (const f of c.fields) f.name = resolve(f.name);
  }
}
