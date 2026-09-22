<script setup lang="ts">
// SelectTemplateSheetController — 添加项目 template grid.
import SheetShell from "../components/SheetShell.vue";
import CardIcon from "../components/CardIcon.vue";
import { useAppStore } from "../stores/app";
import { t, db } from "../lib/i18n";
import { TEMPLATES, makeCardFromSpec } from "../lib/templates";
import { newCard } from "../lib/models";

const app = useAppStore();

function openCustom() {
  app.editDraft = { card: newCard(app.newCardIdValue()), isNew: true };
  app.activeSheet = null;
}

function openFrom(specId: number) {
  const spec = TEMPLATES.find((s) => s.id === specId);
  if (!spec) return;
  app.editDraft = { card: makeCardFromSpec(spec, app.newCardIdValue()), isNew: true };
  app.activeSheet = null;
}
</script>

<template>
  <SheetShell
    :title="t('add_card_title')"
    :min-width="460"
    :ok-title="db('custom_template')"
    @cancel="app.activeSheet = null"
    @ok="openCustom"
  >
    <div class="col">
      <div class="hint muted">{{ t("select_template_title") }}</div>
      <div class="grid">
        <button v-for="spec in TEMPLATES" :key="spec.id" class="cell col" @click="openFrom(spec.id)">
          <CardIcon :symbol="spec.symbol" color="gray" :size="40" />
          <span class="name">{{ db(spec.titleKey) }}</span>
        </button>
      </div>
    </div>
  </SheetShell>
</template>

<style scoped>
.hint { font-size: 13px; margin-bottom: 10px; }
.grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(132px, 1fr));
  gap: 10px;
}
.cell {
  gap: 8px;
  align-items: center;
  padding: 14px 8px;
  border: none;
  border-radius: 10px;
  background: color-mix(in srgb, var(--fg) 4%, transparent);
  cursor: pointer;
  font: inherit;
  color: var(--fg);
}
.cell:hover { background: var(--accent-fill); }
.name { font-size: 12px; }
</style>
