<script setup lang="ts">
// SelectColorViewController color grid — the XML `color` attribute palette.
import { CARD_COLORS, colorCss } from "../lib/sidebar";
const model = defineModel<string>({ required: true });
withDefaults(defineProps<{ large?: boolean }>(), { large: false });
</script>

<template>
  <div class="grid" :class="{ large }">
    <button
      v-for="c in CARD_COLORS"
      :key="c"
      class="swatch"
      :class="{ large, [c]: true }"
      :style="{ background: colorCss(c) }"
      :title="c"
      @click="model = c"
    >
      <svg v-if="model === c" viewBox="0 0 24 24" width="12" height="12" fill="none"
           stroke="currentColor" stroke-width="3.5" stroke-linecap="round" stroke-linejoin="round">
        <path d="M20 6 9 17l-5-5" />
      </svg>
    </button>
  </div>
</template>

<style scoped>
.grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(26px, 1fr));
  gap: 8px;
}
.grid.large { grid-template-columns: repeat(auto-fill, minmax(40px, 1fr)); }
.swatch {
  border-radius: 50%;
  width: 20px;
  height: 20px;
  border: 1px solid var(--border);
  cursor: pointer;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  padding: 0;
}
.swatch.large { width: 32px; height: 32px; }
.swatch.white, .swatch.yellow { color: #000; }
.swatch:not(.white):not(.yellow) { color: #fff; }
</style>
