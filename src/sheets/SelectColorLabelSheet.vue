<script setup lang="ts">
// SelectColorViewController for labels.
import { onMounted, ref } from "vue";
import SheetShell from "../components/SheetShell.vue";
import ColorGrid from "../components/ColorGrid.vue";
import { useAppStore } from "../stores/app";
import { t } from "../lib/i18n";

const props = defineProps<{ sheet: { kind: "selectColorCardLabel"; id: number } }>();
const app = useAppStore();
const color = ref("blue");

onMounted(() => {
  const l = app.database.labels.find((x) => x.id === props.sheet.id);
  if (l?.color) color.value = l.color;
});

function save() {
  app.setLabelColor(props.sheet.id, color.value);
  app.activeSheet = null;
}
</script>

<template>
  <SheetShell
    :title="t('select_color_command')"
    @cancel="app.activeSheet = null"
    @ok="save"
  >
    <ColorGrid v-model="color" large />
  </SheetShell>
</template>
