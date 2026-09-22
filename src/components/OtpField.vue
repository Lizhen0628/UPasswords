<script setup lang="ts">
// ViewCardOneTimePasswordCell — live RFC 6238 code with rollover progress.
import { computed, onBeforeUnmount, onMounted, ref } from "vue";
import AppIcon from "./AppIcon.vue";
import { parseTotp, remainingSeconds, totpCode } from "../lib/totp";
import { t } from "../lib/i18n";
import { useAppStore } from "../stores/app";

const props = defineProps<{ rawValue: string }>();
const app = useAppStore();

const code = ref<string | null>(null);
const remaining = ref(0);
const error = ref<string | null>(null);
let timer: ReturnType<typeof setInterval> | undefined;

async function tick() {
  const raw = props.rawValue.trim();
  if (!raw) {
    code.value = null;
    error.value = null;
    return;
  }
  let cfg;
  try {
    cfg = parseTotp(raw);
  } catch {
    error.value = t("invalid_value_text");
    code.value = null;
    return;
  }
  try {
    code.value = await totpCode(cfg);
    remaining.value = remainingSeconds(cfg.period);
  } catch {
    error.value = t("invalid_value_text");
  }
}

const urgent = computed(() => remaining.value <= 5);

onMounted(() => {
  void tick();
  timer = setInterval(() => void tick(), 1000);
});
onBeforeUnmount(() => clearInterval(timer));
</script>

<template>
  <span class="otp row">
    <template v-if="code">
      <button class="code mono" @click="app.copyOTP(code)">{{ code }}</button>
      <AppIcon name="copy" :size="12" class="muted" />
      <span class="caption mono" :class="urgent ? 'urgent' : 'muted'">({{ remaining }}s)</span>
    </template>
    <span v-else-if="error" class="caption muted">{{ error }}</span>
    <span v-else class="muted">—</span>
  </span>
</template>

<style scoped>
.otp { gap: 8px; }
.code {
  font-size: 17px;
  font-weight: 700;
  color: var(--tint);
  background: none;
  border: none;
  padding: 0;
  cursor: pointer;
  letter-spacing: 1px;
}
.urgent { color: var(--destructive); }
</style>
