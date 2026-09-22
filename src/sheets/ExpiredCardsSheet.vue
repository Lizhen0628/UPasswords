<script setup lang="ts">
// expiring_cards_warning prompt.
import AppIcon from "../components/AppIcon.vue";
import SheetShell from "../components/SheetShell.vue";
import { useAppStore } from "../stores/app";
import { t } from "../lib/i18n";
import { expiringInDays } from "../lib/models";

const app = useAppStore();
const cards = app.cardsFor({ kind: "special", sp: "expiring_label" }, "");

function show() {
  app.selection = { kind: "special", sp: "expiring_label" };
  app.activeSheet = null;
}
</script>

<template>
  <SheetShell
    :title="t('warning_title')"
    :ok-title="t('show_button')"
    @cancel="app.activeSheet = null"
    @ok="show"
  >
    <div class="col" style="gap: 8px">
      <div class="row" style="gap: 8px">
        <AppIcon name="hourglass" :size="14" class="warn" />
        {{ t("expiring_cards_warning") }}
      </div>
      <div v-for="card in cards.slice(0, 8)" :key="card.id" class="row">
        <span class="grow">{{ card.title }}</span>
        <span class="warn">{{ expiringInDays(card) }} {{ t("days_text") }}</span>
      </div>
    </div>
  </SheetShell>
</template>

<style scoped>
.warn { color: #f76b15; }
</style>
