// Central session controller — the Pinia port of App/AppContext.swift
// (DatabaseManager + per-sidebar CardListStrategy + LockedState + auto-lock).
import { defineStore } from "pinia";
import { computed, ref } from "vue";
import * as backend from "../lib/backend";
import type { Card, Field, PasswordDatabase } from "../lib/models";
import {
  activeCards, cardById, deleteCardPermanently as dbDeleteCard,
  emptyDatabase, labelById, nextItemId, putHistoryValue,
} from "../lib/models";
import { t } from "../lib/i18n";
import { OFFLINE_DEMO_SET } from "../lib/demoSet";
import { scorePassword } from "../lib/strength";
import {
  type SidebarSelection, type SpecialLabel, selectionEquals, sortCards,
  specialLabelEmptyState,
} from "../lib/sidebar";
import { useSettingsStore, markSetupTaskDone, pushRecentId, recentIds } from "./settings";
import { useToastStore } from "./toast";

export type Phase = "setup" | "locked" | "unlocked";

/** One case per original *SheetController; payload carries targets. */
export type AppSheet =
  | { kind: "addCard" }
  | { kind: "addNote" }
  | { kind: "addLabel" }
  | { kind: "editCardLabel"; id: number }
  | { kind: "selectColorCardLabel"; id: number }
  | { kind: "sorting" }
  | { kind: "generator" }
  | { kind: "labels"; cardId: number }
  | { kind: "selectSymbol" }
  | { kind: "selectColor" }
  | { kind: "selectTexture" }
  | { kind: "selectTemplate" }
  | { kind: "history" }
  | { kind: "passwordHistory" }
  | { kind: "exportAs" }
  | { kind: "importData" }
  | { kind: "databaseInfo" }
  | { kind: "compromised" }
  | { kind: "changePassword" }
  | { kind: "configureCloud" }
  | { kind: "eraseData" }
  | { kind: "manageDatabases" }
  | { kind: "selectDatabase" }
  | { kind: "preferences" }
  | { kind: "about" }
  | { kind: "whatsNew" }
  | { kind: "premium" }
  | { kind: "setupPlan" }
  | { kind: "enterPassword" }
  | { kind: "expiredCards" }
  | { kind: "restoreTemplates" };

export interface EditCardModel {
  card: Card;
  isNew: boolean;
}

export type SyncState = "disabled" | "idle" | "syncing" | "error";

export const useAppStore = defineStore("app", () => {
  const settings = useSettingsStore();
  const toast = useToastStore();

  const phase = ref<Phase>("setup");
  const database = ref<PasswordDatabase>(emptyDatabase());
  const databaseName = ref("");
  const selection = ref<SidebarSelection>({ kind: "special", sp: "all_cards_label" });
  const selectedCardId = ref<number | null>(null);
  const searchText = ref("");
  const editDraft = ref<EditCardModel | null>(null);
  const activeSheet = ref<AppSheet | null>(null);
  const syncState = ref<SyncState>("disabled");
  const lastSync = ref<Date | null>(null);
  const lastSyncFailed = ref<Date | null>(null);
  const failedUnlockAttempts = ref(0);
  const lastActivity = ref(Date.now());
  const dbsList = ref<backend.DatabaseFile[]>([]);
  const floating = ref(false);

  /** In-memory password, present only while unlocked. */
  let password = "";

  // ----- Bootstrap (SetupWindowController → DatabaseManager) -----

  async function bootstrap() {
    // dev-only demo session (?demo) — unlocks a synthetic database so the
    // main window can be previewed in a plain browser without the backend
    if (import.meta.env.DEV && location.search.includes("demo")) {
      const { createDefaultDatabase, makeCardFromSpec, TEMPLATES } = await import("../lib/templates");
      database.value = createDefaultDatabase();
      const spec = TEMPLATES.find((s) => s.titleKey === "web_account_template")!;
      const demo = makeCardFromSpec(spec, nextItemId(database.value), 0);
      demo.title = "示例网站";
      demo.fields.find((f) => f.type === "login")!.value = "alice@example.com";
      demo.fields.find((f) => f.type === "password")!.value = "s3cret-Passw0rd!";
      database.value.cards.push(demo);
      databaseName.value = "Demo";
      password = "demo";
      phase.value = "unlocked";
      selectedCardId.value = demo.id;
      return;
    }
    try {
      dbsList.value = await backend.listDatabases();
    } catch {
      // backend unreachable (plain-browser dev) — treat as first run
      dbsList.value = [];
    }
    if (dbsList.value.length === 0) {
      phase.value = "setup";
    } else {
      phase.value = "locked";
      const main = settings.s.mainDatabaseName;
      databaseName.value = dbsList.value.some((d) => d.name === main)
        ? main
        : dbsList.value[0].name;
    }
  }

  async function refreshDbs() {
    dbsList.value = await backend.listDatabases();
    return dbsList.value;
  }

  // ----- Setup / lifecycle -----

  async function createDatabase(name: string, pw: string, fastUnlock: boolean) {
    if (!/^[A-Za-z0-9]+$/.test(name)) throw new Error(t("database_name_error"));
    if (dbsList.value.some((d) => d.name === name)) throw new Error(t("database_already_exists_error"));
    await backend.createDefaultDatabase(name, pw);
    settings.s.mainDatabaseName = name;
    await backend.keychainSavePassword(name, pw);
    if (fastUnlock) {
      try {
        await backend.keychainSaveBiometric(name, pw);
      } catch {
        /* keychain unavailable — fast unlock simply stays off */
      }
    }
    await refreshDbs();
    await unlock(name, pw);
    activeSheet.value = { kind: "setupPlan" };
  }

  async function unlock(name: string, pw: string) {
    database.value = await backend.loadDatabase(name, pw);
    databaseName.value = name;
    password = pw;
    phase.value = "unlocked";
    lastActivity.value = Date.now(); // otherwise the idle timer re-locks right after unlocking
    failedUnlockAttempts.value = 0;
    selection.value = { kind: "special", sp: "all_cards_label" };
    selectedCardId.value = activeCards(database.value)[0]?.id ?? null;
    scheduleAutoBackupIfNeeded();
    if (settings.s.cloudType !== "none") markSetupTaskDone("cloud_sync_task");
    if (settings.s.autoBackupEnabled) markSetupTaskDone("auto_backup_task");
    if (settings.s.fastUnlock) markSetupTaskDone("touch_id_task");
    announceStartupSheets();
  }

  /** WhatsNewSheetController + expiring_cards_warning prompt. */
  function announceStartupSheets() {
    const version = "1.0";
    if (settings.s.showWhatsNewAtStartup && settings.s.lastWhatsNewVersion !== version) {
      settings.s.lastWhatsNewVersion = version;
      activeSheet.value = { kind: "whatsNew" };
      return;
    }
    if (cardsFor({ kind: "special", sp: "expiring_label" }, "").length > 0) {
      activeSheet.value = { kind: "expiredCards" };
    }
  }

  function lock() {
    if (phase.value !== "unlocked") return;
    password = "";
    phase.value = "locked";
    activeSheet.value = null;
    editDraft.value = null;
    saveNow(); // flush pending debounced writes under the old password
  }

  async function unlockWithFastUnlock() {
    if (phase.value !== "locked" || !settings.s.fastUnlock) return;
    try {
      const pw = await backend.keychainLoadBiometric(databaseName.value);
      if (pw) await unlock(databaseName.value, pw);
    } catch {
      /* cancelled / unavailable */
    }
  }

  function registerFailedAttempt() {
    failedUnlockAttempts.value += 1;
    const limit = settings.s.selfDestructAttempts;
    if (limit > 0 && failedUnlockAttempts.value >= limit) {
      void eraseAllData();
    }
  }

  /** erase_data_command — removes local data (cloud copies untouched). */
  async function eraseAllData() {
    for (const db of await refreshDbs()) {
      try {
        await backend.deleteDatabase(db.name);
      } catch {
        /* best effort */
      }
    }
    database.value = emptyDatabase();
    databaseName.value = "";
    password = "";
    phase.value = "setup";
  }

  // ----- Persistence -----

  async function saveNow() {
    if (phase.value !== "unlocked" || !password) return;
    try {
      await backend.saveDatabase(database.value, databaseName.value, password);
    } catch (e) {
      toast.show(settings.errorText(String(e)));
    }
  }

  let saveTimer: ReturnType<typeof setTimeout> | undefined;
  function saveDebounced() {
    clearTimeout(saveTimer);
    saveTimer = setTimeout(() => void saveNow(), 600);
  }

  function touch() {
    lastActivity.value = Date.now();
  }

  // ----- Card list strategies (CardListStrategy) -----

  function samePasswordGroups(cards: Card[]): Map<string, number[]> {
    const out = new Map<string, number[]>();
    for (const c of cards) {
      if (c.trashed || c.template) continue;
      for (const f of c.fields) {
        if (f.type === "password" && f.value) {
          const list = out.get(f.value) ?? [];
          list.push(c.id);
          out.set(f.value, list);
        }
      }
    }
    return new Map([...out].filter(([, ids]) => ids.length > 1));
  }

  function hasWeakPasswords(card: Card): boolean {
    return card.fields.some((f) => f.type === "password" && f.value && scorePassword(f.value).score <= 1);
  }

  function isCompromisedOffline(card: Card): boolean {
    return card.fields.some((f) => f.type === "password" && OFFLINE_DEMO_SET.has(f.value));
  }

  function strategyCards(sp: SpecialLabel): Card[] {
    const active = activeCards(database.value);
    switch (sp) {
      case "all_cards_label": return active.filter((c) => !c.archived);
      case "favorites_label": return active.filter((c) => c.favorite && !c.archived);
      case "recent_label": {
        const ids = recentIds();
        return ids.map((id) => active.find((c) => c.id === id)).filter((c): c is Card => !!c);
      }
      case "passwords_label": return active.filter((c) => !c.archived && c.fields.some((f) => f.type === "password"));
      case "totp_label": return active.filter((c) => !c.archived && c.fields.some((f) => f.type === "one_time_password"));
      case "notes_label":
        return active.filter(
          (c) =>
            !c.archived &&
            c.notes.length > 0 &&
            c.fields.every((f) => !(f.type === "login" || f.type === "email") && f.type !== "password"),
        );
      case "files_label": return active.filter((c) => !c.archived && c.files.length > 0);
      case "images_label": return active.filter((c) => !c.archived && c.images.length > 0);
      case "passkeys_label": return []; // passkeys are created in the mobile version
      case "credit_cards_label": return active.filter((c) => !c.archived && c.symbol === "credit_card");
      case "weak_passwords_label": return active.filter((c) => !c.archived && hasWeakPasswords(c));
      case "same_passwords_label": {
        const groups = samePasswordGroups(active);
        const ids = new Set([...groups.values()].flat());
        return active.filter((c) => ids.has(c.id));
      }
      case "compromised_passwords_label": return active.filter((c) => !c.archived && isCompromisedOffline(c));
      case "expiring_label": {
        return active.filter((c) => !c.archived && !c.trashed && c.expiration != null &&
          (() => { const d = Math.floor((c.expiration! - Date.now()) / 86400000); return d >= 0 && d <= 30; })());
      }
      case "expired_label": {
        return active.filter((c) => !c.archived && !c.trashed && c.expiration != null &&
          c.expiration < Date.now());
      }
      case "archived_label": return active.filter((c) => c.archived);
      case "trash_label": return database.value.cards.filter((c) => c.trashed);
      case "templates_label":
        return [...database.value.cards.filter((c) => c.template)]
          .sort((a, b) => a.title.localeCompare(b.title, undefined, { sensitivity: "base" }));
    }
  }

  /** XCard.satisfiesToSearchWords — every word must hit title/field/notes/label. */
  function containsWord(card: Card, word: string): boolean {
    if (card.title.toLowerCase().includes(word)) return true;
    if (card.notes.toLowerCase().includes(word)) return true;
    for (const f of card.fields) {
      if (f.name.toLowerCase().includes(word)) return true;
      if (f.type !== "one_time_password") {
        if (!["password", "pin", "one_time_password", "secret"].includes(f.type) || settings.s.searchPasswords) {
          if (f.value.toLowerCase().includes(word)) return true;
        } else if (f.value.toLowerCase().includes(word)) {
          return true; // hidden fields match on value but are not shown in preview
        }
      }
    }
    if (settings.s.searchByLabels) {
      for (const lid of card.labelIds) {
        const l = labelById(database.value, lid);
        if (l && l.name.toLowerCase().includes(word)) return true;
      }
    }
    return false;
  }

  function cardsFor(sel: SidebarSelection, search: string): Card[] {
    const words = search.toLowerCase().split(" ").filter(Boolean);
    let cards: Card[];
    if (sel.kind === "special") {
      cards = strategyCards(sel.sp);
    } else {
      cards = activeCards(database.value).filter((c) => c.labelIds.includes(sel.id) && !c.archived);
    }
    if (words.length) {
      cards = cards.filter((c) => words.every((w) => containsWord(c, w)));
    }
    return sortCards(cards, settings.s.sorting, settings.s.favoritesAtTop);
  }

  /** XCard.previewForSearchWords — "title — matched snippet" row preview. */
  function searchPreview(card: Card, word: string): string | null {
    const w = word.toLowerCase();
    for (const f of card.fields) {
      if (f.type === "one_time_password") continue;
      const hidden = ["password", "pin", "one_time_password", "secret"].includes(f.type);
      if (!hidden || settings.s.searchPasswords) {
        if (f.value.toLowerCase().includes(w)) {
          return `${f.name}: …${snippet(f.value, w)}…`;
        }
      }
    }
    if (card.notes.toLowerCase().includes(w)) {
      return `…${snippet(card.notes, w)}…`;
    }
    return null;
  }

  function snippet(text: string, w: string): string {
    const idx = text.toLowerCase().indexOf(w);
    if (idx < 0) return text.slice(0, 30);
    const start = Math.max(0, idx - 10);
    return text.slice(start, idx + w.length + 20);
  }

  function countFor(sel: SidebarSelection): number {
    return cardsFor(sel, "").length;
  }

  const currentCards = computed(() => cardsFor(selection.value, searchText.value));

  function emptyStateText(sel: SidebarSelection): string {
    return sel.kind === "special" ? specialLabelEmptyState(sel.sp) : t("user_empty_state");
  }

  // ----- Card CRUD -----

  function newCardIdValue(): number {
    return nextItemId(database.value);
  }

  function upsertCard(card: Card) {
    const c: Card = { ...card };
    c.modified = Date.now();
    const i = database.value.cards.findIndex((x) => x.id === c.id);
    if (i >= 0) {
      const old = database.value.cards[i];
      // keep old values in field history
      c.fields = c.fields.map((f) => {
        const prev = old.fields.find((o) => o.name === f.name && o.type === f.type);
        if (prev) {
          const copy = { ...f, history: [...f.history] };
          putHistoryValue(copy, prev.value, c.modified);
          return copy;
        }
        return f;
      });
      database.value.cards[i] = c;
    } else {
      database.value.cards.push(c);
    }
    selectedCardId.value = c.id;
    pushRecentId(c.id);
    saveDebounced();
  }

  function trashCard(id: number) {
    const c = cardById(database.value, id);
    if (!c) return;
    c.trashed = true;
    c.modified = Date.now();
    if (selectedCardId.value === id) selectedCardId.value = null;
    saveDebounced();
  }

  function deleteCardPermanentlyById(id: number) {
    dbDeleteCard(database.value, id);
    if (selectedCardId.value === id) selectedCardId.value = null;
    saveDebounced();
  }

  function restoreCard(id: number) {
    const c = cardById(database.value, id);
    if (!c) return;
    c.trashed = false;
    c.archived = false;
    c.modified = Date.now();
    saveDebounced();
  }

  function archiveCard(id: number) {
    const c = cardById(database.value, id);
    if (!c) return;
    c.archived = true;
    c.modified = Date.now();
    saveDebounced();
  }

  function unarchiveCard(id: number) {
    const c = cardById(database.value, id);
    if (!c) return;
    c.archived = false;
    c.modified = Date.now();
    saveDebounced();
  }

  function toggleFavorite(id: number) {
    const c = cardById(database.value, id);
    if (!c) return;
    c.favorite = !c.favorite;
    saveDebounced();
  }

  function setCardAutofill(id: number, on: boolean) {
    const c = cardById(database.value, id);
    if (!c) return;
    c.autofillEnabled = on;
    saveDebounced();
  }

  function duplicateCard(id: number) {
    const card = cardById(database.value, id);
    if (!card) return;
    const copy: Card = JSON.parse(JSON.stringify(card));
    copy.id = newCardIdValue();
    copy.created = Date.now();
    copy.modified = copy.created;
    copy.favorite = false;
    database.value.cards.push(copy);
    selectedCardId.value = copy.id;
    saveDebounced();
  }

  function emptyTrash() {
    for (const c of database.value.cards.filter((c) => c.trashed)) {
      dbDeleteCard(database.value, c.id);
    }
    saveDebounced();
  }

  function saveAsTemplate(card: Card) {
    const copy: Card = JSON.parse(JSON.stringify(card));
    copy.template = true;
    copy.id = newCardIdValue();
    database.value.cards.push(copy);
    saveDebounced();
  }

  // ----- Label CRUD -----

  function addLabel(name: string, color: string | null) {
    const id = nextItemId(database.value);
    database.value.labels.push({ id, name, color, type: null, pinToTop: false, timeStamp: Date.now() });
    saveDebounced();
  }

  function renameCardLabel(id: number, name: string) {
    const l = labelById(database.value, id);
    if (!l) return;
    l.name = name;
    l.timeStamp = Date.now();
    saveDebounced();
  }

  function setLabelColor(id: number, color: string | null) {
    const l = labelById(database.value, id);
    if (!l) return;
    l.color = color;
    saveDebounced();
  }

  function toggleLabelPinned(id: number) {
    const l = labelById(database.value, id);
    if (!l) return;
    l.pinToTop = !l.pinToTop;
    saveDebounced();
  }

  function deleteCardLabel(id: number) {
    database.value.labels = database.value.labels.filter((l) => l.id !== id);
    for (const c of database.value.cards) {
      c.labelIds = c.labelIds.filter((x) => x !== id);
    }
    if (selection.value.kind === "label" && selection.value.id === id) {
      selection.value = { kind: "special", sp: "all_cards_label" };
    }
    saveDebounced();
  }

  function setLabels(cardId: number, labelIds: number[]) {
    const c = cardById(database.value, cardId);
    if (!c) return;
    c.labelIds = [...labelIds].sort((a, b) => a - b);
    c.modified = Date.now();
    saveDebounced();
  }

  function addLabelAndAssign(name: string, color: string | null, cardId: number) {
    const id = nextItemId(database.value);
    database.value.labels.push({ id, name, color, type: null, pinToTop: false, timeStamp: Date.now() });
    const c = cardById(database.value, cardId);
    if (!c) return;
    c.labelIds.push(id);
    c.modified = Date.now();
    saveDebounced();
  }

  // ----- Change password -----

  async function changePassword(current: string, next: string) {
    if (current !== password) throw new Error(t("wrong_password_error"));
    await backend.saveDatabase(database.value, databaseName.value, next);
    await backend.keychainSavePassword(databaseName.value, next);
    try {
      if (settings.s.fastUnlock && (await backend.keychainHasBiometric(databaseName.value))) {
        await backend.keychainSaveBiometric(databaseName.value, next);
      }
    } catch { /* keychain unavailable */ }
    password = next;
  }

  // ----- Info / history -----

  const allHistoryEntries = computed(() => {
    const out: { card: Card; field: Field; time: number; value: string }[] = [];
    for (const c of database.value.cards) {
      if (c.template) continue;
      for (const f of c.fields) {
        for (const e of f.history) out.push({ card: c, field: f, time: e.time, value: e.value });
      }
    }
    return out.sort((a, b) => b.time - a.time);
  });

  // ----- Backup / sync -----

  async function backupNow() {
    await saveNow();
    try {
      await backend.backupDatabase(databaseName.value);
      toast.show(`${t("database_saved_message")} ${t("backup_command")}`);
    } catch (e) {
      toast.show(settings.errorText(String(e)));
    }
  }

  function scheduleAutoBackupIfNeeded() {
    if (!settings.s.autoBackupEnabled || settings.s.backupIntervalDays <= 0) return;
    const last = settings.s.backupLast[databaseName.value] ?? 0;
    const interval = settings.s.backupIntervalDays * 86400 * 1000;
    if (Date.now() - last >= interval) {
      void backend.backupDatabase(databaseName.value).catch(() => undefined);
      settings.s.backupLast[databaseName.value] = Date.now();
    }
  }

  async function sync() {
    if (settings.s.cloudType !== "webdav") {
      if (settings.s.cloudType === "none") {
        syncState.value = "disabled";
        toast.show(t("sync_disabled_state"));
      } else {
        toast.show(t("not_configured_state"));
      }
      return;
    }
    syncState.value = "syncing";
    await saveNow();
    try {
      const out = await backend.webdavSync(settings.s.webdav, databaseName.value, password, database.value);
      database.value = out.merged;
      await saveNow();
      lastSync.value = new Date();
      syncState.value = "idle";
      const df = new Intl.DateTimeFormat(undefined, { dateStyle: "short", timeStyle: "short" });
      toast.show(`${t("last_sync_completed_prompt")} ${df.format(lastSync.value)}`);
    } catch (e) {
      lastSyncFailed.value = new Date();
      syncState.value = "error";
      toast.show(`${t("sync_error")}: ${settings.errorText(String(e))}`);
    }
  }

  // ----- Clipboard (ClipboardModel) -----

  async function copy(text: string, message?: string) {
    try {
      await backend.copyText(text, settings.s.clipboardClearSeconds);
      toast.show(message ?? t("text_copied_message"));
    } catch {
      toast.show(t("text_copied_message"));
    }
  }

  function copyOTP(code: string) {
    void copy(code, t("otp_copied_message"));
  }

  const selectedCard = computed(() =>
    selectedCardId.value !== null ? cardById(database.value, selectedCardId.value) : undefined,
  );

  // ----- Auto-lock (LockedState + auto_lock_setting) -----

  let activityHooks = false;
  function installActivityMonitor() {
    if (activityHooks) return;
    activityHooks = true;
    window.setInterval(() => {
      if (phase.value === "unlocked" && settings.s.autoLockSeconds > 0) {
        if (Date.now() - lastActivity.value >= settings.s.autoLockSeconds * 1000) {
          lock();
        }
      }
    }, 5000);
    for (const evt of ["keydown", "mousedown", "wheel", "touchstart", "mousemove"]) {
      window.addEventListener(evt, throttledTouch, { passive: true });
    }
    // lock when the window loses focus (lock_in_background_setting)
    window.addEventListener("blur", () => {
      if (settings.s.lockInBackground) lock();
    });
  }

  let lastTouchTick = 0;
  function throttledTouch() {
    const now = Date.now();
    if (now - lastTouchTick > 2000) {
      lastTouchTick = now;
      touch();
    }
  }

  function openSheet(sheet: AppSheet) {
    activeSheet.value = sheet;
  }

  return {
    phase, database, databaseName, selection, selectedCardId, searchText,
    editDraft, activeSheet, syncState, lastSync, lastSyncFailed,
    failedUnlockAttempts, dbsList, floating, selectedCard, currentCards,
    bootstrap, refreshDbs, createDatabase, unlock, lock, unlockWithFastUnlock,
    registerFailedAttempt, eraseAllData, saveNow, saveDebounced, touch,
    cardsFor, countFor, searchPreview, emptyStateText, hasWeakPasswords,
    isCompromisedOffline, samePasswordGroups,
    newCardIdValue, upsertCard, trashCard, deleteCardPermanentlyById, restoreCard,
    archiveCard, unarchiveCard, toggleFavorite, setCardAutofill, duplicateCard,
    emptyTrash, saveAsTemplate,
    addLabel, renameCardLabel, setLabelColor, toggleLabelPinned, deleteCardLabel,
    setLabels, addLabelAndAssign, changePassword, allHistoryEntries,
    backupNow, sync, copy, copyOTP, installActivityMonitor, openSheet,
  };
});

// selectionEquals re-exported for components
export { selectionEquals };
