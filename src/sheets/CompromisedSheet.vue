<script setup lang="ts">
// CompromisedPasswordsSheetController — HIBP k-anonymity check with offline
// fallback.
import { ref } from "vue";
import AppIcon from "../components/AppIcon.vue";
import SheetShell from "../components/SheetShell.vue";
import CardIcon from "../components/CardIcon.vue";
import { useAppStore } from "../stores/app";
import { t } from "../lib/i18n";
import * as backend from "../lib/backend";
import type { Card } from "../lib/models";

const app = useAppStore();
const running = ref(false);
const compromisedCards = ref<Card[]>([]);
const offline = ref(false);
const resultText = ref("");

async function check(online: boolean) {
  running.value = true;
  compromisedCards.value = [];
  const active = app.database.cards.filter((c) => !c.template && !c.trashed);
  const passwords = [
    ...new Set(
      active.flatMap((c) =>
        c.fields.filter((f) => f.type === "password" && f.value).map((f) => f.value),
      ),
    ),
  ];
  let result: backend.CompromisedResult;
  try {
    result = await backend.checkCompromised(passwords, !online);
  } catch {
    result = { compromised: [], offline: false };
  }
  const set = new Set(result.compromised);
  compromisedCards.value = active.filter((c) =>
    c.fields.some((f) => f.type === "password" && set.has(f.value)),
  );
  offline.value = result.offline;
  resultText.value = `${t("compromised_passwords_found_text")} ${compromisedCards.value.length}${offline.value ? " (offline)" : ""}`;
  running.value = false;
}
</script>

<template>
  <SheetShell
    :title="t('compromised_passwords_title')"
    :min-width="520"
    :ok-title="t('close_button')"
    @cancel="app.activeSheet = null"
    @ok="app.activeSheet = null"
  >
    <div class="col" style="gap: 10px">
      <div class="caption muted">{{ t("compromised_passwords_text") }}</div>
      <div class="row" style="gap: 8px">
        <button class="btn outline" :disabled="running" @click="check(true)">
          <span class="row" style="gap: 6px">
            <AppIcon name="search" :size="12" />{{ t("check_passwords_button") }}
          </span>
        </button>
        <button class="btn outline" :disabled="running" @click="check(false)">
          {{ t("offline_button", "离线检查") }}
        </button>
        <div class="grow" />
        <span v-if="resultText">{{ resultText }}</span>
      </div>
      <div class="list col grow">
        <button
          v-for="card in compromisedCards"
          :key="card.id"
          class="row item"
          @click="app.selectedCardId = card.id; app.activeSheet = null"
        >
          <CardIcon :symbol="card.symbol" :color="card.color" :size="26" />
          <span class="grow name">{{ card.title }}</span>
          <AppIcon name="shield-alert" :size="14" class="danger" />
        </button>
        <div v-if="!compromisedCards.length && !running" class="empty muted">
          {{ t("compromised_passwords_empty_state") }}
        </div>
      </div>
    </div>
  </SheetShell>
</template>

<style scoped>
.list {
  min-height: 140px;
  max-height: 300px;
  overflow-y: auto;
  border: 1px solid var(--border);
  border-radius: var(--radius-md);
}
.item {
  gap: 10px;
  padding: 6px 10px;
  background: none;
  border: none;
  border-bottom: 1px solid color-mix(in srgb, var(--border) 50%, transparent);
  cursor: pointer;
  font: inherit;
  color: var(--fg);
  text-align: left;
}
.item:hover { background: var(--accent-fill); }
.name { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.danger { color: var(--destructive); }
.empty {
  text-align: center;
  padding: 24px;
  max-width: 360px;
  margin: 0 auto;
}
</style>
