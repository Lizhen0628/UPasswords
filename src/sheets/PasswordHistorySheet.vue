<script setup lang="ts">
// HistorySheetController / password_history_command — all field history.
import AppIcon from "../components/AppIcon.vue";
import CardIcon from "../components/CardIcon.vue";
import SheetShell from "../components/SheetShell.vue";
import { useAppStore } from "../stores/app";
import { t } from "../lib/i18n";

const app = useAppStore();

const df = new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" });
</script>

<template>
  <SheetShell
    :title="t('password_history_command')"
    :min-width="520"
    :ok-title="t('close_button')"
    @cancel="app.activeSheet = null"
    @ok="app.activeSheet = null"
  >
    <div v-if="!app.allHistoryEntries.length" class="empty muted">
      {{ t("user_empty_state") }}
    </div>
    <div v-else class="col list">
      <div v-for="(e, i) in app.allHistoryEntries" :key="i" class="row item">
        <CardIcon :symbol="e.card.symbol" :color="e.card.color" :size="24" />
        <div class="col grow texts">
          <span class="title">{{ e.card.title }} — {{ e.field.name }}</span>
          <span class="value mono muted">{{ e.value }}</span>
        </div>
        <span class="caption muted">{{ df.format(new Date(e.time)) }}</span>
        <button class="icon-btn" @click="app.copy(e.value)">
          <AppIcon name="copy" :size="12" />
        </button>
      </div>
    </div>
  </SheetShell>
</template>

<style scoped>
.empty {
  display: flex;
  align-items: center;
  justify-content: center;
  min-height: 160px;
}
.list { max-height: 340px; overflow-y: auto; gap: 2px; }
.item { gap: 10px; padding: 6px 8px; }
.texts { gap: 1px; min-width: 0; }
.title { font-size: 13px; }
.value {
  font-size: 12px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
</style>
