<script setup lang="ts">
// ImportSheetController + ImportSourceViewController + ImportLogViewController.
import { ref } from "vue";
import AppIcon from "../components/AppIcon.vue";
import SheetShell from "../components/SheetShell.vue";
import { useAppStore } from "../stores/app";
import { useSettingsStore } from "../stores/settings";
import { markSetupTaskDone } from "../stores/settings";
import { t } from "../lib/i18n";
import { IMPORT_FORMATS, importFormatById, importParsedXml } from "../lib/importer";
import * as backend from "../lib/backend";

const app = useAppStore();
const settings = useSettingsStore();
const formatId = ref<string | null>(null);
const log = ref<string[]>([]);
const imported = ref(0);
const ranOnce = ref(false);

async function run() {
  if (!formatId.value) return;
  const files = await backend.pickFiles("xml");
  if (!files.length) {
    log.value = [t("operation_canceled_text")];
    ranOnce.value = true;
    return;
  }
  // decode base64 → text
  const b64 = files[0].data;
  const bin = atob(b64);
  const bytes = Uint8Array.from(bin, (c) => c.charCodeAt(0));
  const text = new TextDecoder().decode(bytes);

  const format = importFormatById(formatId.value);
  log.value = [
    `${t("source_prompt")} ${format?.title ?? formatId.value}`,
    t("conversion_started_message"),
  ];
  let count = 0;
  try {
    if (formatId.value === "safeincloud-xml") {
      const parsed = await backend.parseXml(text);
      count = importParsedXml(parsed, app.database);
    } else if (format) {
      count = format.parse(text, app.database, Date.now());
    }
    await app.saveNow();
    imported.value = count;
    log.value.push(`${t("conversion_completed_message")} — ${count} ${t("cards_title")}`);
  } catch (e) {
    log.value.push(`${t("conversion_failed_message")}: ${settings.errorText(String(e))}`);
  }
  ranOnce.value = true;
  markSetupTaskDone("import_passwords_task");
}
</script>

<template>
  <SheetShell
    :title="t('import_command')"
    :min-width="520"
    :ok-title="ranOnce ? t('close_button') : t('continue_button')"
    :ok-disabled="!ranOnce && !formatId"
    @cancel="app.activeSheet = null"
    @ok="ranOnce ? (app.activeSheet = null) : run()"
  >
    <div class="col" style="gap: 10px; min-height: 220px">
      <template v-if="!ranOnce">
        <div class="muted">{{ t("select_source_text") }}</div>
        <div class="grid">
          <button
            v-for="f in IMPORT_FORMATS.filter((x) => x.id !== 'safeincloud-xml')"
            :key="f.id"
            class="src"
            :class="{ selected: formatId === f.id }"
            @click="formatId = f.id"
          >{{ f.title }}</button>
        </div>
      </template>
      <template v-else>
        <div class="log-title">{{ t("log_title") }}</div>
        <div class="log col mono">
          <span v-for="(line, i) in log" :key="i">{{ line }}</span>
        </div>
        <div class="ok row">
          <AppIcon name="circle-check" :size="14" class="ok-icon" />
          {{ imported }} {{ t("cards_title") }}
        </div>
      </template>
    </div>
  </SheetShell>
</template>

<style scoped>
.grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(120px, 1fr));
  gap: 8px;
  overflow-y: auto;
  max-height: 260px;
}
.src {
  padding: 8px;
  border: 1px solid var(--border);
  border-radius: 6px;
  background: var(--card);
  cursor: pointer;
  font: inherit;
  font-size: 12px;
  color: var(--fg);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.src.selected {
  background: color-mix(in srgb, var(--tint) 20%, transparent);
  border-color: var(--tint);
}
.log-title { font-weight: 600; }
.log { gap: 2px; font-size: 12px; }
.ok { gap: 6px; font-size: 13px; }
.ok-icon { color: #32a467; }
</style>
