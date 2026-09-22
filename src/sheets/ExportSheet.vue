<script setup lang="ts">
// ExportAsSheetController — XML / CSV / TXT export with plaintext warning.
import { ref } from "vue";
import AppIcon from "../components/AppIcon.vue";
import SheetShell from "../components/SheetShell.vue";
import { useAppStore } from "../stores/app";
import { useSettingsStore } from "../stores/settings";
import { useToastStore } from "../stores/toast";
import { t } from "../lib/i18n";
import { exportCards, EXPORT_FORMATS, type ExportFormat } from "../lib/importer";
import * as backend from "../lib/backend";

const app = useAppStore();
const settings = useSettingsStore();
const toast = useToastStore();
const format = ref<ExportFormat>("xml");

async function doExport() {
  const cards = app.database.cards.filter((c) => !c.template);
  let text: string;
  if (format.value === "xml") {
    text = await backend.serializeXml({
      labels: app.database.labels,
      cards,
      ghosts: [],
    });
  } else {
    text = exportCards(cards, app.database.labels, format.value, () => "");
  }
  const saved = await backend.saveTextFile(`${app.databaseName}.${format.value}`, text);
  if (saved) toast.show(`${t("data_exported_message")} ${saved}`);
  app.activeSheet = null;
}
</script>

<template>
  <SheetShell
    :title="t('export_as_title')"
    @cancel="app.activeSheet = null"
    @ok="doExport"
  >
    <div class="col" style="gap: 12px">
      <div>{{ t("export_as_text") }}</div>
      <div class="col" style="gap: 5px">
        <label v-for="f in EXPORT_FORMATS" :key="f" class="row" style="gap: 6px">
          <input type="radio" :value="f" v-model="format" />
          <span>{{ t(`${f}_format_text`) }}</span>
        </label>
      </div>
      <div class="warning row">
        <AppIcon name="triangle-alert" :size="13" />
        {{ t("export_warning_message") }}
      </div>
    </div>
  </SheetShell>
</template>

<style scoped>
.warning {
  gap: 6px;
  color: #f76b15;
  font-size: 13px;
}
</style>
