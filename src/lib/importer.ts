// Import/export — mirrors Services/ImportExport.swift: the CSV engine, 18
// import formats (SafeInCloud XML / Chrome-family / LastPass / Bitwarden
// CSV+JSON / Dashlane / 1Password / Safari / NordPass / Proton / KeePass /
// Keeper / RoboForm / generic CSV) and XML/CSV/TXT export.
import type { Card, CardLabel, PasswordDatabase } from "./models";
import { newCard, newField, nextItemId } from "./models";
import { db } from "./i18n";

// ----- CSV engine (CsvFormat.h) -----

/** RFC 4180-ish parser supporting quotes and embedded separators. */
export function csvRows(text: string): string[][] {
  const rows: string[][] = [];
  let field = "";
  let row: string[] = [];
  let inQuotes = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (inQuotes) {
      if (c === '"') {
        if (text[i + 1] === '"') {
          field += '"';
          i += 1;
        } else {
          inQuotes = false;
        }
      } else {
        field += c;
      }
    } else if (c === '"') {
      inQuotes = true;
    } else if (c === "," || c === "\t") {
      row.push(field);
      field = "";
    } else if (c === "\n") {
      row.push(field);
      field = "";
      if (!(row.length === 1 && row[0] === "")) rows.push(row);
      row = [];
    } else if (c !== "\r") {
      field += c;
    }
  }
  row.push(field);
  if (!(row.length === 1 && row[0] === "")) rows.push(row);
  return rows;
}

export function csvEscape(s: string): string {
  return `"${s.replaceAll('"', '""')}"`;
}

// ----- Import formats -----

export interface ImportResult {
  cards: Card[];
  labels: CardLabel[]; // labels referenced by imported cards (new ones to merge)
  count: number;
}

type ColumnMap = Record<"name" | "login" | "password" | "url" | "notes", string[]>;

function headerIndexOf(aliases: string[], header: string[]): number | undefined {
  const lower = header.map((h) => h.toLowerCase().trim());
  for (const a of aliases) {
    const i = lower.indexOf(a);
    if (i >= 0) return i;
  }
  for (const a of aliases) {
    const i = lower.findIndex((h) => h.startsWith(a));
    if (i >= 0) return i;
  }
  return undefined;
}

function importCsv(
  state: ImportState,
  text: string,
  map: ColumnMap,
  now: number,
  folderColumn?: string[],
  folderToLabel?: (folder: string, state: ImportState) => number | undefined,
): number {
  const rows = csvRows(text);
  if (rows.length < 2) throw new Error("cannot parse");
  const header = rows.shift()!;
  const nameIdx = headerIndexOf(map.name, header);
  if (nameIdx === undefined) throw new Error("cannot parse");
  const loginIdx = headerIndexOf(map.login, header);
  const pwIdx = headerIndexOf(map.password, header);
  const urlIdx = headerIndexOf(map.url, header);
  const noteIdx = headerIndexOf(map.notes, header);
  const folderIdx = folderColumn ? headerIndexOf(folderColumn, header) : undefined;

  let count = 0;
  for (const row of rows) {
    const col = (i?: number) => (i !== undefined && i < row.length ? row[i] : "");
    if (!col(nameIdx) && !col(loginIdx) && !col(pwIdx)) continue;
    const card = newCard(state.nextId(), now);
    card.title = col(nameIdx) || col(loginIdx) || "—";
    card.symbol = "key";
    card.color = "gray";
    if (col(loginIdx)) card.fields.push({ ...newField(db("login_field")), type: "login", value: col(loginIdx), autofill: "username" });
    if (col(pwIdx)) card.fields.push({ ...newField(db("password_field")), type: "password", value: col(pwIdx), autofill: "current-password" });
    if (col(urlIdx)) card.fields.push({ ...newField(db("url_field")), type: "website", value: col(urlIdx), autofill: "url" });
    if (col(noteIdx)) card.notes = col(noteIdx);
    if (folderIdx !== undefined && folderToLabel) {
      const folder = col(folderIdx);
      if (folder) {
        const labelId = folderToLabel(folder, state);
        if (labelId !== undefined) card.labelIds.push(labelId);
      }
    }
    state.push(card);
    count += 1;
  }
  return count;
}

/** Shared mutable state: accumulates new cards/labels against the live db. */
class ImportState {
  private dbase: PasswordDatabase;
  constructor(dbase: PasswordDatabase) {
    this.dbase = dbase;
  }
  nextId(): number {
    return nextItemId(this.dbase);
  }
  push(card: Card) {
    this.dbase.cards.push(card);
  }
  ensureLabel(name: string, now: number): number {
    const existing = this.dbase.labels.find((l) => l.name === name);
    if (existing) return existing.id;
    const id = nextItemId(this.dbase);
    this.dbase.labels.push({ id, name, color: null, type: null, pinToTop: false, timeStamp: now });
    return id;
  }
}

export interface ImportFormat {
  id: string;
  title: string;
  parse(text: string, dbase: PasswordDatabase, now: number): number;
}

function csvFormat(id: string, title: string, map: ColumnMap): ImportFormat {
  return {
    id,
    title,
    parse: (text, dbase, now) => importCsv(new ImportState(dbase), text, map, now),
  };
}

export const IMPORT_FORMATS: ImportFormat[] = [
  {
    id: "safeincloud-xml",
    title: "XML (SafeInCloud)",
    parse(text, dbase, now) {
      // Full <database> docs or bare <card> lists are handled by the Rust XML
      // parser; the frontend wraps it through backend.parseXml.
      // Fallback path used when the backend is reachable.
      throw new Error("use parseXmlImport");
    },
  },
  csvFormat("chrome-chrome", "Chrome", { name: ["name"], login: ["username", "login", "login_username"], password: ["password"], url: ["url", "website", "origin_url"], notes: ["note", "notes"] }),
  csvFormat("chrome-brave", "Brave", { name: ["name"], login: ["username", "login", "login_username"], password: ["password"], url: ["url", "website", "origin_url"], notes: ["note", "notes"] }),
  csvFormat("chrome-edge", "Edge", { name: ["name"], login: ["username", "login", "login_username"], password: ["password"], url: ["url", "website", "origin_url"], notes: ["note", "notes"] }),
  csvFormat("chrome-opera", "Opera", { name: ["name"], login: ["username", "login", "login_username"], password: ["password"], url: ["url", "website", "origin_url"], notes: ["note", "notes"] }),
  csvFormat("chrome-firefox", "Firefox", { name: ["name"], login: ["username", "login", "login_username"], password: ["password"], url: ["url", "website", "origin_url"], notes: ["note", "notes"] }),
  csvFormat("lastpass", "LastPass", { name: ["name"], login: ["username"], password: ["password"], url: ["url"], notes: ["extra", "notes"] }),
  {
    id: "bitwarden-csv",
    title: "Bitwarden (CSV)",
    parse(text, dbase, now) {
      return importCsv(
        new ImportState(dbase),
        text,
        { name: ["name"], login: ["login_username", "username"], password: ["login_password", "password"], url: ["login_uri", "uri"], notes: ["notes"] },
        now,
        ["folder"],
        (folder, st) => st.ensureLabel(folder, now),
      );
    },
  },
  {
    id: "bitwarden-json",
    title: "Bitwarden (JSON)",
    parse(text, dbase, now) {
      const obj = JSON.parse(text) as Record<string, unknown>;
      const items = ((obj.items ?? (obj.vault as Record<string, unknown>)?.items) as Record<string, unknown>[]) ?? [];
      const folders = (obj.folders as Record<string, unknown>[]) ?? [];
      const folderNames = new Map<string, string>();
      for (const f of folders) {
        if (typeof f.id === "string" && typeof f.name === "string") folderNames.set(f.id, f.name);
      }
      const state = new ImportState(dbase);
      let count = 0;
      for (const item of items) {
        const title = item.name;
        if (typeof title !== "string") continue;
        const login = item.login as Record<string, unknown> | undefined;
        const card = newCard(state.nextId(), now);
        card.title = title || "—";
        card.symbol = "key";
        card.color = "gray";
        const u = login?.username;
        if (typeof u === "string" && u) card.fields.push({ ...newField(db("login_field")), type: "login", value: u, autofill: "username" });
        const p = login?.password;
        if (typeof p === "string" && p) card.fields.push({ ...newField(db("password_field")), type: "password", value: p, autofill: "current-password" });
        const uris = login?.uris as Record<string, unknown>[] | undefined;
        const firstUri = uris?.[0]?.uri;
        if (typeof firstUri === "string" && firstUri) card.fields.push({ ...newField(db("url_field")), type: "website", value: firstUri, autofill: "url" });
        const totp = login?.totp;
        if (typeof totp === "string" && totp) card.fields.push({ ...newField(db("one_time_password_field")), type: "one_time_password", value: totp, autofill: "one-time-code" });
        const n = item.notes;
        if (typeof n === "string" && n) card.notes = n;
        const fid = item.folderId;
        if (typeof fid === "string") {
          const fname = folderNames.get(fid);
          if (fname) card.labelIds.push(state.ensureLabel(fname, now));
        }
        state.push(card);
        count += 1;
      }
      return count;
    },
  },
  csvFormat("dashlane-csv", "Dashlane (CSV)", { name: ["title", "name"], login: ["login", "username", "email"], password: ["password"], url: ["url", "website"], notes: ["note", "notes"] }),
  csvFormat("1password-csv", "1Password (CSV)", { name: ["title", "name"], login: ["username"], password: ["password"], url: ["url"], notes: ["notes"] }),
  csvFormat("apple-passwords", "Safari / Apple Passwords", { name: ["title"], login: ["username"], password: ["password"], url: ["url"], notes: ["notes"] }),
  csvFormat("nordpass", "NordPass", { name: ["name"], login: ["username"], password: ["password"], url: ["url"], notes: ["note", "notes"] }),
  csvFormat("protonpass", "Proton Pass", { name: ["name", "title"], login: ["username", "email"], password: ["password"], url: ["url"], notes: ["note", "notes"] }),
  csvFormat("keepass", "KeePass / KeePassXC", { name: ["title", "account", "name"], login: ["login", "username"], password: ["password"], url: ["url"], notes: ["notes"] }),
  csvFormat("keeper", "Keeper", { name: ["title", "record_type"], login: ["login"], password: ["password"], url: ["url"], notes: ["notes"] }),
  csvFormat("roboform", "RoboForm", { name: ["name"], login: ["login"], password: ["pwd", "password"], url: ["url"], notes: ["note", "notes"] }),
  csvFormat("csv", "CSV", { name: ["name", "title", "account"], login: ["login", "username", "user", "email"], password: ["password", "pass", "pwd"], url: ["url", "website", "site", "uri"], notes: ["note", "notes", "comment"] }),
];

export function importFormatById(id: string): ImportFormat | undefined {
  return IMPORT_FORMATS.find((f) => f.id === id);
}

/** SafeInCloud XML import — merges parsed cards, skipping duplicate titles. */
export function importParsedXml(
  parsed: PasswordDatabase,
  dbase: PasswordDatabase,
): number {
  const existingIds = new Set(dbase.cards.map((c) => c.id));
  const existingTitles = new Set(dbase.cards.filter((c) => !c.template).map((c) => c.title));
  let count = 0;
  for (const c of parsed.cards) {
    if (c.template || existingTitles.has(c.title)) continue;
    const card = { ...c };
    if (existingIds.has(card.id)) card.id = nextItemId(dbase);
    dbase.cards.push(card);
    count += 1;
  }
  return count;
}

// ----- Export (ExportCardsTask / ExportAsSheetController) -----

export const EXPORT_FORMATS = ["xml", "csv", "txt"] as const;
export type ExportFormat = (typeof EXPORT_FORMATS)[number];

export function exportCards(
  cards: Card[],
  labels: CardLabel[],
  format: ExportFormat,
  xmlSerializer: (db: PasswordDatabase) => string,
): string {
  switch (format) {
    case "xml":
      return xmlSerializer({ labels, cards, ghosts: [] });
    case "csv": {
      const rows: string[][] = [["title", "login", "password", "website", "notes"]];
      for (const c of cards) {
        const login = c.fields.find((f) => f.type === "login" || f.type === "email")?.value ?? "";
        const password = c.fields.find((f) => f.type === "password")?.value ?? "";
        const website = c.fields.find((f) => f.type === "website")?.value ?? "";
        rows.push([c.title, login, password, website, c.notes]);
      }
      return rows.map((r) => r.map(csvEscape).join(",")).join("\n");
    }
    case "txt":
      return cards
        .map((c) => {
          const lines = [c.title];
          for (const f of c.fields) lines.push(`${f.name}: ${f.value}`);
          if (c.notes) lines.push(c.notes);
          return lines.join("\n");
        })
        .join("\n\n" + "—".repeat(30) + "\n\n");
  }
}
