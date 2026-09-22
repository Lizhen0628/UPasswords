<script setup lang="ts">
// StrengthIndicator (Services/StrengthIndicator.h): 0–4 segments + crack time.
import { computed } from "vue";
import type { PasswordStrength } from "../lib/strength";
import { strengthCrackTimeText } from "../lib/strength";
import { t } from "../lib/i18n";

const props = defineProps<{ strength: PasswordStrength }>();

const segColor = computed(() => {
  switch (props.strength.score) {
    case 0: return "var(--destructive)";
    case 1: return "#f76b15";
    case 2: return "#eab308";
    default: return "#32a467";
  }
});
const litCount = computed(() =>
  props.strength.score === 0 ? 1 : props.strength.score,
);
const crack = computed(() => strengthCrackTimeText(props.strength));
</script>

<template>
  <div class="strength">
    <div class="segs">
      <span
        v-for="i in 4"
        :key="i"
        class="seg"
        :class="{ lit: i <= litCount }"
        :style="i <= litCount ? { background: segColor } : undefined"
      />
    </div>
    <div class="caption muted">{{ t("crack_time_prompt") }} {{ crack }}</div>
  </div>
</template>

<style scoped>
.strength { display: flex; flex-direction: column; gap: 4px; }
.segs { display: flex; gap: 3px; }
.seg {
  flex: 1;
  height: 4px;
  border-radius: 1.5px;
  background: color-mix(in srgb, var(--muted-fg) 25%, transparent);
}
</style>
