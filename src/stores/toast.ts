// Toast surface — mirrors AppToast in Services/DatabaseStore.swift.
import { defineStore } from "pinia";
import { ref } from "vue";

export const useToastStore = defineStore("toast", () => {
  const message = ref<string | null>(null);
  let dismissTimer: ReturnType<typeof setTimeout> | undefined;

  function show(text: string) {
    message.value = text;
    clearTimeout(dismissTimer);
    dismissTimer = setTimeout(() => {
      message.value = null;
    }, 1800);
  }

  return { message, show };
});
