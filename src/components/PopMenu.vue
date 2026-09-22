<script setup lang="ts">
// Generic popup menu — context menus and dropdown triggers.
import { nextTick, onBeforeUnmount, ref } from "vue";
import AppIcon from "./AppIcon.vue";

export interface MenuItem {
  kind?: "item" | "sep" | "title";
  label?: string;
  icon?: string;
  check?: boolean;
  destructive?: boolean;
  disabled?: boolean;
  action?: () => void;
}

const props = withDefaults(
  defineProps<{ items: MenuItem[]; trigger?: "click" | "contextmenu" }>(),
  { trigger: "click" },
);

const open = ref(false);
const x = ref(0);
const y = ref(0);
const host = ref<HTMLElement | null>(null);

const menuStyle = ref<{ left: string; top: string }>({ left: "0px", top: "0px" });

function show(clientX: number, clientY: number) {
  x.value = clientX;
  y.value = clientY;
  open.value = true;
  void nextTick(() => {
    menuStyle.value = {
      left: `${Math.max(8, Math.min(x.value, window.innerWidth - 220))}px`,
      top: `${Math.max(8, Math.min(y.value, window.innerHeight - 40 - props.items.length * 28))}px`,
    };
    document.addEventListener("mousedown", onDocDown);
  });
}
function onTrigger(e: MouseEvent) {
  e.preventDefault();
  if (open.value) {
    open.value = false;
    return;
  }
  const r = host.value?.getBoundingClientRect();
  show(e.clientX || r?.left || 0, e.clientY || r?.bottom || 0);
}
function onDocDown(e: MouseEvent) {
  const path = e.composedPath();
  if (!path.some((n) => (n as HTMLElement)?.classList?.contains?.("menu"))) {
    close();
  }
}
function close() {
  open.value = false;
  document.removeEventListener("mousedown", onDocDown);
}
function run(item: MenuItem) {
  if (item.disabled) return;
  close();
  item.action?.();
}
onBeforeUnmount(() => document.removeEventListener("mousedown", onDocDown));
</script>

<template>
  <span ref="host" class="pop-host" @[trigger]="onTrigger">
    <slot />
    <Teleport to="body">
      <div v-if="open" class="menu" :style="menuStyle">
        <template v-for="(item, i) in items" :key="i">
          <div v-if="item.kind === 'sep'" class="menu-sep" />
          <div
            v-else
            class="menu-item"
            :class="{ destructive: item.destructive }"
            :style="{ opacity: item.disabled ? 0.4 : 1 }"
            @mousedown.stop
            @click="run(item)"
          >
            <AppIcon v-if="item.icon" :name="item.icon" :size="13" />
            <AppIcon v-else-if="item.check" name="check" :size="13" />
            <span v-else class="ph" />
            <span>{{ item.label }}</span>
          </div>
        </template>
      </div>
    </Teleport>
  </span>
</template>

<style scoped>
.pop-host { display: inline-flex; }
.ph { width: 13px; flex: none; }
</style>
