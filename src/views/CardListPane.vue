<script setup lang="ts">
// Card list — reference-design header (selection title + count, cloud menu)
// and rounded rows: squircle icon, title/subtitle, OTP mark, first-label pill
// and a persistent star (filled yellow when favorited). Search moved to the
// toolbar (⌘K); full right-click menu kept.
import { computed } from "vue";
import AppIcon from "../components/AppIcon.vue";
import CardIcon from "../components/CardIcon.vue";
import PopMenu, { type MenuItem } from "../components/PopMenu.vue";
import { useAppStore } from "../stores/app";
import { useSettingsStore } from "../stores/settings";
import { useToastStore } from "../stores/toast";
import { t, db } from "../lib/i18n";
import { sortingName } from "../lib/sidebar";
import { cardLogin, isExpiring, isExpired } from "../lib/models";
import type { Card } from "../lib/models";

const app = useAppStore();
const settings = useSettingsStore();
const toast = useToastStore();

const cards = computed(() => app.currentCards);

const firstWord = computed(() =>
  app.searchText.toLowerCase().split(" ").filter(Boolean)[0] ?? "",
);

function previewFor(card: Card): string | null {
  return app.searchText ? app.searchPreview(card, firstWord.value) : null;
}

function subtitle(card: Card): string {
  const preview = previewFor(card);
  if (preview) return preview;
  const login = cardLogin(card);
  if (login) return login;
  return card.fields.find((f) => f.value)?.value ?? "";
}

function selectCard(card: Card) {
  app.selectedCardId = card.id;
}

function cardMenu(card: Card): MenuItem[] {
  const items: MenuItem[] = [
    { label: t("add_card_command"), action: () => app.openSheet({ kind: "addCard" }) },
    { label: t("add_note_command"), action: () => app.openSheet({ kind: "addNote" }) },
    { label: t("add_template_command"), action: () => app.openSheet({ kind: "addCard" }) },
    { kind: "sep" },
    { label: t("edit_command"), action: () => (app.editDraft = { card, isNew: false }) },
    { label: t("delete_command"), action: () => app.trashCard(card.id) },
    { label: t("move_command"), action: () => app.openSheet({ kind: "labels", cardId: card.id }) },
    { label: t("duplicate_command"), action: () => app.duplicateCard(card.id) },
    { label: t("save_as_template_command"), action: () => app.saveAsTemplate(card) },
  ];
  if (card.archived) {
    items.push({ label: t("unarchive_command"), action: () => app.unarchiveCard(card.id) });
  } else {
    items.push({ label: t("archive_command"), action: () => app.archiveCard(card.id) });
  }
  if (card.trashed) {
    items.push({ label: t("restore_card_command"), action: () => app.restoreCard(card.id) });
  }
  items.push(
    { kind: "sep" },
    {
      label: t("copy_as_text_command"),
      action: () => {
        const lines = [card.title];
        for (const f of card.fields) lines.push(`${f.name}: ${f.value}`);
        if (card.notes) lines.push(card.notes);
        void app.copy(lines.join("\n"));
      },
    },
    { label: t("export_command"), action: () => app.openSheet({ kind: "exportAs" }) },
    { kind: "sep" },
    { label: t("set_labels_command"), action: () => app.openSheet({ kind: "labels", cardId: card.id }) },
    {
      label: t("use_website_icon_command"),
      action: () => {
        card.useWebsiteIcon = !card.useWebsiteIcon;
        app.saveDebounced();
      },
    },
    { label: t("select_symbol_command"), action: () => app.openSheet({ kind: "selectSymbol" }) },
    { label: t("select_color_command"), action: () => app.openSheet({ kind: "selectColor" }) },
  );
  return items;
}

const cloudMenu: MenuItem[] = [
  { label: t("sync_command"), icon: "refresh-cw", action: () => void app.sync() },
  { kind: "sep" },
  { label: t("manage_databases_command"), icon: "database", action: () => app.openSheet({ kind: "manageDatabases" }) },
  { label: t("configure_cloud_command"), icon: "cloud", action: () => app.openSheet({ kind: "configureCloud" }) },
];

const cloudConfigured = computed(() => settings.s.cloudType !== "none");

const selectionTitle = computed(() => {
  const sel = app.selection;
  if (sel.kind === "label") {
    return app.database.labels.find((l) => l.id === sel.id)?.name ?? "";
  }
  return db(sel.sp);
});
</script>

<template>
  <div class="list col">
    <!-- header: selection title + cloud menu -->
    <div class="header row">
      <span class="list-title">
        {{ selectionTitle }}
        <span class="list-count">({{ cards.length }})</span>
      </span>
      <div class="grow" />
      <PopMenu :items="cloudMenu" trigger="click">
        <button class="icon-btn" :title="t('sync_command')">
          <AppIcon name="cloud" :size="15" :class="{ muted: !cloudConfigured }" />
        </button>
      </PopMenu>
      <button class="sort-btn row" @click="app.openSheet({ kind: 'sorting' })">
        <span>{{ sortingName(settings.s.sorting) }}</span>
        <AppIcon name="chevron-down" :size="11" class="muted" />
      </button>
    </div>

    <!-- toast bar -->
    <div v-if="toast.message" class="toast-bar row">
      <span class="toast-pill row">
        <AppIcon name="copy" :size="11" />
        {{ toast.message }}
      </span>
    </div>

    <!-- card rows -->
    <div class="rows grow">
      <PopMenu block v-for="card in cards" :key="card.id" :items="cardMenu(card)" trigger="contextmenu">
        <div
          class="cell row"
          :class="{ selected: app.selectedCardId === card.id }"
          @click="selectCard(card)"
        >
          <CardIcon
            class="icon"
            :symbol="card.symbol"
            :color="card.color"
            :size="40"
            :credit-card-number="card.fields.find((f) => f.type === 'number')?.value ?? null"
          />
          <div class="texts col">
            <div class="title row">
              <span class="title-text">{{ card.title || "—" }}</span>
              <AppIcon v-if="isExpired(card)" name="calendar-x" :size="11" class="danger" />
              <AppIcon v-else-if="isExpiring(card)" name="hourglass" :size="11" class="warn" />
              <AppIcon v-if="app.hasWeakPasswords(card)" name="triangle-alert" :size="11" class="danger" />
            </div>
            <div v-if="subtitle(card)" class="subtitle">{{ subtitle(card) }}</div>
          </div>
          <div class="grow" />
          <AppIcon
            v-if="card.fields.some((f) => f.type === 'one_time_password')"
            name="timer"
            :size="13"
            class="otp-mark"
          />
          <button
            class="icon-btn mini star"
            :class="{ fav: card.favorite }"
            @click.stop="app.toggleFavorite(card.id)"
          >
            <AppIcon name="star" :size="14" :class="{ filled: card.favorite }" />
          </button>
          <AppIcon name="chevron-right" :size="13" class="row-chev" />
        </div>
      </PopMenu>

      <!-- empty state -->
      <div v-if="cards.length === 0" class="empty col">
        <div class="empty-icon">
          <AppIcon name="layout-grid" :size="18" />
        </div>
        <span class="empty-text">{{ app.emptyStateText(app.selection) }}</span>
        <button class="btn outline sm" @click="app.openSheet({ kind: 'addCard' })">
          <AppIcon name="plus" :size="12" />
          {{ t("add_button") }}
        </button>
      </div>
    </div>
  </div>
</template>

<style scoped>
.list { height: 100%; min-width: 0; background: var(--bg); }

.header {
  gap: 8px;
  padding: 12px 10px 8px 16px;
  flex: none;
  border-bottom: 1px solid var(--border);
}
.list-title { font-size: 13.5px; font-weight: 600; letter-spacing: -0.01em; }
.list-count { color: var(--muted-fg); font-weight: 500; }
.icon-btn.mini { width: 24px; height: 24px; border-radius: var(--radius-sm); }
.sort-btn {
  appearance: none;
  gap: 4px;
  background: none;
  border: none;
  font: inherit;
  font-size: 11.5px;
  color: var(--muted-fg);
  cursor: pointer;
  padding: 4px 6px;
  border-radius: var(--radius-sm);
}
.sort-btn:hover { color: var(--fg); background: var(--accent-fill); }

.toast-bar { justify-content: center; padding: 0 0 6px; flex: none; }
.toast-pill {
  gap: 6px;
  font-size: 11px;
  font-weight: 500;
  background: var(--popover);
  border: 1px solid var(--border);
  border-radius: 999px;
  padding: 4px 12px;
  box-shadow: var(--shadow-sm);
}

.rows { overflow-y: auto; padding: 6px 8px 10px; }
.cell {
  min-height: 56px;
  gap: 11px;
  padding: 8px 10px;
  margin-top: 2px;
  border-radius: var(--radius-lg);
  cursor: default;
  border: 1px solid transparent;
  transition: background 0.12s ease, border-color 0.12s ease;
}
.cell:hover { background: color-mix(in srgb, var(--accent-fill) 55%, transparent); }
.cell.selected {
  background: var(--select-row);
  border-color: var(--select-row-border);
}
.cell .icon { flex: none; }
.texts { min-width: 0; flex: 1; gap: 1px; justify-content: center; }
.title { gap: 5px; min-width: 0; }
.title-text {
  font-size: 13px;
  font-weight: 500;
  letter-spacing: -0.01em;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.selected .title-text { font-weight: 600; }
.subtitle {
  font-size: 11.5px;
  color: var(--muted-fg);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.danger { color: var(--destructive); }
.warn { color: var(--warning); }
.otp-mark { color: var(--tint); flex: none; }

.star {
  color: color-mix(in srgb, var(--muted-fg) 70%, transparent);
}
.star.fav { color: var(--star); }
.star .filled :deep(svg) { fill: currentColor; }

.row-chev { color: var(--muted-fg); opacity: 0.5; flex: none; }

.empty {
  align-items: center;
  justify-content: center;
  gap: 12px;
  height: 100%;
  padding: 24px;
  text-align: center;
}
.empty-icon {
  width: 44px;
  height: 44px;
  border-radius: 50%;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  color: var(--muted-fg);
  background: var(--accent-fill);
}
.empty-text {
  color: var(--muted-fg);
  font-size: 12.5px;
  line-height: 1.6;
  max-width: 240px;
}
</style>
