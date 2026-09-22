<script setup lang="ts">
// SetLabelsSheetController + SetLabelsViewController — checkbox list + create
// new label on the fly.
import { onMounted, ref } from "vue";
import AppIcon from "../components/AppIcon.vue";
import SheetShell from "../components/SheetShell.vue";
import { useAppStore } from "../stores/app";
import { t } from "../lib/i18n";
import { colorCss } from "../lib/sidebar";

const props = defineProps<{ sheet: { kind: "labels"; cardId: number } }>();
const app = useAppStore();
const selection = ref(new Set<number>());
const newLabelName = ref("");

onMounted(() => {
  const c = app.database.cards.find((x) => x.id === props.sheet.cardId);
  if (c) selection.value = new Set(c.labelIds);
});

function toggle(id: number) {
  const set = new Set(selection.value);
  if (set.has(id)) set.delete(id);
  else set.add(id);
  selection.value = set;
}

function addNew() {
  if (!newLabelName.value) return;
  app.addLabelAndAssign(newLabelName.value, null, props.sheet.cardId);
  const c = app.database.cards.find((x) => x.id === props.sheet.cardId);
  if (c) selection.value = new Set(c.labelIds);
  newLabelName.value = "";
}

function save() {
  app.setLabels(props.sheet.cardId, [...selection.value]);
  app.activeSheet = null;
}
</script>

<template>
  <SheetShell
    :title="t('set_labels_button')"
    :min-width="420"
    :ok-title="t('save_button')"
    @cancel="app.activeSheet = null"
    @ok="save"
  >
    <div class="col">
      <div class="labels col">
        <button v-for="label in app.database.labels" :key="label.id" class="label-row row" @click="toggle(label.id)">
          <AppIcon
            :name="selection.has(label.id) ? 'square-check' : 'square'"
            :size="14"
            :class="selection.has(label.id) ? 'tint' : 'muted'"
          />
          <span class="dot" :style="{ background: colorCss(label.color) }" />
          <span>{{ label.name }}</span>
        </button>
      </div>
      <div class="row new-row">
        <input
          v-model="newLabelName"
          type="text"
          :placeholder="t('add_label_button')"
          @keydown.enter="addNew"
        />
        <button class="btn outline" :disabled="!newLabelName" @click="addNew">{{ t("add_button") }}</button>
      </div>
    </div>
  </SheetShell>
</template>

<style scoped>
.labels { min-height: 180px; overflow-y: auto; gap: 2px; margin-bottom: 10px; }
.label-row {
  gap: 8px;
  background: none;
  border: none;
  padding: 5px 8px;
  border-radius: 4px;
  cursor: pointer;
  font: inherit;
  color: var(--fg);
  text-align: left;
}
.label-row:hover { background: var(--accent-fill); }
.dot { width: 10px; height: 10px; border-radius: 50%; flex: none; }
.tint { color: var(--tint); }
.new-row { gap: 8px; }
</style>
