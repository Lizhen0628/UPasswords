<script setup lang="ts">
// CardListViewController — search field at top with the 黄钥匙+云 sync capsule
// at the right, 48pt rows (35pt icon, title/subtitle, OTP badge, star button)
// and the full right-click context menu.
import { computed } from "vue";
import AppIcon from "../components/AppIcon.vue";
import CardIcon from "../components/CardIcon.vue";
import PopMenu, { type MenuItem } from "../components/PopMenu.vue";
import { useAppStore } from "../stores/app";
import { useSettingsStore } from "../stores/settings";
import { useToastStore } from "../stores/toast";
import { t } from "../lib/i18n";
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
</script>

<template>
  <div class="list col">
    <!-- header: search + generator/sync capsule -->
    <div class="header row">
      <div class="search shadcn-field row">
        <AppIcon name="search" :size="12" class="muted" />
        <input
          v-model="app.searchText"
          class="plain"
          type="text"
          :placeholder="t('search_text')"
        />
        <button v-if="app.searchText" class="icon-btn mini" @click="app.searchText = ''">
          <AppIcon name="circle-x" :size="12" />
        </button>
      </div>

      <div class="capsule row">
        <button class="cap-left" :title="t('generator_command')" @click="app.openSheet({ kind: 'generator' })">
          <AppIcon name="key-round" :size="11" />
        </button>
        <span class="cap-sep" />
        <PopMenu :items="cloudMenu" trigger="click">
          <button class="cap-right" :title="t('sync_command')">
            <AppIcon name="cloud" :size="11" :class="{ muted: !cloudConfigured }" />
          </button>
        </PopMenu>
      </div>
    </div>
    <div class="divider" />

    <!-- toast bar -->
    <div v-if="toast.message" class="toast-bar row">
      <span class="toast-pill row">
        <AppIcon name="copy" :size="11" />
        {{ toast.message }}
      </span>
    </div>

    <!-- card rows -->
    <div class="rows grow">
      <PopMenu v-for="card in cards" :key="card.id" :items="cardMenu(card)" trigger="contextmenu">
        <div
          class="cell row"
          :class="{ selected: app.selectedCardId === card.id }"
          @click="selectCard(card)"
        >
          <CardIcon
            class="icon"
            :symbol="card.symbol"
            :color="card.color"
            :size="35"
            :credit-card-number="card.fields.find((f) => f.type === 'number')?.value ?? null"
          />
          <div class="texts col" :class="{ 'no-sub': !subtitle(card) }">
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
            :size="14"
            class="otp-mark"
          />
          <button class="icon-btn star" :class="{ fav: card.favorite }" @click.stop="app.toggleFavorite(card.id)">
            <AppIcon name="star" :size="14" :class="{ filled: card.favorite }" />
          </button>
        </div>
      </PopMenu>

      <div v-if="cards.length === 0" class="empty">
        {{ app.emptyStateText(app.selection) }}
      </div>
    </div>
  </div>
</template>

<style scoped>
.list { height: 100%; min-width: 0; }
.header { gap: 10px; padding: 9px 12px; flex: none; }
.search { gap: 5px; padding: 0 8px; height: 26px; flex: 1; }
.search input { min-height: auto; padding: 0; }
.icon-btn.mini { width: 18px; height: 18px; }

.capsule {
  border: 1px solid var(--input-border);
  border-radius: var(--radius-md);
  overflow: hidden;
  flex: none;
}
.cap-left {
  width: 30px;
  height: 26px;
  border: none;
  background: var(--primary);
  color: var(--primary-fg);
  cursor: pointer;
  display: inline-flex;
  align-items: center;
  justify-content: center;
}
.cap-sep { width: 1px; height: 16px; background: var(--border); }
.cap-right {
  width: 30px;
  height: 26px;
  border: none;
  background: none;
  color: var(--fg);
  cursor: pointer;
  display: inline-flex;
  align-items: center;
  justify-content: center;
}

.toast-bar { justify-content: center; padding: 4px 0; flex: none; }
.toast-pill {
  gap: 6px;
  font-size: 11px;
  font-weight: 500;
  background: var(--popover);
  border: 1px solid var(--border);
  border-radius: var(--radius-sm);
  padding: 4px 10px;
}

.rows { overflow-y: auto; }
.cell {
  height: 48px;
  gap: 0;
  cursor: default;
  border-bottom: 1px solid color-mix(in srgb, var(--border) 45%, transparent);
}
.cell:hover { background: var(--accent-fill); }
.cell.selected { background: var(--accent-fill); }
.cell .icon { margin-left: 7px; }
.texts { margin-left: 10px; min-width: 0; flex: 1; gap: 1px; justify-content: center; }
.texts.no-sub { justify-content: center; }
.title { gap: 4px; min-width: 0; }
.title-text {
  font-size: 13px;
  font-weight: 600;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.subtitle {
  font-size: 11px;
  color: var(--muted-fg);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.danger { color: var(--destructive); }
.warn { color: #f76b15; }
.otp-mark { color: var(--tint); width: 32px; height: 32px; flex: none; }
.star { color: color-mix(in srgb, var(--muted-fg) 45%, transparent); margin-right: 4px; }
.star.fav { color: #eab308; }
.star .filled :deep(svg) { fill: currentColor; }

.empty {
  padding: 24px;
  text-align: center;
  color: var(--muted-fg);
  font-size: 13px;
  max-width: 320px;
  margin: 0 auto;
}
</style>
