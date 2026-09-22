<script setup lang="ts">
// SelectColorViewController (cards) — color grid + use-website-icon toggle.
// Applies to the edit draft when open, otherwise to the selected card.
import { computed, onMounted, ref } from "vue";
import SheetShell from "../components/SheetShell.vue";
import ColorGrid from "../components/ColorGrid.vue";
import { useAppStore } from "../stores/app";
import { t } from "../lib/i18n";

const app = useAppStore();
const selection = ref("gray");

onMounted(() => {
  selection.value = app.editDraft?.card.color ?? app.selectedCard?.color ?? "gray";
});

const target = computed(() => app.editDraft?.card ?? app.selectedCard ?? null);

const useWebsiteIcon = computed({
  get: () => target.value?.useWebsiteIcon ?? false,
  set: (v: boolean) => {
    if (target.value) target.value.useWebsiteIcon = v;
  },
});

function save() {
  if (target.value) {
    target.value.color = selection.value;
    if (!app.editDraft) app.saveDebounced();
  }
  app.activeSheet = null;
}
</script>

<template>
  <SheetShell
    :title="t('select_color_command')"
    @cancel="app.activeSheet = null"
    @ok="save"
  >
    <div class="col" style="gap: 12px">
      <ColorGrid v-model="selection" large />
      <label class="row" style="gap: 6px">
        <input v-model="useWebsiteIcon" type="checkbox" />
        <span>{{ t("use_website_icon_command") }}</span>
      </label>
    </div>
  </SheetShell>
</template>
