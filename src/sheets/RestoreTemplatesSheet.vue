<script setup lang="ts">
// restore_templates_command.
import SheetShell from "../components/SheetShell.vue";
import { useAppStore } from "../stores/app";
import { t } from "../lib/i18n";
import { TEMPLATES, makeTemplateCard } from "../lib/templates";

const app = useAppStore();

function restore() {
  for (const spec of TEMPLATES) {
    if (!app.database.cards.some((c) => c.id === spec.id)) {
      app.database.cards.push(makeTemplateCard(spec));
    }
  }
  app.saveDebounced();
  app.activeSheet = null;
}
</script>

<template>
  <SheetShell
    :title="t('restore_templates_command')"
    :ok-title="t('restore_button')"
    @cancel="app.activeSheet = null"
    @ok="restore"
  >
    <div style="max-width: 320px">{{ t("restore_templates_query") }}</div>
  </SheetShell>
</template>
