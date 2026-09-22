<script setup lang="ts">
// Main window — reference-design toolbar: centered search field (⌘K focuses
// it), blue「+ 添加」pill, bordered sorting button and an overflow menu that
// keeps every other tool (sync / generator / delete / pin / lock / settings /
// sidebar toggle) reachable. Three-pane split below.
import { computed, onBeforeUnmount, onMounted, ref } from "vue";
import AppIcon from "../components/AppIcon.vue";
import PopMenu, { type MenuItem } from "../components/PopMenu.vue";
import SidebarPane from "./SidebarPane.vue";
import CardListPane from "./CardListPane.vue";
import CardDetailPane from "./CardDetailPane.vue";
import EditCardModal from "./EditCardModal.vue";
import { useAppStore } from "../stores/app";
import { currentWindow } from "../lib/window";
import { t } from "../lib/i18n";

const app = useAppStore();
const sidebarOpen = ref(true);
const searchInput = ref<HTMLInputElement | null>(null);

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

// overflow (☰) menu — every toolbar action that the reference design does not
// surface as a dedicated button stays reachable here
const overflowMenu = computed<MenuItem[]>(() => [
  { label: t("sync_button"), icon: "refresh-cw", action: () => void app.sync() },
  { label: t("generator_button"), icon: "key-round", action: () => app.openSheet({ kind: "generator" }) },
  {
    label: t("delete_button"),
    icon: "trash",
    destructive: true,
    disabled: app.selectedCardId === null,
    action: () => app.selectedCardId !== null && app.trashCard(app.selectedCardId),
  },
  { kind: "sep" },
  { label: t("above_all_button"), icon: "pin", check: app.floating, action: toggleFloating },
  { label: t("lock_button"), icon: "lock", action: () => app.lock() },
  { label: t("preferences_button"), icon: "settings", action: () => app.openSheet({ kind: "preferences" }) },
  { kind: "sep" },
  { label: t("show_button"), icon: "panel-left", check: sidebarOpen.value, action: () => (sidebarOpen.value = !sidebarOpen.value) },
]);

function onKeydown(e: KeyboardEvent) {
  if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") {
    e.preventDefault();
    searchInput.value?.focus();
    searchInput.value?.select();
  }
}
onMounted(() => window.addEventListener("keydown", onKeydown));
onBeforeUnmount(() => window.removeEventListener("keydown", onKeydown));
</script>

<template>
  <div class="main col">
    <!-- toolbar (drag region) -->
    <div class="titlebar row" data-tauri-drag-region>
      <div class="lights-gap" data-tauri-drag-region />

      <div class="search shadcn-field row">
        <AppIcon name="search" :size="13" class="muted" />
        <input
          ref="searchInput"
          v-model="app.searchText"
          class="plain"
          type="text"
          :placeholder="t('search_text')"
        />
        <kbd v-if="!app.searchText" class="kbd row" aria-hidden="true">
          <span class="kbd-sym">⌘</span>K
        </kbd>
        <button v-else class="icon-btn mini" @click="app.searchText = ''">
          <AppIcon name="circle-x" :size="13" />
        </button>
      </div>

      <div class="grow" data-tauri-drag-region />

      <div class="tools row">
        <button class="add-pill row" @click="app.openSheet({ kind: 'addCard' })">
          <AppIcon name="plus" :size="15" :stroke-width="2.6" />
          <span>{{ t("add_button") }}</span>
        </button>
        <button
          class="tool-icon-btn"
          :title="t('sorting_command')"
          @click="app.openSheet({ kind: 'sorting' })"
        >
          <AppIcon name="arrow-up-down" :size="15" />
        </button>
        <PopMenu :items="overflowMenu" trigger="click">
          <button class="tool-icon-btn" :title="t('more_info_button')">
            <AppIcon name="sliders-horizontal" :size="15" />
          </button>
        </PopMenu>
      </div>
    </div>

    <div class="panes row grow">
      <Transition name="slide">
        <SidebarPane v-if="sidebarOpen" class="pane-sidebar" />
      </Transition>
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
  height: 62px;
  flex: none;
  background: var(--sidebar-bg);
  border-bottom: 1px solid var(--border);
  padding-right: 14px;
  gap: 10px;
}
.lights-gap { width: 72px; flex: none; }

/* search — centered field like the reference (⌘K hint) */
.search {
  gap: 7px;
  padding: 0 8px 0 12px;
  height: 36px;
  width: 340px;
  flex: none;
  border-radius: 10px;
  background: color-mix(in srgb, var(--card) 92%, white 4%);
  border-color: var(--border);
}
.search input { min-height: auto; padding: 0; font-size: 12.5px; }
.kbd {
  gap: 2px;
  font-family: inherit;
  font-size: 11px;
  color: var(--muted-fg);
  background: var(--accent-fill);
  border: 1px solid var(--border);
  border-radius: 5px;
  padding: 2px 6px;
  flex: none;
}
.kbd-sym { font-size: 12px; }
.icon-btn.mini { width: 20px; height: 20px; border-radius: var(--radius-sm); }

/* right side: add pill + bordered icon buttons */
.tools { gap: 10px; }
.add-pill {
  appearance: none;
  border: none;
  gap: 6px;
  height: 34px;
  padding: 0 18px;
  border-radius: 10px;
  background: var(--primary);
  color: var(--primary-fg);
  font: inherit;
  font-size: 13px;
  font-weight: 600;
  cursor: pointer;
  box-shadow: 0 2px 10px color-mix(in srgb, var(--primary) 40%, transparent);
  transition: opacity 0.15s ease;
}
.add-pill:hover { opacity: 0.88; }
.add-pill:active { opacity: 0.75; }
.add-pill:focus-visible {
  outline: none;
  box-shadow: 0 0 0 2px var(--bg), 0 0 0 4px color-mix(in srgb, var(--ring) 55%, transparent);
}
.tool-icon-btn {
  appearance: none;
  width: 34px;
  height: 34px;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  border: 1px solid var(--border-strong);
  border-radius: 10px;
  background: transparent;
  color: var(--fg-secondary);
  cursor: pointer;
  transition: background 0.15s ease, color 0.15s ease;
}
.tool-icon-btn:hover { background: var(--accent-fill); color: var(--fg); }
.tool-icon-btn:focus-visible {
  outline: none;
  box-shadow: 0 0 0 2px var(--bg), 0 0 0 4px color-mix(in srgb, var(--ring) 55%, transparent);
}

.panes { min-height: 0; }
.pane-sidebar { width: 232px; flex: none; }
.pane-list { width: 342px; flex: none; }
.pane-detail { flex: 1; min-width: 0; }

.slide-enter-active, .slide-leave-active { transition: opacity 0.15s ease; }
.slide-enter-from, .slide-leave-to { opacity: 0; }
</style>
