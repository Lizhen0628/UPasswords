<script setup lang="ts">
// SetPasswordSheetController — change master password (re-encrypts container).
import { ref } from "vue";
import SheetShell from "../components/SheetShell.vue";
import LabeledRow from "../components/LabeledRow.vue";
import { useAppStore } from "../stores/app";
import { useSettingsStore } from "../stores/settings";
import { useToastStore } from "../stores/toast";
import { t } from "../lib/i18n";

const app = useAppStore();
const settings = useSettingsStore();
const toast = useToastStore();
const current = ref("");
const next = ref("");
const confirm = ref("");
const error = ref("");

async function save() {
  if (next.value.length < 4) {
    error.value = t("minimum_password_length_error");
    return;
  }
  if (next.value !== confirm.value) {
    error.value = t("passwords_do_not_match_error");
    return;
  }
  try {
    await app.changePassword(current.value, next.value);
    toast.show(t("password_changed_message"));
    app.activeSheet = null;
  } catch (e) {
    error.value = settings.errorText(String(e));
  }
}
</script>

<template>
  <SheetShell
    :title="t('change_password_button')"
    :ok-disabled="!current || !next"
    @cancel="app.activeSheet = null"
    @ok="save"
  >
    <div class="col" style="gap: 10px">
      <LabeledRow :label="t('enter_current_password_prompt')">
        <input v-model="current" type="password" />
      </LabeledRow>
      <LabeledRow :label="t('set_password_prompt')">
        <input v-model="next" type="password" />
      </LabeledRow>
      <LabeledRow :label="t('confirm_password_prompt')">
        <input v-model="confirm" type="password" @keydown.enter="save" />
      </LabeledRow>
      <div class="caption muted">{{ t("change_password_on_all_devices_message") }}</div>
      <div v-if="error" class="error">{{ error }}</div>
    </div>
  </SheetShell>
</template>

<style scoped>
.error { color: var(--destructive); font-size: 13px; }
</style>
