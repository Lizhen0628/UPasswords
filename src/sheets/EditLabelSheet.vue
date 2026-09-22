<script setup lang="ts">
// rename_label_title — rename + recolor a label.
import { onMounted, ref } from "vue";
import SheetShell from "../components/SheetShell.vue";
import LabeledRow from "../components/LabeledRow.vue";
import ColorGrid from "../components/ColorGrid.vue";
import { useAppStore } from "../stores/app";
import { t } from "../lib/i18n";

const props = defineProps<{ sheet: { kind: "editCardLabel"; id: number } }>();
const app = useAppStore();
const name = ref("");
const color = ref("blue");

onMounted(() => {
  const l = app.database.labels.find((x) => x.id === props.sheet.id);
  if (l) {
    name.value = l.name;
    color.value = l.color ?? "blue";
  }
});

function save() {
  app.renameCardLabel(props.sheet.id, name.value);
  app.setLabelColor(props.sheet.id, color.value);
  app.activeSheet = null;
}
</script>

<template>
  <SheetShell
    :title="t('rename_label_title')"
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
