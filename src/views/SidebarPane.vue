<script setup lang="ts">
// Sidebar — reference-design nav: brand header (shield logo + wordmark),
// collapsible section groups (database / labels / security / special) with
// tinted icons and counts, blue pill selection, colored label dots, plus a
// security-score style progress ring card and the「显示」menu at the bottom.
import { computed, ref } from "vue";
import AppIcon from "../components/AppIcon.vue";
import PopMenu, { type MenuItem } from "../components/PopMenu.vue";
import { useAppStore } from "../stores/app";
import { useSettingsStore, setupCompletedCount } from "../stores/settings";
import { db as dbStr, t, tBranded } from "../lib/i18n";
import {
  type SidebarSelection, type SpecialLabel,
  colorCss, selectionEquals, specialLabelIcon, specialLabelTint,
} from "../lib/sidebar";
import logoUrl from "../assets/reference-style/logo-shield.png";

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
  { key: "safe_group", section: "safe" as const },
  { key: "labels_group", section: "labels" as const },
  { key: "security_group", section: "security" as const },
  { key: "special_group", section: "special" as const },
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
    case "yellow": return "var(--star)";
    case "red": return "var(--destructive)";
    case "orange": return "#f78130";
    case "blue": return "var(--tint)";
    default: return "var(--fg-secondary)";
  }
}

function select(sel: SidebarSelection) {
  app.selection = sel;
}

/** bottom-bar moon button — toggles explicit light/dark, "system" untouched */
function toggleTheme() {
  const el = document.documentElement;
  const darkNow =
    el.dataset.theme === "dark" ||
    (el.dataset.theme !== "light" && window.matchMedia("(prefers-color-scheme: dark)").matches);
  settings.s.theme = darkNow ? "light" : "dark";
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

const setupTotal = 8;
const setupPct = computed(() => Math.round((setupCompletedCount() / setupTotal) * 100));
const ringLen = 2 * Math.PI * 15;
</script>

<template>
  <div class="sidebar col">
    <!-- brand header -->
    <div class="brand row">
      <img class="brand-logo" :src="logoUrl" alt="" aria-hidden="true" draggable="false" />
      <div class="col brand-texts">
        <span class="brand-name">{{ tBranded("app_title") }}</span>
        <span class="brand-tagline">Your secrets, safer.</span>
      </div>
    </div>

    <div class="scroll grow">
      <template v-for="group in groups" :key="group.key">
        <div class="group-row row">
          <button class="group-toggle row" @click="toggle(group.key)">
            <AppIcon name="chevron-right" :size="10" :stroke-width="2.5" class="chev" :class="{ open: isOpen(group.key) }" />
            <span class="group-name">
              {{ group.key === "safe_group" && app.databaseName ? app.databaseName : dbStr(group.key) }}
            </span>
          </button>
          <button
            v-if="group.section === 'labels'"
            class="icon-btn mini group-add"
            :title="t('add_label_button')"
            @click="app.openSheet({ kind: 'addLabel' })"
          >
            <AppIcon name="plus" :size="13" />
          </button>
        </div>

        <template v-if="isOpen(group.key)">
          <!-- Safe group -->
          <template v-if="group.section === 'safe'">
            <PopMenu
              block
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
                <AppIcon :name="specialLabelIcon(sp)" :size="14" :style="{ color: tintCss(sp) }" class="row-icon" />
                <span class="row-title">{{ dbStr(sp) }}</span>
                <span v-if="settings.s.showCardCount" class="count">{{ app.countFor({ kind: 'special', sp }) }}</span>
              </button>
            </PopMenu>
          </template>

          <!-- Labels group -->
          <template v-else-if="group.section === 'labels'">
            <PopMenu block v-for="label in sortedLabels" :key="label.id" :items="labelMenu(label.id)" trigger="contextmenu">
              <button
                class="row-item row"
                :class="{ selected: selectionEquals(app.selection, { kind: 'label', id: label.id }) }"
                @click="select({ kind: 'label', id: label.id })"
              >
                <span class="dot" :style="{ background: colorCss(label.color) }" />
                <span class="row-title">{{ label.name }}</span>
                <span v-if="settings.s.showCardCount" class="count">{{ app.countFor({ kind: 'label', id: label.id }) }}</span>
              </button>
            </PopMenu>
          </template>

          <!-- Security / Special groups -->
          <template v-else>
            <PopMenu
              block
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
                <AppIcon :name="specialLabelIcon(sp)" :size="14" :style="{ color: tintCss(sp) }" class="row-icon" />
                <span class="row-title">{{ dbStr(sp) }}</span>
                <span v-if="settings.s.showCardCount" class="count">{{ app.countFor({ kind: 'special', sp }) }}</span>
              </button>
            </PopMenu>
          </template>
        </template>
      </template>
    </div>

    <!-- setup progress card (security-score style ring) -->
    <div class="bottom col">
      <button class="score-card row" @click="app.openSheet({ kind: 'setupPlan' })">
        <span class="ring">
          <svg viewBox="0 0 36 36" width="38" height="38">
            <circle cx="18" cy="18" r="15" class="ring-track" />
            <circle
              cx="18" cy="18" r="15"
              class="ring-fill"
              :stroke-dasharray="`${(setupPct / 100) * ringLen} ${ringLen}`"
            />
          </svg>
          <span class="ring-pct">{{ setupPct }}</span>
        </span>
        <span class="col grow score-texts">
          <span class="score-title">{{ t("setup_text") }}</span>
          <span class="score-sub">{{ setupCompletedCount() }}/{{ setupTotal }}</span>
        </span>
        <AppIcon name="chevron-right" :size="14" class="muted" />
      </button>
      <div class="row bottom-menu">
        <button class="icon-btn" :title="t('preferences_button')" @click="app.openSheet({ kind: 'preferences' })">
          <AppIcon name="settings" :size="15" />
        </button>
        <button class="icon-btn" :title="t('dark_mode_button', '深色模式')" @click="toggleTheme">
          <AppIcon name="moon" :size="15" />
        </button>
        <div class="grow" />
        <PopMenu :items="showMenuItems" trigger="click">
          <button class="btn ghost sm show-btn">{{ t("show_button") }}</button>
        </PopMenu>
      </div>
    </div>
  </div>
</template>

<style scoped>
.sidebar { height: 100%; background: var(--sidebar-bg); }

.brand { gap: 10px; padding: 14px 14px 12px; flex: none; }
.brand-logo {
  width: 34px;
  height: 38px;
  object-fit: contain;
  flex: none;
  user-select: none;
  -webkit-user-drag: none;
}
.brand-texts { gap: 1px; min-width: 0; }
.brand-name { font-size: 15px; font-weight: 700; letter-spacing: -0.01em; }
.brand-tagline { font-size: 10.5px; color: var(--muted-fg); }

.scroll { overflow-y: auto; padding: 2px 10px 6px; }

.group-row {
  height: 26px;
  margin-top: 10px;
  padding-right: 2px;
}
.group-row:first-child { margin-top: 2px; }
.group-toggle {
  flex: 1;
  min-width: 0;
  gap: 5px;
  height: 100%;
  padding: 0 6px;
  background: none;
  border: none;
  border-radius: var(--radius-sm);
  cursor: pointer;
  font: inherit;
  color: var(--muted-fg);
}
.group-toggle:hover { color: var(--fg); }
.chev { transition: transform 0.15s ease; }
.chev.open { transform: rotate(90deg); }
.group-name {
  font-size: 12px;
  font-weight: 600;
  letter-spacing: -0.01em;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.row-item {
  gap: 10px;
  height: 32px;
  padding: 0 10px;
  margin-top: 2px;
  border: none;
  border-radius: var(--radius-md);
  background: none;
  cursor: pointer;
  font: inherit;
  color: var(--fg);
  width: 100%;
  transition: background 0.12s ease;
}
.row-item:hover { background: var(--accent-fill); }
.row-item.selected { background: var(--select-pill); }
.row-item.selected .row-title { font-weight: 600; color: #fff; }
.row-item.selected :deep(.app-icon) { color: #fff !important; }
.row-item.selected .count { color: rgba(255, 255, 255, 0.75); }
.row-icon { width: 18px; flex: none; }
.row-title {
  flex: 1;
  text-align: left;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  font-size: 13px;
}
.dot {
  width: 9px;
  height: 9px;
  border-radius: 50%;
  flex: none;
  margin: 0 4.5px;
}
.count { font-size: 11px; color: var(--muted-fg); font-variant-numeric: tabular-nums; }

.bottom { flex: none; padding: 8px 10px 6px; }
.score-card {
  gap: 10px;
  width: 100%;
  padding: 10px 12px;
  background: var(--card);
  border: 1px solid var(--border);
  border-radius: var(--radius-lg);
  box-shadow: var(--shadow-xs);
  cursor: pointer;
  font: inherit;
  color: var(--fg);
  text-align: left;
  transition: background 0.12s ease;
}
.score-card:hover { background: color-mix(in srgb, var(--card) 80%, var(--accent-fill)); }
.ring { position: relative; width: 38px; height: 38px; flex: none; }
.ring svg { display: block; transform: rotate(-90deg); }
.ring-track { fill: none; stroke: var(--accent-fill); stroke-width: 3.5; }
.ring-fill {
  fill: none;
  stroke: var(--strength-strong);
  stroke-width: 3.5;
  stroke-linecap: round;
  transition: stroke-dasharray 0.3s ease;
}
.ring-pct {
  position: absolute;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 10px;
  font-weight: 700;
  font-variant-numeric: tabular-nums;
}
.score-texts { gap: 2px; min-width: 0; }
.score-title { font-size: 12.5px; font-weight: 600; }
.score-sub { font-size: 11px; color: var(--muted-fg); }
.bottom-menu { padding: 2px 2px 0; gap: 2px; }
.icon-btn.mini { width: 22px; height: 22px; border-radius: var(--radius-sm); }
.group-add { color: var(--muted-fg); }
.group-add:hover { color: var(--fg); }
.show-btn { min-height: 20px; padding: 0 6px; font-size: 10.5px; color: var(--muted-fg); }
</style>
