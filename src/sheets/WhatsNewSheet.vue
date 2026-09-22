<script setup lang="ts">
// WhatsNewSheetController (whats_new.json).
import { ref } from "vue";
import AppIcon from "../components/AppIcon.vue";
import SheetShell from "../components/SheetShell.vue";
import { useAppStore } from "../stores/app";
import { useSettingsStore } from "../stores/settings";
import { t } from "../lib/i18n";

const app = useAppStore();
const settings = useSettingsStore();
const showAtStartup = ref(settings.s.showWhatsNewAtStartup);

function close() {
  settings.s.showWhatsNewAtStartup = showAtStartup.value;
  app.activeSheet = null;
}

const FEATURES = [
  { icon: "shield-check", text: "PBKDF2-SHA256 ×310,000 + AES-256-GCM" },
  { icon: "timer", text: "TOTP (RFC 6238) one-time codes" },
  { icon: "cloud", text: "WebDAV cloud sync with item-level merge" },
  { icon: "download", text: "18 import formats (Chrome/Bitwarden/LastPass/…)" },
  { icon: "chart-column", text: "Password strength & compromised checks (k-anonymity)" },
];
</script>

<template>
  <SheetShell
    :title="t('whats_new_title')"
    :min-width="420"
    :ok-title="t('finish_button')"
    @cancel="close"
    @ok="close"
  >
    <div class="col" style="gap: 10px">
      <div v-for="(f, i) in FEATURES" :key="i" class="row feature">
        <AppIcon :name="f.icon" :size="14" class="muted" />
        <span>{{ f.text }}</span>
      </div>
      <label class="row" style="gap: 6px; margin-top: 4px">
        <input v-model="showAtStartup" type="checkbox" />
        <span>{{ t("show_this_info_at_startup_button") }}</span>
      </label>
    </div>
  </SheetShell>
</template>

<style scoped>
.feature { gap: 8px; align-items: flex-start; }
</style>
