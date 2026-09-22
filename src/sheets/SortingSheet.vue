<script setup lang="ts">
// SortingSheetController — the 8 sort orders + favorites-at-top toggle.
import { onMounted, ref } from "vue";
import AppIcon from "../components/AppIcon.vue";
import SheetShell from "../components/SheetShell.vue";
import { useAppStore } from "../stores/app";
import { useSettingsStore } from "../stores/settings";
import { t } from "../lib/i18n";
import { SORTINGS, type Sorting } from "../lib/sidebar";

const app = useAppStore();
const settings = useSettingsStore();
const value = ref<Sorting>("title_asc");

onMounted(() => {
  value.value = settings.s.sorting;
});

function save() {
  settings.s.sorting = value.value;
  app.activeSheet = null;
}
</script>

<template>
  <SheetShell
    :title="t('sorting_title')"
    @cancel="app.activeSheet = null"
    @ok="save"
  >
    <div class="col" style="gap: 6px">
      <div class="hint muted">{{ t("sorting_text") }}</div>
      <button
        v-for="s in SORTINGS"
        :key="s"
        class="opt row"
        @click="value = s"
      >
        <AppIcon :name="value === s ? 'circle-check' : 'circle'" :size="14"
                 :class="{ tint: value === s, muted: value !== s }" />
        <span>{{ t(`${s}_text`) }}</span>
      </button>
      <div class="divider" style="margin: 6px 0" />
      <label class="row" style="gap: 6px">
        <input v-model="settings.s.favoritesAtTop" type="checkbox" />
        <span>{{ t("favorites_at_top_setting") }}</span>
      </label>
    </div>
  </SheetShell>
</template>

<style scoped>
.hint { font-size: 13px; }
.opt {
  gap: 8px;
  background: none;
  border: none;
  padding: 4px 2px;
  cursor: pointer;
  font: inherit;
  color: var(--fg);
  text-align: left;
}
.opt:hover { background: var(--accent-fill); border-radius: 4px; }
.tint { color: var(--tint); }
</style>
