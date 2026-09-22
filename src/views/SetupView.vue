<script setup lang="ts">
// SetupWindowController — first-run wizard: 初始化数据库 with the original's
// three options (create new / restore from cloud / restore from local file).
import { ref } from "vue";
import LabeledRow from "../components/LabeledRow.vue";
import { useAppStore } from "../stores/app";
import { useSettingsStore } from "../stores/settings";
import { t, tBranded } from "../lib/i18n";

const app = useAppStore();
const settings = useSettingsStore();

const name = ref("");
const password = ref("");
const confirm = ref("");
const touchID = ref(true);
const error = ref("");

async function create() {
  if (password.value.length < 4) {
    error.value = t("minimum_password_length_error");
    return;
  }
  if (password.value !== confirm.value) {
    error.value = t("passwords_do_not_match_error");
    return;
  }
  try {
    await app.createDatabase(name.value, password.value, touchID.value);
  } catch (e) {
    error.value = settings.errorText(String(e));
  }
}
</script>

<template>
  <div class="setup col">
    <div class="title">{{ t("database_setup_title") }}</div>
    <div class="subtitle muted">{{ tBranded("app_title") }}</div>

    <div class="grow" />

    <div class="steps col">
      <div class="step row"><span class="muted">1.</span><b>{{ t("database_setup_item_1") }}</b></div>

      <div class="group col">
        <LabeledRow :label="t('database_name_prompt')">
          <input v-model="name" type="text" placeholder="Main" />
        </LabeledRow>
        <LabeledRow :label="t('set_password_prompt')">
          <input v-model="password" type="password" />
        </LabeledRow>
        <LabeledRow :label="t('confirm_password_prompt')">
          <input v-model="confirm" type="password" @keydown.enter="create" />
        </LabeledRow>
        <label class="row touch-id">
          <input v-model="touchID" type="checkbox" />
          <span>{{ t("touch_id_login_query") }}</span>
        </label>
        <div class="caption muted">{{ t("password_restore_warning") }}</div>
      </div>

      <div class="divider" />

      <div class="step row"><span class="muted">2.</span><span>{{ t("database_setup_item_2") }}</span></div>
      <div class="step row"><span class="muted">3.</span><span>{{ t("database_setup_item_3") }}</span></div>

      <button class="btn outline" disabled :title="t('not_configured_state')">
        {{ t("restore_from_cloud_button") }}
      </button>
    </div>

    <div class="grow" />

    <div v-if="error" class="error">{{ error }}</div>
    <div class="actions">
      <button class="btn" :disabled="!name || !password" @click="create">
        {{ t("continue_button") }}
      </button>
    </div>
  </div>
</template>

<style scoped>
.setup {
  height: 100%;
  align-items: center;
  padding: 32px 60px 28px;
}
.title { font-size: 20px; font-weight: 700; }
.subtitle { margin-top: 4px; }
.steps { gap: 14px; max-width: 420px; width: 100%; }
.step { gap: 8px; align-items: baseline; }
.group {
  border: 1px solid var(--border);
  border-radius: var(--radius-md);
  padding: 12px;
  gap: 10px;
}
.touch-id { gap: 6px; }
.error { color: var(--destructive); margin-bottom: 10px; }
.actions { margin-top: 14px; }
</style>
