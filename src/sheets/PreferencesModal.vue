<script setup lang="ts">
// The Settings window — tabbed like the original's preference panes:
// Appearance / Security / AutoBackup / Autofill / LockScreen / Cloud.
import { onMounted, ref } from "vue";
import AppIcon from "../components/AppIcon.vue";
import LabeledRow from "../components/LabeledRow.vue";
import CloudSettings from "../components/CloudSettings.vue";
import { useAppStore } from "../stores/app";
import { useSettingsStore } from "../stores/settings";
import { t, tBranded, setLanguage } from "../lib/i18n";
import { SORTINGS, type Sorting } from "../lib/sidebar";
import { LOCK_TEXTURE_COUNT, textureCss } from "../lib/lockTextures";
import * as backend from "../lib/backend";

const app = useAppStore();
const settings = useSettingsStore();
const tab = ref<"appearance" | "security" | "autoBackup" | "autofill" | "lockScreen" | "cloud">("appearance");

const TABS = [
  { key: "appearance", label: t("appearance_title") },
  { key: "security", label: t("security_title") },
  { key: "autoBackup", label: t("auto_backup_title") },
  { key: "autofill", label: t("autofill_title") },
  { key: "lockScreen", label: t("lock_screen_title") },
  { key: "cloud", label: t("cloud_sync_title") },
] as const;

function setLang(lang: string) {
  settings.s.languageOverride = lang;
  setLanguage(lang);
}

const LOCK_CHOICES = [
  { label: t("never_text"), value: 0 },
  { label: "1 m", value: 60 },
  { label: "5 m", value: 300 },
  { label: "15 m", value: 900 },
  { label: "1 h", value: 3600 },
];
const REQUIRE_CHOICES = [
  { label: t("never_text"), value: 0 },
  { label: "8 h", value: 28800 },
  { label: "1 d", value: 86400 },
  { label: "7 d", value: 604800 },
];
const CLIPBOARD_CHOICES = [
  { label: t("off_text"), value: 0 },
  { label: "10 s", value: 10 },
  { label: "30 s", value: 30 },
  { label: "1 m", value: 60 },
  { label: "2 m", value: 120 },
];
const ATTEMPTS_CHOICES = [
  { label: t("unlimited_text"), value: 0 },
  { label: "5", value: 5 },
  { label: "10", value: 10 },
  { label: "20", value: 20 },
];
const INTERVAL_CHOICES = [
  { label: "1 d", value: 1 },
  { label: "3 d", value: 3 },
  { label: "7 d", value: 7 },
  { label: "30 d", value: 30 },
];

// backups
const backups = ref<backend.BackupEntry[]>([]);
async function refreshBackups() {
  try {
    backups.value = await backend.listBackups(app.databaseName);
  } catch {
    backups.value = [];
  }
}
onMounted(refreshBackups);

async function restore(fileName: string) {
  if (!confirm(t("confirm_restore_query"))) return;
  try {
    await backend.restoreBackup(app.databaseName, fileName);
    const pw = await backend.keychainLoadPassword(app.databaseName);
    if (pw) await app.unlock(app.databaseName, pw);
    (await import("../stores/toast")).useToastStore().show(t("database_restored_message"));
  } catch (e) {
    (await import("../stores/toast")).useToastStore().show(settings.errorText(String(e)));
  }
}
</script>

<template>
  <div class="modal prefs col">
    <div class="tabs row">
      <button
        v-for="item in TABS"
        :key="item.key"
        class="tab"
        :class="{ active: tab === item.key }"
        @click="tab = item.key"
      >{{ item.label }}</button>
    </div>
    <div class="divider" />
    <div class="body grow">
      <!-- Appearance -->
      <div v-if="tab === 'appearance'" class="form col">
        <LabeledRow :label="t('language_prompt')">
          <select :value="settings.s.languageOverride" @change="setLang(($event.target as HTMLSelectElement).value)">
            <option value="">{{ t("system_default_text") }}</option>
            <option value="zh-Hans">简体中文</option>
            <option value="en">English</option>
          </select>
        </LabeledRow>
        <div class="divider" />
        <LabeledRow :label="t('sorting_title')">
          <select v-model="settings.s.sorting">
            <option v-for="s in SORTINGS" :key="s" :value="s">{{ t(`${s}_text`) }}</option>
          </select>
        </LabeledRow>
        <label class="row opt"><input v-model="settings.s.favoritesAtTop" type="checkbox" /><span>{{ t("favorites_at_top_setting") }}</span></label>
        <label class="row opt"><input v-model="settings.s.showCardCount" type="checkbox" /><span>{{ t("show_card_count_setting") }}</span></label>
        <label class="row opt"><input v-model="settings.s.hidePasswords" type="checkbox" /><span>{{ t("hide_passwords_setting") }}</span></label>
        <label class="row opt"><input v-model="settings.s.useWebsiteIcons" type="checkbox" /><span>{{ t("use_website_icons_setting") }}</span></label>
        <div class="divider" />
        <label class="row opt"><input v-model="settings.s.searchByLabels" type="checkbox" /><span>{{ t("search_by_labels_setting") }}</span></label>
        <label class="row opt"><input v-model="settings.s.searchPasswords" type="checkbox" /><span>{{ t("search_passwords_setting") }}</span></label>
        <label class="row opt" style="opacity: 0.45">
          <input type="checkbox" checked disabled /><span>{{ t("global_search_setting") }}</span>
        </label>
      </div>

      <!-- Security -->
      <div v-else-if="tab === 'security'" class="form col">
        <LabeledRow :label="t('auto_lock_setting')">
          <select v-model.number="settings.s.autoLockSeconds">
            <option v-for="c in LOCK_CHOICES" :key="c.value" :value="c.value">{{ c.label }}</option>
          </select>
        </LabeledRow>
        <label class="row opt"><input v-model="settings.s.lockInBackground" type="checkbox" /><span>{{ t("lock_in_background_button") }}</span></label>
        <label class="row opt"><input v-model="settings.s.lockIfWindowClosed" type="checkbox" /><span>{{ t("lock_if_window_closed_button") }}</span></label>
        <div class="divider" />
        <label class="row opt"><input v-model="settings.s.fastUnlock" type="checkbox" /><span>{{ t("fast_unlock_setting") }}</span></label>
        <div class="caption muted note">{{ t("touch_id_login_warning") }}</div>
        <LabeledRow :label="t('require_password_setting')">
          <select v-model.number="settings.s.requirePasswordSeconds">
            <option v-for="c in REQUIRE_CHOICES" :key="c.value" :value="c.value">{{ c.label }}</option>
          </select>
        </LabeledRow>
        <div class="divider" />
        <LabeledRow :label="t('empty_clipboard_setting')">
          <select v-model.number="settings.s.clipboardClearSeconds">
            <option v-for="c in CLIPBOARD_CHOICES" :key="c.value" :value="c.value">{{ c.label }}</option>
          </select>
        </LabeledRow>
        <LabeledRow :label="t('password_attempts_setting')">
          <select v-model.number="settings.s.selfDestructAttempts">
            <option v-for="c in ATTEMPTS_CHOICES" :key="c.value" :value="c.value">{{ c.label }}</option>
          </select>
        </LabeledRow>
        <div class="divider" />
        <div class="row" style="gap: 8px">
          <button class="btn outline" @click="app.openSheet({ kind: 'changePassword' })">
            {{ t("change_password_button") }}
          </button>
          <button class="btn destructive" @click="app.openSheet({ kind: 'eraseData' })">
            {{ t("erase_data_command") }}
          </button>
        </div>
      </div>

      <!-- Auto backup -->
      <div v-else-if="tab === 'autoBackup'" class="form col">
        <label class="row opt"><input v-model="settings.s.autoBackupEnabled" type="checkbox" /><span>{{ t("auto_backup_title") }}</span></label>
        <LabeledRow :label="t('backup_interval_setting')">
          <select v-model.number="settings.s.backupIntervalDays" :disabled="!settings.s.autoBackupEnabled">
            <option v-for="c in INTERVAL_CHOICES" :key="c.value" :value="c.value">{{ c.label }}</option>
          </select>
        </LabeledRow>
        <LabeledRow :label="t('backup_location_setting')">
          <span class="caption muted selectable">~/Library/Application Support/UPasswords/Backups</span>
        </LabeledRow>
        <div class="row" style="gap: 8px">
          <button class="btn outline" @click="app.backupNow(); refreshBackups()">{{ t("backup_now_button") }}</button>
          <button class="btn outline" :disabled="!backups.length" @click="restore(backups[0].fileName)">
            {{ t("restore_command") }}
          </button>
        </div>
        <template v-if="backups.length">
          <div class="divider" />
          <div class="caption bold muted">{{ t("last_backup_completed_text") }}</div>
          <div class="col backups">
            <div v-for="b in backups" :key="b.fileName" class="row backup-row">
              <AppIcon name="history" :size="13" class="muted" />
              <span class="grow mono caption">{{ b.fileName }}</span>
              <button class="btn link" @click="restore(b.fileName)">{{ t("restore_button") }}</button>
            </div>
          </div>
        </template>
      </div>

      <!-- Autofill -->
      <div v-else-if="tab === 'autofill'" class="col autofill-info">
        <div class="row head"><AppIcon name="globe" :size="14" /><b>{{ t("browser_integration_title") }}</b></div>
        <div class="muted">{{ t("install_extension_text") }}</div>
        <div class="row head"><AppIcon name="smartphone" :size="14" /><b>{{ t("use_for_autofill_button") }}</b></div>
        <div class="muted note-text">
          macOS autofill requires a Credential Provider extension and is not part of this replica;
          passwords can be copied from any field instead.
        </div>
      </div>

      <!-- Lock screen -->
      <div v-else-if="tab === 'lockScreen'" class="form col">
        <LabeledRow :label="t('lock_screen_background_prompt')">
          <select v-model.number="settings.s.lockTexture">
            <option v-for="i in LOCK_TEXTURE_COUNT" :key="i" :value="i - 1">{{ t("texture_text") }} {{ i }}</option>
          </select>
        </LabeledRow>
        <LabeledRow :label="t('lock_screen_text_prompt')">
          <select :value="settings.s.lockWhiteText ? 'white' : 'black'"
                  @change="settings.s.lockWhiteText = ($event.target as HTMLSelectElement).value === 'white'">
            <option value="white">{{ t("white_text_text") }}</option>
            <option value="black">{{ t("black_text_text") }}</option>
          </select>
        </LabeledRow>
        <div class="preview col" :style="{ background: textureCss(settings.s.lockTexture) }">
          <AppIcon name="lock" :size="30" />
          <span class="preview-title">{{ tBranded("app_title") }}</span>
        </div>
      </div>

      <!-- Cloud -->
      <div v-else class="form col">
        <CloudSettings />
      </div>
    </div>
    <div class="divider" />
    <div class="footer row">
      <div class="grow" />
      <button class="btn" @click="app.activeSheet = null">{{ t("close_button") }}</button>
    </div>
  </div>
</template>

<style scoped>
.prefs { min-width: 560px; width: min(640px, 92vw); height: min(470px, 90vh); }
.tabs { flex: none; padding: 12px 12px 0; gap: 2px; border-bottom: 1px solid var(--border); }
.tab {
  border: none;
  background: none;
  font: inherit;
  font-size: 13px;
  padding: 6px 12px;
  cursor: pointer;
  color: var(--muted-fg);
  border-bottom: 2px solid transparent;
  border-radius: 6px 6px 0 0;
}
.tab.active { color: var(--fg); border-bottom-color: var(--tint); }

.body { overflow-y: auto; padding: 14px; }
.form { gap: 10px; max-width: 480px; }
.opt { gap: 8px; }
.note { margin-left: 22px; }
.divider { margin: 4px 0; }

.backups { gap: 4px; }
.backup-row { gap: 8px; padding: 4px 2px; }
.bold { font-weight: 700; }

.autofill-info { gap: 14px; padding: 8px; max-width: 480px; }
.head { gap: 8px; }
.note-text { line-height: 1.5; }

.preview {
  height: 120px;
  border-radius: 10px;
  align-items: center;
  justify-content: center;
  gap: 8px;
  color: #fff;
}
.preview-title { font-weight: 600; }

.footer { padding: 10px; flex: none; }
</style>
