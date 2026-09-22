<script setup lang="ts">
// Toast overlay — the AppToast equivalent (text_copied_message etc.).
import { useToastStore } from "../stores/toast";
import AppIcon from "./AppIcon.vue";
const toast = useToastStore();
</script>

<template>
  <Transition name="toast">
    <div v-if="toast.message" class="toast">
      <AppIcon name="copy" :size="12" />
      <span>{{ toast.message }}</span>
    </div>
  </Transition>
</template>

<style scoped>
.toast {
  position: fixed;
  bottom: 24px;
  left: 50%;
  transform: translateX(-50%);
  background: var(--popover);
  border: 1px solid var(--border);
  border-radius: var(--radius-md);
  padding: 8px 14px;
  font-size: 12px;
  font-weight: 500;
  display: flex;
  gap: 8px;
  align-items: center;
  box-shadow: 0 10px 30px rgba(0, 0, 0, 0.18);
  z-index: 500;
  pointer-events: none;
}
.toast-enter-active, .toast-leave-active { transition: all 0.25s ease; }
.toast-enter-from, .toast-leave-to { opacity: 0; transform: translate(-50%, 8px); }
</style>
