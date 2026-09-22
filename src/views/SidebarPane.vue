<script setup lang="ts">
// LabelListViewController — four collapsible groups (Safe 数据库名 / 标签 /
// 安全性 / 特殊) with colored group icons, counts and the 「显示」 optional-item
// menu; bottom card holds「初始化 n/8」.
import { computed, ref } from "vue";
import AppIcon from "../components/AppIcon.vue";
import PopMenu, { type MenuItem } from "../components/PopMenu.vue";
import { useAppStore } from "../stores/app";
import { useSettingsStore, setupCompletedCount } from "../stores/settings";
import { db as dbStr, t } from "../lib/i18n";
import {
  type SidebarSelection, type SpecialLabel,
  colorCss, sectionHeaderIcon, selectionEquals, specialLabelIcon, specialLabelTint,
} from "../lib/sidebar";

const app = useAppStore();
const settings = useSettingsStore();
const expanded = ref(new Set(["safe_group", "labels_group", "security_group", "special_group"]));

const SAFE_ORDER: SpecialLabel[] = [
  "all_cards_label", "favorites_label", "credit_cards_label", "notes_label",
  "totp_label", "passkeys_label", "recent_label",
];
const SECURITY_ORDER: SpecialLabel[] = ["compromised_passwords_label", "weak_passwords_label", "same_passwords_label"];
const SPECIAL_ORDER: SpecialLabel[] = ["expiring_label", "expired_label", "archived_label", "templates_label", "trash_label"];
const OPTIONAL_ORDER: SpecialLabel[] = ["passwords_label", "files_label", "images_label"];

const groups = [
  { key: "safe_group", section: "safe" as const, tint: "var(--tint)" },
  { key: "labels_group", section: "labels" as const, tint: "var(--tint)" },
  { key: "security_group", section: "security" as const, tint: "var(--destructive)" },
  { key: "special_group", section: "special" as const, tint: "var(--tint)" },
];

const safeRows = computed<SpecialLabel[]>(() => {
  const rows: SpecialLabel[] = [];
  const optional = settings.s.sidebarOptionalItems;
  for (const sp of SAFE_ORDER) {
    rows.push(sp);
    if (sp === "all_cards_label" && optional.includes("passwords_label")) rows.push("passwords_label");
    if (sp === "notes_label") {
      if (optional.includes("files_label")) rows.push("files_label");
      if (optional.includes("images_label")) rows.push("images_label");
    }
  }
  return rows;
});

const sortedLabels = computed(() =>
  [...app.database.labels].sort((a, b) => {
    if (a.pinToTop !== b.pinToTop) return a.pinToTop ? -1 : 1;
    return a.name.localeCompare(b.name, undefined, { sensitivity: "base" });
  }),
);

function toggle(key: string) {
  const set = new Set(expanded.value);
  if (set.has(key)) set.delete(key);
  else set.add(key);
  expanded.value = set;
}
const isOpen = (key: string) => expanded.value.has(key);

function tintCss(sp: SpecialLabel): string {
  const tint = specialLabelTint(sp);
  switch (tint) {
    case "yellow": return "#eab308";
    case "red": return "var(--destructive)";
    case "orange": return "#f76b15";
    case "blue": return "var(--tint)";
    default: return "var(--fg-secondary)";
  }
}

function select(sel: SidebarSelection) {
  app.selection = sel;
}

function specialMenu(sp: SpecialLabel): MenuItem[] {
  const items: MenuItem[] = [];
  if (sp === "recent_label") {
    items.push({ label: t("clear_recent_command"), action: () => localStorage.removeItem("upasswords.recent") });
  }
  if (sp === "trash_label") {
    items.push({ label: t("empty_trash_command"), action: () => app.emptyTrash() });
  }
  if (sp === "templates_label") {
    items.push({ label: t("restore_templates_command"), action: () => app.openSheet({ kind: "restoreTemplates" }) });
  }
  return items;
}

function labelMenu(id: number): MenuItem[] {
  return [
    { label: t("rename_command"), action: () => app.openSheet({ kind: "editCardLabel", id }) },
    { label: t("pin_to_top_command"), action: () => app.toggleLabelPinned(id) },
    { label: t("select_color_command"), action: () => app.openSheet({ kind: "selectColorCardLabel", id }) },
    { kind: "sep" },
    { label: t("export_command"), action: () => app.openSheet({ kind: "exportAs" }) },
    { label: t("delete_button"), destructive: true, action: () => app.deleteCardLabel(id) },
  ];
}

const showMenuItems = computed<MenuItem[]>(() =>
  OPTIONAL_ORDER.map((sp) => ({
    label: dbStr(sp),
    check: settings.s.sidebarOptionalItems.includes(sp),
    action: () => {
      const items = settings.s.sidebarOptionalItems;
      settings.s.sidebarOptionalItems = items.includes(sp)
        ? items.filter((x) => x !== sp)
        : [...items, sp];
    },
  })),
);
</script>

<template>
  <div class="sidebar col">
    <div class="scroll grow">
      <template v-for="group in groups" :key="group.key">
        <button class="group-row row" @click="toggle(group.key)">
          <AppIcon name="chevron-right" :size="9" class="chev" :class="{ open: isOpen(group.key) }" />
          <AppIcon :name="sectionHeaderIcon(group.section)" :size="12.5" :style="{ color: group.tint }" />
          <span class="group-name">
            {{ group.key === "safe_group" && app.databaseName ? app.databaseName : dbStr(group.key) }}
          </span>
        </button>

        <template v-if="isOpen(group.key)">
          <!-- Safe group -->
          <template v-if="group.section === 'safe'">
            <PopMenu
              v-for="sp in safeRows"
              :key="sp"
              :items="specialMenu(sp)"
              trigger="contextmenu"
            >
              <button
                class="row-item row"
                :class="{ selected: selectionEquals(app.selection, { kind: 'special', sp }) }"
                @click="select({ kind: 'special', sp })"
              >
                <AppIcon :name="specialLabelIcon(sp)" :size="12.5" :style="{ color: tintCss(sp) }" class="row-icon" />
                <span class="row-title">{{ dbStr(sp) }}</span>
                <span v-if="settings.s.showCardCount" class="count">{{ app.countFor({ kind: 'special', sp }) }}</span>
              </button>
            </PopMenu>
          </template>

          <!-- Labels group -->
          <template v-else-if="group.section === 'labels'">
            <PopMenu v-for="label in sortedLabels" :key="label.id" :items="labelMenu(label.id)" trigger="contextmenu">
              <button
                class="row-item row"
                :class="{ selected: selectionEquals(app.selection, { kind: 'label', id: label.id }) }"
                @click="select({ kind: 'label', id: label.id })"
              >
                <AppIcon name="tag" :size="12.5" :style="{ color: colorCss(label.color) }" class="row-icon" />
                <span class="row-title">{{ label.name }}</span>
                <span v-if="settings.s.showCardCount" class="count">{{ app.countFor({ kind: 'label', id: label.id }) }}</span>
              </button>
            </PopMenu>
          </template>

          <!-- Security / Special groups -->
          <template v-else>
            <PopMenu
              v-for="sp in group.section === 'security' ? SECURITY_ORDER : SPECIAL_ORDER"
              :key="sp"
              :items="specialMenu(sp)"
              trigger="contextmenu"
            >
              <button
                class="row-item row"
                :class="{ selected: selectionEquals(app.selection, { kind: 'special', sp }) }"
                @click="select({ kind: 'special', sp })"
              >
                <AppIcon :name="specialLabelIcon(sp)" :size="12.5" :style="{ color: tintCss(sp) }" class="row-icon" />
                <span class="row-title">{{ dbStr(sp) }}</span>
                <span v-if="settings.s.showCardCount" class="count">{{ app.countFor({ kind: 'special', sp }) }}</span>
              </button>
            </PopMenu>
          </template>
        </template>
      </template>
    </div>

    <!-- setup card -->
    <div class="setup-card">
      <button class="setup-row row" @click="app.openSheet({ kind: 'setupPlan' })">
        <AppIcon name="wrench" :size="12" class="muted" />
        <span class="setup-text">{{ t("setup_text") }} {{ setupCompletedCount() }}/8</span>
      </button>
      <PopMenu :items="showMenuItems" trigger="click">
        <button class="show-btn">{{ t("show_button") }}</button>
      </PopMenu>
    </div>
  </div>
</template>

<style scoped>
.sidebar { height: 100%; background: var(--sidebar-bg); }
.scroll { overflow-y: auto; padding: 4px 0; }
.group-row {
  gap: 5px;
  height: 28px;
  padding: 0 8px;
  background: none;
  border: none;
  cursor: pointer;
  font: inherit;
  color: var(--fg);
}
.chev { transition: transform 0.15s; color: var(--muted-fg); }
.chev.open { transform: rotate(90deg); }
.group-name { font-size: 13px; font-weight: 600; }

.row-item {
  gap: 7px;
  height: 27px;
  margin: 0 6px;
  padding: 0 10px;
  border: none;
  border-radius: var(--radius-sm);
  background: none;
  cursor: pointer;
  font: inherit;
  color: var(--fg);
  width: calc(100% - 12px);
}
.row-item.selected { background: var(--accent-fill); }
.row-item.selected .row-title { font-weight: 500; }
.row-icon { width: 17px; flex: none; }
.row-title {
  flex: 1;
  text-align: left;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  font-size: 13px;
}
.count { font-size: 11px; color: var(--muted-fg); font-variant-numeric: tabular-nums; }

.setup-card {
  border-top: 1px solid var(--border);
  padding: 10px;
  display: flex;
  flex-direction: column;
  gap: 8px;
  align-items: stretch;
  background: var(--bg);
}
.setup-row {
  gap: 7px;
  background: none;
  border: none;
  padding: 0;
  cursor: pointer;
  font: inherit;
  color: var(--fg);
}
.setup-text { font-size: 12px; font-weight: 500; }
.show-btn {
  align-self: center;
  font-size: 11px;
  font-weight: 500;
  padding: 3px 14px;
  border-radius: 999px;
  border: 1px solid var(--input-border);
  background: none;
  cursor: pointer;
  color: var(--fg);
}
</style>
