// Typed bridge to the Rust backend (src-tauri/src/commands.rs). Every invoke
// maps one DatabaseStore / PasswordStore / WebDavDriver / CompromisedService
// entry point of the Swift version.
import { invoke } from "@tauri-apps/api/core";
import type { PasswordDatabase } from "./models";
import { resolveStringRefs } from "./models";

export interface DatabaseFile {
  name: string;
  fileName: string;
  created: number; // millis
}

export interface WebDavSettings {
  host: string;
  port: number;
  useHTTPS: boolean;
  user: string;
  password: string;
  path: string;
}

export interface CompromisedResult {
  compromised: string[];
  offline: boolean;
}

export interface SyncOutcome {
  merged: PasswordDatabase;
  changed: boolean; // whether the remote copy produced local merges
}

export interface BackupEntry {
  fileName: string;
  created: number;
}

// ----- DatabaseStore -----

export async function listDatabases(): Promise<DatabaseFile[]> {
  const files = await invoke<DatabaseFile[]>("list_databases");
  return files;
}

export async function databaseExists(name: string): Promise<boolean> {
  return invoke("database_exists", { name });
}

export async function loadDatabase(name: string, password: string): Promise<PasswordDatabase> {
  const dbase = await invoke<PasswordDatabase>("load_database", { name, password });
  resolveStringRefs(dbase);
  return dbase;
}

export async function saveDatabase(dbase: PasswordDatabase, name: string, password: string): Promise<void> {
  await invoke("save_database", { dbJson: dbase, name, password });
}

export async function renameDatabase(oldName: string, newName: string): Promise<void> {
  await invoke("rename_database", { oldName, newName });
}

export async function deleteDatabase(name: string): Promise<void> {
  await invoke("delete_database", { name });
}

export async function backupDatabase(name: string): Promise<void> {
  await invoke("backup_database", { name });
}

export async function listBackups(name: string): Promise<BackupEntry[]> {
  return invoke("list_backups", { name });
}

export async function restoreBackup(name: string, fileName: string): Promise<void> {
  await invoke("restore_backup", { name, fileName });
}

/** Loads a fresh default database (15 templates + default labels), localized. */
export async function createDefaultDatabase(name: string, password: string): Promise<PasswordDatabase> {
  const dbase = await invoke<PasswordDatabase>("create_default_database");
  resolveStringRefs(dbase);
  await saveDatabase(dbase, name, password);
  return dbase;
}

// ----- XML (SafeInCloud exchange format) -----

export async function parseXml(text: string): Promise<PasswordDatabase> {
  const dbase = await invoke<PasswordDatabase>("parse_xml", { text });
  resolveStringRefs(dbase);
  return dbase;
}

export async function serializeXml(dbase: PasswordDatabase): Promise<string> {
  return invoke("serialize_xml", { dbJson: dbase });
}

// ----- PasswordStore (OS keychain) -----

export async function keychainSavePassword(name: string, password: string): Promise<void> {
  await invoke("keychain_save_password", { name, password });
}

export async function keychainSaveBiometric(name: string, password: string): Promise<void> {
  await invoke("keychain_save_biometric", { name, password });
}

export async function keychainLoadPassword(name: string): Promise<string | null> {
  return invoke("keychain_load_password", { name });
}

export async function keychainLoadBiometric(name: string): Promise<string | null> {
  return invoke("keychain_load_biometric", { name });
}

export async function keychainHasBiometric(name: string): Promise<boolean> {
  return invoke("keychain_has_biometric", { name });
}

export async function keychainRemoveBiometric(name: string): Promise<void> {
  await invoke("keychain_remove_biometric", { name });
}

export async function keychainErase(name: string): Promise<void> {
  await invoke("keychain_erase", { name });
}

/** Whether fast (biometric) unlock can work: entry present in the keychain. */
export async function fastUnlockAvailable(name: string): Promise<boolean> {
  return invoke("fast_unlock_available", { name });
}

// ----- WebDAV sync -----

export async function webdavTest(settings: WebDavSettings, databaseName: string): Promise<void> {
  await invoke("webdav_test", { settings, databaseName });
}

export async function webdavSync(
  settings: WebDavSettings,
  databaseName: string,
  password: string,
  local: PasswordDatabase,
): Promise<SyncOutcome> {
  const out = await invoke<SyncOutcome>("webdav_sync", {
    settings,
    databaseName,
    password,
    localJson: local,
  });
  resolveStringRefs(out.merged);
  return out;
}

// ----- Compromised passwords (HIBP k-anonymity) -----

export async function checkCompromised(passwords: string[], demo: boolean): Promise<CompromisedResult> {
  return invoke("check_compromised", { passwords, demo });
}

// ----- Clipboard -----

export async function copyText(text: string, clearSeconds: number): Promise<void> {
  await invoke("copy_text", { text, clearSeconds });
}

// ----- Attachments / files -----

export interface PickedFile {
  name: string;
  /** base64 contents */
  data: string;
  length: number;
}

export async function pickFiles(filterKind: "image" | "file" | "text" | "xml"): Promise<PickedFile[]> {
  return invoke("pick_files", { filterKind });
}

export async function saveTextFile(defaultName: string, text: string): Promise<string | null> {
  return invoke("save_text_file", { defaultName, text });
}

export async function saveBinaryFile(defaultName: string, base64: string): Promise<string | null> {
  return invoke("save_binary_file", { defaultName, base64 });
}

// ----- Misc -----

export async function openExternal(url: string): Promise<void> {
  const { openUrl } = await import("@tauri-apps/plugin-opener");
  await openUrl(url);
}

export async function databaseFileSize(name: string): Promise<number> {
  return invoke("database_file_size", { name });
}
