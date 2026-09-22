<script setup lang="ts">
// MainWindowController — 970×640 window with a 66px custom title bar
// (traffic-light gap | sidebar toggle + db name | 8 icon buttons) above a
// three-pane split (sidebar 213 / list 355 / detail).
import { computed, ref } from "vue";
import AppIcon from "../components/AppIcon.vue";
import SidebarPane from "./SidebarPane.vue";
import CardListPane from "./CardListPane.vue";
import CardDetailPane from "./CardDetailPane.vue";
import EditCardModal from "./EditCardModal.vue";
import { useAppStore } from "../stores/app";
import { currentWindow } from "../lib/window";
import { t, tBranded } from "../lib/i18n";

const app = useAppStore();
const sidebarOpen = ref(true);

interface ToolSpec {
  labelKey: string;
  helpKey: string;
  icon: string;
  enabled: () => boolean;
  active?: () => boolean;
  action: () => void;
}

const specs = computed<ToolSpec[]>(() => [
  { labelKey: "add_button", helpKey: "add_card_command", icon: "plus", enabled: () => true, action: () => app.openSheet({ kind: "addCard" }) },
  { labelKey: "delete_button", helpKey: "delete_command", icon: "trash", enabled: () => app.selectedCardId !== null, action: () => app.selectedCardId !== null && app.trashCard(app.selectedCardId) },
  { labelKey: "lock_button", helpKey: "lock_command", icon: "lock", enabled: () => true, action: () => app.lock() },
  { labelKey: "sync_button", helpKey: "sync_command", icon: "refresh-cw", enabled: () => true, action: () => void app.sync() },
  { labelKey: "generator_button", helpKey: "generator_command", icon: "key-round", enabled: () => true, action: () => app.openSheet({ kind: "generator" }) },
  { labelKey: "sorting_button", helpKey: "sorting_command", icon: "arrow-up-down", enabled: () => true, action: () => app.openSheet({ kind: "sorting" }) },
  { labelKey: "above_all_button", helpKey: "above_all_button", icon: "pin", enabled: () => true, active: () => app.floating, action: toggleFloating },
  { labelKey: "preferences_button", helpKey: "preferences_command", icon: "settings", enabled: () => true, action: () => app.openSheet({ kind: "preferences" }) },
]);

async function toggleFloating() {
  app.floating = !app.floating;
  const win = await currentWindow();
  if (!win) return;
  try {
    await win.setAlwaysOnTop(app.floating);
  } catch {
    /* not in window */
  }
}

const titleText = computed(() =>
  app.databaseName ? app.databaseName : tBranded("app_title"),
);
</script>

<template>
  <div class="main col">
    <!-- 66pt custom title bar (drag region) -->
    <div class="titlebar row" data-tauri-drag-region>
      <div class="lights-gap" data-tauri-drag-region />
      <button class="icon-btn sidebar-toggle" :title="t('show_button')" @click="sidebarOpen = !sidebarOpen">
        <AppIcon name="panel-left" :size="15" />
      </button>
      <div class="db-name" data-tauri-drag-region>{{ titleText }}</div>
      <div class="grow" data-tauri-drag-region />
      <div class="tools row">
        <button
          v-for="spec in specs"
          :key="spec.labelKey"
          class="tool col"
          :class="{ active: spec.active?.(), disabled: !spec.enabled() }"
          :disabled="!spec.enabled()"
          :title="t(spec.helpKey)"
          @click="spec.action"
        >
          <AppIcon :name="spec.icon" :size="14" />
          <span class="tool-label">{{ t(spec.labelKey) }}</span>
        </button>
      </div>
    </div>
    <div class="divider" />

    <div class="panes row grow">
      <SidebarPane v-if="sidebarOpen" class="pane-sidebar" />
      <div v-if="sidebarOpen" class="divider-v" />
      <CardListPane class="pane-list" />
      <div class="divider-v" />
      <CardDetailPane class="pane-detail" />
    </div>

    <EditCardModal v-if="app.editDraft" />
  </div>
</template>

<style scoped>
.main { height: 100vh; }
.titlebar {
  height: 66px;
  flex: none;
  background: var(--bg);
  padding-right: 12px;
}
.lights-gap { width: 76px; flex: none; }
.sidebar-toggle { width: 30px; height: 30px; margin-top: 18px; }
.db-name {
  font-size: 13px;
  font-weight: 600;
  margin: 18px 0 0 6px;
}
.tools { gap: 18px; padding-right: 6px; margin-top: 4px; align-items: flex-start; }
.tool {
  align-items: center;
  gap: 4px;
  min-width: 42px;
  padding: 0;
  background: none;
  border: none;
  color: var(--fg);
  cursor: pointer;
  font: inherit;
}
.tool svg { width: 30px; height: 30px; padding: 8px; border-radius: var(--radius-sm); }
.tool:hover svg { background: var(--accent-fill); }
.tool-label { font-size: 9px; color: var(--muted-fg); line-height: 1.1; }
.tool.active { color: var(--tint); }
.tool.active .tool-label { color: var(--tint); }
.tool.disabled { opacity: 0.35; cursor: default; }

.panes { min-height: 0; }
.pane-sidebar { width: 213px; flex: none; }
.pane-list { width: 355px; flex: none; }
.pane-detail { flex: 1; min-width: 0; }
</style>
