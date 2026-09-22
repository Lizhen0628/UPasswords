<script setup lang="ts">
// add_note_command — quick note card.
import { ref } from "vue";
import SheetShell from "../components/SheetShell.vue";
import { useAppStore } from "../stores/app";
import { t, db } from "../lib/i18n";
import { newCard } from "../lib/models";

const app = useAppStore();
const title = ref("");
const notes = ref("");

function save() {
  const card = newCard(app.newCardIdValue());
  card.title = title.value || db("notes_label");
  card.notes = notes.value;
  card.color = "yellow";
  card.symbol = "note";
  app.upsertCard(card);
  app.activeSheet = null;
}
</script>

<template>
  <SheetShell
    :title="t('add_note_title')"
    :ok-disabled="!title && !notes"
    @cancel="app.activeSheet = null"
    @ok="save"
  >
    <div class="col" style="gap: 10px">
      <label class="col gap4">
        <span class="caption muted">{{ t("title_hint") }}</span>
        <input v-model="title" type="text" />
      </label>
      <div class="caption muted">{{ t("notes_prompt") }}</div>
      <textarea v-model="notes" rows="7" />
    </div>
  </SheetShell>
</template>

<style scoped>
.gap4 { gap: 4px; }
</style>
