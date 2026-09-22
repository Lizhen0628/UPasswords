<script setup lang="ts">
// AddLabelSheetController.
import { ref } from "vue";
import SheetShell from "../components/SheetShell.vue";
import LabeledRow from "../components/LabeledRow.vue";
import ColorGrid from "../components/ColorGrid.vue";
import { useAppStore } from "../stores/app";
import { t } from "../lib/i18n";

const app = useAppStore();
const name = ref("");
const color = ref("blue");

function save() {
  app.addLabel(name.value, color.value);
  app.activeSheet = null;
}
</script>

<template>
  <SheetShell
    :title="t('add_label_title')"
    :ok-disabled="!name"
    @cancel="app.activeSheet = null"
    @ok="save"
  >
    <div class="col" style="gap: 10px">
      <LabeledRow :label="t('name_prompt')">
        <input v-model="name" type="text" />
      </LabeledRow>
      <LabeledRow :label="t('color_prompt')">
        <ColorGrid v-model="color" />
      </LabeledRow>
    </div>
  </SheetShell>
</template>
