<script setup lang="ts">
// Phase router — SetupWindowController / LockWindowController /
// MainWindowController equivalents. Manages window chrome per phase
// (lock = 500×380 fixed; main = restored 970×640 resizable), the sheet host
// and the toast overlay.
import { onMounted, watch } from "vue";
import { LogicalSize } from "@tauri-apps/api/dpi";
import { useAppStore } from "./stores/app";
import { useSettingsStore } from "./stores/settings";
import { useToastStore } from "./stores/toast";
import { currentWindow } from "./lib/window";
import { tBranded } from "./lib/i18n";
import SetupView from "./views/SetupView.vue";
import LockView from "./views/LockView.vue";
import MainView from "./views/MainView.vue";
import SheetHost from "./sheets/SheetHost.vue";
import ToastOverlay from "./components/ToastOverlay.vue";

const app = useAppStore();
const toast = useToastStore();
const settings = useSettingsStore();

// theme override — "system" follows the OS, otherwise force via data-theme
watch(
  () => settings.s.theme,
  (theme) => {
    if (theme === "system") delete document.documentElement.dataset.theme;
    else document.documentElement.dataset.theme = theme;
  },
  { immediate: true },
);

let savedMainFrame: { width: number; height: number } | null = null;

async function applyWindowMode() {
  const win = await currentWindow();
  if (!win) return;
  try {
    if (app.phase === "locked") {
      const size = await win.innerSize();
      const factor = await win.scaleFactor();
      savedMainFrame = { width: size.width / factor, height: size.height / factor };
      await win.setTitle(tBranded("app_title"));
      await win.setResizable(false);
      await win.setSize(new LogicalSize(500, 380));
    } else {
      await win.setTitle(
        app.phase === "unlocked" && app.databaseName
          ? app.databaseName
          : tBranded("app_title"),
      );
      await win.setResizable(true);
      if (savedMainFrame && app.phase === "unlocked") {
        await win.setSize(new LogicalSize(savedMainFrame.width, savedMainFrame.height));
        savedMainFrame = null;
      }
    }
  } catch {
    /* window API unavailable (plain web dev server) */
  }
}

watch(() => app.phase, () => void applyWindowMode());
watch(
  () => [app.phase, app.databaseName],
  () => {
    if (app.phase === "unlocked") void applyWindowMode();
  },
);

onMounted(() => {
  app.installActivityMonitor();
  void app.bootstrap().then(() => applyWindowMode());
});
</script>

<template>
  <div class="root col" @mousedown="app.touch()">
    <SetupView v-if="app.phase === 'setup'" />
    <LockView v-else-if="app.phase === 'locked'" />
    <MainView v-else />
    <SheetHost />
    <ToastOverlay />
  </div>
</template>

<style scoped>
.root { height: 100vh; }
</style>
