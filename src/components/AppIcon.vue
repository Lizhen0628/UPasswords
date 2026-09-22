<script setup lang="ts">
// Renders a lucide icon by kebab-name through the symbols registry.
import { computed } from "vue";
import { icon } from "../lib/symbols";
const props = withDefaults(
  defineProps<{ name: string; size?: number; strokeWidth?: number }>(),
  { size: 14, strokeWidth: 2 },
);
const comp = computed(() => icon(props.name));
</script>

<template>
  <component
    :is="comp"
    :size="size"
    :stroke-width="strokeWidth"
    :absolute-stroke-width="true"
    class="app-icon"
  />
</template>

<style scoped>
.app-icon { flex: none; }
</style>
