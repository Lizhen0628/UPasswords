<script setup lang="ts">
// AboutWindowController.
import AppIcon from "../components/AppIcon.vue";
import SheetShell from "../components/SheetShell.vue";
import { useAppStore } from "../stores/app";
import { t, tBranded } from "../lib/i18n";

const app = useAppStore();
</script>

<template>
  <SheetShell
    :title="t('about_title')"
    :ok-title="t('close_button')"
    @cancel="app.activeSheet = null"
    @ok="app.activeSheet = null"
  >
    <div class="col about" style="gap: 12px; align-items: center">
      <AppIcon name="shield-check" :size="56" class="tint" />
      <div class="title">{{ tBranded("app_title") }}</div>
      <div class="muted">{{ t("version_text") }} 1.0 (1000)</div>
      <div class="caption muted">© 2026 UPasswords</div>
      <div class="caption muted legal">
        Tauri 2 + Vue 3 rewrite of the Swift replica of Safe.app (SafeInCloud 25.3.5) — see README
      </div>
      <div class="divider" style="width: 100%" />
      <div class="row" style="gap: 16px">
        <button class="btn link" @click="app.openSheet({ kind: 'premium' })">{{ t("license_info_button") }}</button>
        <button class="btn link" @click="app.openSheet({ kind: 'whatsNew' })">{{ t("legal_title") }}</button>
      </div>
    </div>
  </SheetShell>
</template>

<style scoped>
.about { padding: 6px 10px; }
.title { font-size: 17px; font-weight: 700; }
.tint { color: var(--tint); }
.legal { max-width: 360px; text-align: center; }
</style>
