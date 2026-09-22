<script setup lang="ts">
// SelectDatabaseSheetController — from the lock screen.
import AppIcon from "../components/AppIcon.vue";
import SheetShell from "../components/SheetShell.vue";
import { useAppStore } from "../stores/app";
import { useSettingsStore } from "../stores/settings";
import { t } from "../lib/i18n";

const app = useAppStore();
const settings = useSettingsStore();

function pick(name: string) {
  app.databaseName = name;
  settings.s.mainDatabaseName = name;
  app.activeSheet = null;
}
</script>

<template>
  <SheetShell
    :title="t('select_database_title')"
    :ok-title="t('close_button')"
    @cancel="app.activeSheet = null"
    @ok="app.activeSheet = null"
  >
    <div class="col list">
      <button v-for="db in app.dbsList" :key="db.name" class="row item" @click="pick(db.name)">
        <AppIcon name="database" :size="14" class="muted" />
        <span class="grow">{{ db.name }}</span>
        <AppIcon v-if="db.name === app.databaseName" name="check" :size="14" class="tint" />
      </button>
    </div>
  </SheetShell>
</template>

<style scoped>
.list { min-height: 120px; gap: 2px; }
.item {
  gap: 10px;
  padding: 6px 10px;
  border: none;
  border-radius: 6px;
  background: none;
  cursor: pointer;
  font: inherit;
  color: var(--fg);
  text-align: left;
}
.item:hover { background: var(--accent-fill); }
.tint { color: var(--tint); }
</style>
