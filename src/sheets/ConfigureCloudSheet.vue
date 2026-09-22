<script setup lang="ts">
// ConfigureCloudSheetController — cloud picker + WebDAV fields + test.
import { ref } from "vue";
import SheetShell from "../components/SheetShell.vue";
import LabeledRow from "../components/LabeledRow.vue";
import CloudSettings from "../components/CloudSettings.vue";
import { useAppStore } from "../stores/app";
import { useSettingsStore, markSetupTaskDone } from "../stores/settings";
import { t } from "../lib/i18n";
import * as backend from "../lib/backend";

const app = useAppStore();
const settings = useSettingsStore();
const testing = ref(false);
const testResult = ref<string | null>(null);

async function save() {
  if (settings.s.cloudType === "webdav") {
    testing.value = true;
    try {
      await backend.webdavTest(settings.s.webdav, app.databaseName);
      testResult.value = t("success_title");
      markSetupTaskDone("cloud_sync_task");
      app.activeSheet = null;
    } catch (e) {
      testResult.value = settings.errorText(String(e));
    }
    testing.value = false;
    return;
  }
  if (settings.s.cloudType !== "none") markSetupTaskDone("cloud_sync_task");
  app.activeSheet = null;
}
</script>

<template>
  <SheetShell
    :title="t('cloud_sync_title')"
    :min-width="480"
    :ok-title="t('save_button')"
    @cancel="app.activeSheet = null"
    @ok="save"
  >
    <CloudSettings />
    <template v-if="testResult">
      <div style="margin-top: 10px">{{ testResult }}</div>
    </template>
  </SheetShell>
</template>
