<script setup lang="ts">
// CardIcon + SymbolView — a card's circular icon: symbol (lucide mapping),
// credit-card brand auto-detected from the number, or the custom placeholder.
import { computed } from "vue";
import AppIcon from "./AppIcon.vue";
import { colorCss } from "../lib/sidebar";
import { iconNameForSymbol, creditCardSymbolForNumber } from "../lib/symbols";

const props = withDefaults(
  defineProps<{
    symbol?: string | null;
    color?: string | null;
    size?: number;
    creditCardNumber?: string | null;
  }>(),
  { size: 32, creditCardNumber: null },
);

const resolved = computed(() => {
  if (!props.symbol) return "custom";
  if (props.symbol === "credit_card" && props.creditCardNumber) {
    return creditCardSymbolForNumber(props.creditCardNumber);
  }
  return props.symbol;
});
const iconName = computed(() => iconNameForSymbol(resolved.value));
const bg = computed(() => colorCss(props.color));
const iconSize = computed(() => Math.round(props.size * 0.5));
</script>

<template>
  <span
    class="card-icon"
    :style="{ width: size + 'px', height: size + 'px', background: bg }"
  >
    <AppIcon :name="iconName" :size="iconSize" :stroke-width="2.2" />
  </span>
</template>

<style scoped>
.card-icon {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  border-radius: 26%;
  color: #fff;
  flex: none;
}
</style>
