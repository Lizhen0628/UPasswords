<script setup lang="ts">
// ManageDatabasesViewController — main/new databases: set main, rename,
// delete, switch, create.
import { ref } from "vue";
import AppIcon from "../components/AppIcon.vue";
import PopMenu, { type MenuItem } from "../components/PopMenu.vue";
import SheetShell from "../components/SheetShell.vue";
import { useAppStore } from "../stores/app";
import { useSettingsStore } from "../stores/settings";
import { useToastStore } from "../stores/toast";
import { t } from "../lib/i18n";
import { generatorInstance } from "../lib/generator";
import * as backend from "../lib/backend";

const app = useAppStore();
const settings = useSettingsStore();
const toast = useToastStore();
const newName = ref("");
const error = ref("");
const renaming = ref<{ old: string; input: string } | null>(null);

function isMain(name: string) {
  return settings.s.mainDatabaseName === name;
}

function dbMenu(name: string): MenuItem[] {
  const items: MenuItem[] = [];
  if (!isMain(name)) {
    items.push({ label: t("main_database_name"), action: () => (settings.s.mainDatabaseName = name) });
  }
  items.push({ label: t("rename_database_title"), action: () => (renaming.value = { old: name, input: name }) });
  items.push({ kind: "sep" });
  items.push({
    label: t("delete_button"),
    destructive: true,
    action: async () => {
      try {
        await backend.deleteDatabase(name);
        await app.refreshDbs();
      } catch (e) {
        error.value = settings.errorText(String(e));
      }
    },
  });
  return items;
}

async function create() {
  if (!newName.value) return;
  const pwd = generatorInstance.password(16, 0, settings.s.pwd);
  try {
    await backend.createDefaultDatabase(newName.value, pwd);
    toast.show(t("new_database_created_message"));
    newName.value = "";
    error.value = "";
    await app.refreshDbs();
  } catch (e) {
    error.value = settings.errorText(String(e));
  }
}

async function commitRename() {
  if (!renaming.value || !renaming.value.input) return;
  try {
    await backend.renameDatabase(renaming.value.old, renaming.value.input);
    if (app.databaseName === renaming.value.old) app.databaseName = renaming.value.input;
    if (settings.s.mainDatabaseName === renaming.value.old) {
      settings.s.mainDatabaseName = renaming.value.input;
    }
    await app.refreshDbs();
    renaming.value = null;
    error.value = "";
  } catch (e) {
    error.value = settings.errorText(String(e));
  }
}

async function switchTo(name: string) {
  if (app.phase === "unlocked" && name === app.databaseName) return;
  app.databaseName = name;
  settings.s.mainDatabaseName = name;
  if (app.phase === "locked") {
    app.activeSheet = null; // stay on lock screen; the new name is prefilled
  } else {
    app.lock();
  }
}
</script>

<template>
  <SheetShell
    :title="t('databases_title')"
    :min-width="520"
    :ok-title="t('close_button')"
    @cancel="app.activeSheet = null"
    @ok="app.activeSheet = null"
  >
    <div class="col" style="gap: 10px">
      <div class="caption bold muted">{{ t("main_database_group") }}</div>
      <div
        v-for="db in app.dbsList"
        :key="db.name"
        class="db-row row shadcn-card"
      >
        <AppIcon name="database" :size="14" class="muted" />
        <span class="name">{{ db.name }}</span>
        <span v-if="isMain(db.name)" class="badge secondary main-badge">{{ t("main_database_name") }}</span>
        <div class="grow" />
        <span
          v-if="db.name === app.databaseName && app.phase === 'unlocked'"
          class="caption ok"
        >{{ t("authenticated_state") }}</span>
        <PopMenu :items="dbMenu(db.name)" trigger="click">
          <button class="icon-btn">
            <AppIcon name="ellipsis" :size="13" />
          </button>
        </PopMenu>
        <button class="btn link" @click="switchTo(db.name)">{{ t("load_database_command") }}</button>
      </div>

      <!-- rename inline editor -->
      <div v-if="renaming" class="row shadcn-card rename-row">
        <input v-model="renaming.input" type="text" @keydown.enter="commitRename" />
        <button class="btn sm" @click="commitRename">{{ t("ok_button") }}</button>
        <button class="btn outline sm" @click="renaming = null">{{ t("cancel_button") }}</button>
      </div>

      <div class="divider" />
      <div class="row" style="gap: 8px">
        <input v-model="newName" type="text" :placeholder="t('database_name_prompt')" @keydown.enter="create" />
        <button class="btn" :disabled="!newName" @click="create">{{ t("new_database_button") }}</button>
      </div>
      <div v-if="error" class="error">{{ error }}</div>
    </div>
  </SheetShell>
</template>

<style scoped>
.db-row { gap: 10px; padding: 8px; }
.name { font-weight: 500; }
.main-badge { font-size: 10px; }
.ok { color: #32a467; }
.rename-row { gap: 8px; padding: 8px; }
.error { color: var(--destructive); font-size: 13px; }
.bold { font-weight: 700; }
</style>
