// Settings — mirrors App/AppSettings.swift + PasswordSettings.swift, persisted
// in localStorage (the UserDefaults equivalent for the webview).
import { defineStore } from "pinia";
import { reactive, watch } from "vue";
import type { PasswordSettings } from "../lib/generator";
import { defaultPasswordSettings } from "../lib/generator";
import type { Sorting } from "../lib/sidebar";
import type { WebDavSettings } from "../lib/backend";
import { t } from "../lib/i18n";

const KEY = "upasswords.settings";

interface PersistedSettings {
  languageOverride: string;
  sorting: Sorting;
  favoritesAtTop: boolean;
  showCardCount: boolean;
  hidePasswords: boolean;
  searchByLabels: boolean;
  searchPasswords: boolean;
  useWebsiteIcons: boolean;
  autoLockSeconds: number;
  lockInBackground: boolean;
  lockIfWindowClosed: boolean;
  requirePasswordSeconds: number;
  fastUnlock: boolean;
  selfDestructAttempts: number;
  clipboardClearSeconds: number;
  lockTexture: number;
  lockWhiteText: boolean;
  autoBackupEnabled: boolean;
  backupIntervalDays: number;
  cloudType: "none" | "webdav" | "gdrive" | "dropbox" | "onedrive" | "icloud";
  webdav: WebDavSettings;
  sidebarOptionalItems: string[];
  showWhatsNewAtStartup: boolean;
  mainDatabaseName: string;
  lastWhatsNewVersion: string;
  backupLast: Record<string, number>;
  pwd: PasswordSettings;
}

function defaults(): PersistedSettings {
  return {
    languageOverride: "",
    sorting: "title_asc",
    favoritesAtTop: true,
    showCardCount: true,
    hidePasswords: true,
    searchByLabels: true,
    searchPasswords: false,
    useWebsiteIcons: true,
    autoLockSeconds: 300,
    lockInBackground: true,
    lockIfWindowClosed: false,
    requirePasswordSeconds: 0,
    fastUnlock: true,
    selfDestructAttempts: 0,
    clipboardClearSeconds: 60,
    lockTexture: 12,
    lockWhiteText: true,
    autoBackupEnabled: false,
    backupIntervalDays: 7,
    cloudType: "none",
    webdav: { host: "", port: 443, useHTTPS: true, user: "", password: "", path: "/UPasswords/" },
    sidebarOptionalItems: [],
    showWhatsNewAtStartup: true,
    mainDatabaseName: "Main",
    lastWhatsNewVersion: "",
    backupLast: {},
    pwd: defaultPasswordSettings(),
  };
}

function load(): PersistedSettings {
  try {
    const raw = localStorage.getItem(KEY);
    if (!raw) return defaults();
    return { ...defaults(), ...(JSON.parse(raw) as Partial<PersistedSettings>) };
  } catch {
    return defaults();
  }
}

export const useSettingsStore = defineStore("settings", () => {
  const s = reactive<PersistedSettings>(load());

  watch(
    s,
    () => {
      localStorage.setItem(KEY, JSON.stringify(s));
    },
    { deep: true },
  );

  /** Localized backend error codes → messages. */
  function errorText(code: string): string {
    switch (code) {
      case "WRONG_PASSWORD": return t("wrong_password_error");
      case "WRONG_FORMAT": return t("wrong_database_format_error");
      case "DATABASE_EXISTS": return t("database_already_exists_error");
      case "DATABASE_NOT_FOUND": return t("database_not_fond_error");
      case "DATABASE_NAME": return t("database_name_error");
      case "BAD_URL": return t("invalid_address_text");
      case "WEBDAV_401": return t("webdav_401_error");
      case "WEBDAV_405": return t("webdav_405_error");
      case "NETWORK": return t("sync_error");
      default:
        if (code.startsWith("SYNC_HTTP_")) {
          return `${t("sync_error")} (${code.slice("SYNC_HTTP_".length)})`;
        }
        if (code.startsWith("IO: ")) return `${t("sync_error")}: ${code.slice(4)}`;
        return code;
    }
  }

  return { s, errorText };
});

/** The 8 setup-plan tasks (SetupPlanViewController) — persisted flags. */
export type SetupPlanTask =
  | "cloud_sync_task"
  | "import_passwords_task"
  | "touch_id_task"
  | "security_settings_task"
  | "auto_backup_task"
  | "autofill_task"
  | "install_on_mobile_task"
  | "ui_preferences_task";

export const SETUP_PLAN_TASKS: { key: SetupPlanTask; icon: string }[] = [
  { key: "cloud_sync_task", icon: "cloud" },
  { key: "import_passwords_task", icon: "download" },
  { key: "touch_id_task", icon: "fingerprint" },
  { key: "security_settings_task", icon: "shield-check" },
  { key: "auto_backup_task", icon: "history" },
  { key: "autofill_task", icon: "smartphone" },
  { key: "install_on_mobile_task", icon: "smartphone" },
  { key: "ui_preferences_task", icon: "paintbrush" },
];

const SETUP_KEY = "upasswords.setupPlan";

export function setupTaskDone(task: SetupPlanTask): boolean {
  try {
    const flags = JSON.parse(localStorage.getItem(SETUP_KEY) ?? "{}") as Record<string, boolean>;
    return flags[task] === true;
  } catch {
    return false;
  }
}

export function markSetupTaskDone(task: SetupPlanTask) {
  const flags = JSON.parse(localStorage.getItem(SETUP_KEY) ?? "{}") as Record<string, boolean>;
  flags[task] = true;
  localStorage.setItem(SETUP_KEY, JSON.stringify(flags));
}

export function setupCompletedCount(): number {
  return SETUP_PLAN_TASKS.filter((x) => setupTaskDone(x.key)).length;
}

/** Recent cards (RecentModel) — ids capped at 20. */
const RECENT_KEY = "upasswords.recent";

export function recentIds(): number[] {
  try {
    return JSON.parse(localStorage.getItem(RECENT_KEY) ?? "[]") as number[];
  } catch {
    return [];
  }
}

export function pushRecentId(id: number) {
  const ids = recentIds().filter((x) => x !== id);
  ids.unshift(id);
  localStorage.setItem(RECENT_KEY, JSON.stringify(ids.slice(0, 20)));
}
