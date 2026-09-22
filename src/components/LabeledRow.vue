<script setup lang="ts">
// Settings-style labeled row (label left, content right).
defineProps<{ label: string; labelWidth?: number }>();
</script>

<template>
  <div class="row labeled">
    <span class="label" :style="{ width: (labelWidth ?? 110) + 'px' }">{{ label }}</span>
    <div class="grow"><slot /></div>
  </div>
</template>

<style scoped>
.labeled { gap: 10px; margin-bottom: 2px; }
.label { flex: none; color: var(--fg-secondary); }
</style>
