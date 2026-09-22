<script setup lang="ts">
// SetupPlanViewController — the 8-task onboarding checklist.
import AppIcon from "../components/AppIcon.vue";
import SheetShell from "../components/SheetShell.vue";
import { useAppStore } from "../stores/app";
import { useSettingsStore, SETUP_PLAN_TASKS, markSetupTaskDone, setupCompletedCount, setupTaskDone } from "../stores/settings";
import { t } from "../lib/i18n";
import { ref, computed } from "vue";
import * as backend from "../lib/backend";

const app = useAppStore();
const settings = useSettingsStore();
const tick = ref(0);

const done = (key: string) => {
  void tick.value;
  return setupTaskDone(key as never);
};
const completed = computed(() => {
  void tick.value;
  return setupCompletedCount();
});

async function open(key: string) {
  switch (key) {
    case "cloud_sync_task":
      app.openSheet({ kind: "configureCloud" });
      break;
    case "import_passwords_task":
      app.openSheet({ kind: "importData" });
      break;
    case "touch_id_task":
      settings.s.fastUnlock = true;
      try {
        const pw = await backend.keychainLoadPassword(app.databaseName);
        if (pw) await backend.keychainSaveBiometric(app.databaseName, pw);
      } catch { /* keychain unavailable */ }
      markSetupTaskDone("touch_id_task");
      break;
    case "security_settings_task":
    case "autofill_task":
    case "ui_preferences_task":
      app.openSheet({ kind: "preferences" });
      break;
    case "auto_backup_task":
      settings.s.autoBackupEnabled = true;
      await app.backupNow();
      markSetupTaskDone("auto_backup_task");
      break;
    case "install_on_mobile_task":
      markSetupTaskDone("install_on_mobile_task");
      break;
  }
  tick.value++;
}
</script>

<template>
  <SheetShell
    :title="t('setup_text')"
    :min-width="500"
    :ok-title="t('finish_button')"
    @cancel="app.activeSheet = null"
    @ok="app.activeSheet = null"
  >
    <div class="col">
      <div class="list col">
        <div v-for="task in SETUP_PLAN_TASKS" :key="task.key" class="row task">
          <AppIcon
            :name="done(task.key) ? 'circle-check' : 'circle'"
            :size="14"
            :class="done(task.key) ? 'ok' : 'muted'"
          />
          <span class="grow">{{ t(task.key) }}</span>
          <button class="btn link" @click="open(task.key)">{{ t("configure_button") }}</button>
        </div>
      </div>
      <div class="progress-track" style="margin-top: 10px">
        <div class="progress-fill" :style="{ width: (completed / 8) * 100 + '%' }" />
      </div>
    </div>
  </SheetShell>
</template>

<style scoped>
.list { gap: 6px; }
.task { gap: 10px; padding: 4px 2px; }
.ok { color: #32a467; }
</style>
