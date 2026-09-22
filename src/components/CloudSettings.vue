<script setup lang="ts">
// Cloud sync form shared by ConfigureCloudSheet and the preferences pane
// (ConfigureCloudSheetContents).
import AppIcon from "./AppIcon.vue";
import LabeledRow from "./LabeledRow.vue";
import { useSettingsStore, markSetupTaskDone } from "../stores/settings";
import { useAppStore } from "../stores/app";
import { t } from "../lib/i18n";
import * as backend from "../lib/backend";
import { ref } from "vue";

const settings = useSettingsStore();
const app = useAppStore();
const testing = ref(false);
const testResult = ref<string | null>(null);

const CLOUDS = [
  { key: "none", name: t("none_cloud") },
  { key: "webdav", name: t("webdav_cloud") },
  { key: "gdrive", name: t("gdrive_cloud") },
  { key: "dropbox", name: "Dropbox" },
  { key: "onedrive", name: "OneDrive" },
  { key: "icloud", name: "iCloud Drive" },
] as const;

async function test() {
  testing.value = true;
  try {
    await backend.webdavTest(settings.s.webdav, app.databaseName);
    testResult.value = t("success_title");
    markSetupTaskDone("cloud_sync_task");
  } catch (e) {
    testResult.value = settings.errorText(String(e));
  }
  testing.value = false;
}
</script>

<template>
  <div class="col" style="gap: 12px">
    <div class="caption">{{ t("cloud_sync_text") }}</div>
    <div class="col" style="gap: 5px">
      <label v-for="c in CLOUDS" :key="c.key" class="row" style="gap: 6px">
        <input
          type="radio"
          name="cloud"
          :value="c.key"
          :checked="settings.s.cloudType === c.key"
          @change="settings.s.cloudType = c.key"
        />
        <span>{{ c.name }}</span>
      </label>
    </div>

    <div v-if="settings.s.cloudType === 'webdav'" class="webdav shadcn-card col">
      <label class="row" style="gap: 6px">
        <input v-model="settings.s.webdav.useHTTPS" type="checkbox" />
        <span>HTTPS</span>
      </label>
      <LabeledRow :label="t('host_prompt')">
        <input v-model="settings.s.webdav.host" type="text" placeholder="dav.example.com" />
      </LabeledRow>
      <LabeledRow :label="t('port_prompt')">
        <input v-model.number="settings.s.webdav.port" type="number" placeholder="443" />
      </LabeledRow>
      <LabeledRow :label="t('database_name_field', '/UPasswords/')">
        <input v-model="settings.s.webdav.path" type="text" />
      </LabeledRow>
      <LabeledRow :label="t('user_name_prompt')">
        <input v-model="settings.s.webdav.user" type="text" />
      </LabeledRow>
      <LabeledRow :label="t('password_prompt')">
        <input v-model="settings.s.webdav.password" type="password" />
      </LabeledRow>
      <div class="row" style="gap: 8px">
        <button class="btn outline sm" :disabled="testing" @click="test">
          {{ testing ? t("testing_message") : t("repair_button") }}
        </button>
        <span v-if="testResult" class="caption">{{ testResult }}</span>
      </div>
      <div class="caption muted">{{ t("https_protocol_warning") }}</div>
    </div>

    <div v-else-if="settings.s.cloudType !== 'none'" class="row muted" style="gap: 6px">
      <AppIcon name="info" :size="13" />
      {{ t("not_configured_state") }}
    </div>

    <div v-if="settings.s.cloudType === 'none'" class="warn row" style="gap: 6px">
      <AppIcon name="triangle-alert" :size="13" />
      {{ t("not_synchronizing_warning") }}
    </div>
  </div>
</template>

<style scoped>
.webdav { padding: 12px; gap: 8px; }
.caption { color: var(--muted-fg); font-size: 13px; }
.warn { color: #f76b15; font-size: 12px; }
</style>
