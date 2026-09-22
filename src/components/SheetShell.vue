<script setup lang="ts">
// Standard chrome for the original's *SheetController dialogs: title bar,
// content, cancel/OK row (Enter/Escape wired), optional search field.
import { onMounted, provide, ref } from "vue";
import AppIcon from "./AppIcon.vue";
import { t } from "../lib/i18n";

const props = withDefaults(
  defineProps<{
    title: string;
    minWidth?: number;
    okTitle?: string;
    okDisabled?: boolean;
    search?: boolean;
    cancelTitle?: string;
  }>(),
  { minWidth: 400, okDisabled: false, search: false, cancelTitle: undefined, okTitle: undefined },
);
const emit = defineEmits<{ cancel: []; ok: [] }>();
const query = defineModel<string>("query", { default: "" });

const root = ref<HTMLElement | null>(null);

function onCancel() {
  emit("cancel");
}
function onOk() {
  if (!props.okDisabled) emit("ok");
}

onMounted(() => {
  root.value?.focus();
});

provide("sheetSearchQuery", query);
</script>

<template>
  <div class="modal sheet" ref="root" tabindex="-1" :style="{ minWidth: minWidth + 'px' }" @keydown.esc="onCancel" @keydown.enter="onOk">
    <div class="modal-title">{{ title }}</div>
    <div class="divider" />
    <div class="modal-body">
      <slot />
    </div>
    <div class="divider" />
    <div class="modal-footer">
      <div v-if="search" class="shadcn-field search row">
        <AppIcon name="search" :size="12" class="muted" />
        <input v-model="query" class="plain" type="text" :placeholder="t('search_text')" />
      </div>
      <div class="grow" />
      <button class="btn outline sm" @click="onCancel">{{ cancelTitle ?? t("cancel_button") }}</button>
      <button class="btn sm" :disabled="okDisabled" @click="onOk">{{ okTitle ?? t("ok_button") }}</button>
    </div>
  </div>
</template>

<style scoped>
.sheet { outline: none; max-width: min(92vw, 720px); }
.search { gap: 5px; padding: 0 8px; height: 26px; width: 180px; }
.search input { min-height: auto; }
</style>
