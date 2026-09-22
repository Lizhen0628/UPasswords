<script setup lang="ts">
// erase_data_command confirm.
import SheetShell from "../components/SheetShell.vue";
import { useAppStore } from "../stores/app";
import { t } from "../lib/i18n";

const app = useAppStore();

function erase() {
  void app.eraseAllData();
  app.activeSheet = null;
}
</script>

<template>
  <SheetShell
    :title="t('erase_data_command')"
    :ok-title="t('delete_button')"
    @cancel="app.activeSheet = null"
    @ok="erase"
  >
    <div style="max-width: 360px">{{ t("erase_data_text") }}</div>
  </SheetShell>
</template>
