<script setup lang="ts">
// PremiumSheetController — informational only (no store integration).
import AppIcon from "../components/AppIcon.vue";
import SheetShell from "../components/SheetShell.vue";
import { useAppStore } from "../stores/app";
import { t } from "../lib/i18n";

const app = useAppStore();
</script>

<template>
  <SheetShell
    :title="t('premium_title')"
    :min-width="440"
    :ok-title="t('close_button')"
    @cancel="app.activeSheet = null"
    @ok="app.activeSheet = null"
  >
    <div class="col" style="gap: 12px">
      <div class="row ok" style="gap: 8px">
        <AppIcon name="badge-check" :size="16" />
        {{ t("license_is_active_text") }}
      </div>
      <div class="shadcn-card col activate">
        <div>{{ t("activate_license_text") }}</div>
        <div class="row" style="gap: 8px">
          <input type="text" :placeholder="t('enter_your_email_prompt')" disabled />
          <button class="btn" disabled>{{ t("activate_button") }}</button>
        </div>
        <button class="btn link">{{ t("restore_purchase_button") }}</button>
      </div>
      <div class="caption muted">This replica has no store integration; Premium is informational only.</div>
    </div>
  </SheetShell>
</template>

<style scoped>
.ok { color: #32a467; font-weight: 500; }
.activate { gap: 8px; padding: 12px; }
</style>
