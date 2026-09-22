<script setup lang="ts">
// DatabaseInfoSheetController.
import { computed, onMounted, ref } from "vue";
import SheetShell from "../components/SheetShell.vue";
import { useAppStore } from "../stores/app";
import { useSettingsStore } from "../stores/settings";
import { t, db } from "../lib/i18n";
import * as backend from "../lib/backend";

const app = useAppStore();
const settings = useSettingsStore();
const fileSize = ref<number | null>(null);
const dbsPath = ref("");

onMounted(async () => {
  try {
    fileSize.value = await backend.databaseFileSize(app.databaseName);
  } catch {
    fileSize.value = null;
  }
});

const cards = computed(() => app.database.cards.filter((c) => !c.template));

const CLOUD_NAMES = computed(() => ({
  none: t("none_cloud"),
  webdav: t("webdav_cloud"),
  gdrive: t("gdrive_cloud"),
  dropbox: "Dropbox",
  onedrive: "OneDrive",
  icloud: "iCloud Drive",
}));

function fmtBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
  return `${(n / 1024 / 1024).toFixed(1)} MB`;
}

const rows = computed(() => [
  [t("database_name_prompt"), app.databaseName],
  [t("cards_title"), String(cards.value.filter((c) => !c.trashed && !c.archived).length)],
  [t("archived_label"), String(cards.value.filter((c) => c.archived).length)],
  [t("trash_label"), String(cards.value.filter((c) => c.trashed).length)],
  [t("labels_text"), String(app.database.labels.length)],
  [db("templates_label"), String(app.database.cards.filter((c) => c.template).length)],
  [t("cloud_prompt"), CLOUD_NAMES.value[settings.s.cloudType]],
  ...(fileSize.value !== null
    ? [[t("size_prompt"), fmtBytes(fileSize.value)] as [string, string]]
    : []),
  [t("security_title"), "PBKDF2-SHA256 ×310,000 + AES-256-GCM"],
]);
</script>

<template>
  <SheetShell
    :title="t('database_info_button')"
    :ok-title="t('close_button')"
    @cancel="app.activeSheet = null"
    @ok="app.activeSheet = null"
  >
    <div class="col" style="gap: 8px">
      <div v-for="[k, v] in rows" :key="k" class="row">
        <span class="muted key">{{ k }}</span>
        <span>{{ v }}</span>
      </div>
    </div>
  </SheetShell>
</template>

<style scoped>
.key { width: 150px; flex: none; }
</style>
