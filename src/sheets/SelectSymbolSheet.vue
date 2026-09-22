<script setup lang="ts">
// SelectSymbolViewController — grouped symbol catalog with search.
import { computed, ref } from "vue";
import AppIcon from "../components/AppIcon.vue";
import SheetShell from "../components/SheetShell.vue";
import { useAppStore } from "../stores/app";
import { t } from "../lib/i18n";
import {
  SYMBOL_GROUPS, allSymbolNames, groupLocalizedName, iconNameForSymbol, symbolNamesForGroup,
} from "../lib/symbols";

const app = useAppStore();
const group = ref(SYMBOL_GROUPS[0]);
const query = ref("");

const items = computed(() => {
  if (query.value) {
    const q = query.value.toLowerCase();
    return allSymbolNames().filter((n) => n.toLowerCase().includes(q));
  }
  return symbolNamesForGroup(group.value);
});

function pick(name: string) {
  if (app.editDraft) app.editDraft.card.symbol = name;
  app.activeSheet = null;
}

const current = computed(() => app.editDraft?.card.symbol ?? null);
</script>

<template>
  <SheetShell
    :title="t('select_symbol_command')"
    :min-width="520"
    :ok-title="t('close_button')"
    search
    @cancel="app.activeSheet = null"
    @ok="app.activeSheet = null"
    v-model:query="query"
  >
    <div class="col">
      <select v-if="!query" v-model="group">
        <option v-for="g in SYMBOL_GROUPS" :key="g" :value="g">{{ groupLocalizedName(g) }}</option>
      </select>
      <div class="grid">
        <button
          v-for="name in items"
          :key="name"
          class="cell col"
          :class="{ selected: current === name }"
          @click="pick(name)"
        >
          <AppIcon :name="iconNameForSymbol(name)" :size="20" />
          <span class="name">{{ name }}</span>
        </button>
      </div>
    </div>
  </SheetShell>
</template>

<style scoped>
select { margin-bottom: 10px; width: auto; }
.grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(72px, 1fr));
  gap: 10px;
}
.cell {
  gap: 4px;
  align-items: center;
  padding: 8px 4px;
  border: none;
  border-radius: 8px;
  background: color-mix(in srgb, var(--fg) 4%, transparent);
  cursor: pointer;
  color: var(--fg);
  font: inherit;
}
.cell:hover, .cell.selected { background: color-mix(in srgb, var(--tint) 20%, transparent); }
.name {
  font-size: 10px;
  color: var(--muted-fg);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  max-width: 100%;
}
</style>
