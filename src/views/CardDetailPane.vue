<script setup lang="ts">
// Detail pane — reference-design record view: header (squircle icon, title,
// website link, star + overflow menu), label chips with a「+」adder, each
// field in its own card with persistent actions, password strength bar,
// notes card with edit pencil, metadata card and a bottom action bar.
import { computed, reactive } from "vue";
import AppIcon from "../components/AppIcon.vue";
import CardIcon from "../components/CardIcon.vue";
import PopMenu, { type MenuItem } from "../components/PopMenu.vue";
import OtpField from "../components/OtpField.vue";
import StrengthIndicator from "../components/StrengthIndicator.vue";
import { useAppStore } from "../stores/app";
import { useSettingsStore } from "../stores/settings";
import { useToastStore } from "../stores/toast";
import { t, db } from "../lib/i18n";
import { TEMPLATES } from "../lib/templates";
import { asPlainText, isHiddenType, isExpiring, isExpired, expiringInDays, newField } from "../lib/models";
import type { Card, Field } from "../lib/models";
import { scorePassword } from "../lib/strength";
import { colorCss } from "../lib/sidebar";
import * as backend from "../lib/backend";

const app = useAppStore();
const settings = useSettingsStore();
const toast = useToastStore();

const card = computed(() => app.selectedCard);
const revealed = reactive<Record<string, boolean>>({});

const cardLabels = computed(() =>
  card.value
    ? card.value.labelIds
        .map((id) => app.database.labels.find((l) => l.id === id))
        .filter((l): l is NonNullable<typeof l> => !!l)
    : [],
);

const websiteValue = computed(() =>
  card.value?.fields.find((f) => f.type === "website" && f.value)?.value ?? null,
);

function fullDate(millis: number): string {
  const d = new Date(millis);
  const p = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}/${p(d.getMonth() + 1)}/${p(d.getDate())}, ${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
}

function fmtBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
  return `${(n / 1024 / 1024).toFixed(1)} MB`;
}

function base64Bytes(b64: string): number {
  const pad = b64.endsWith("==") ? 2 : b64.endsWith("=") ? 1 : 0;
  return Math.max(0, Math.floor((b64.length * 3) / 4) - pad);
}

function fieldMenu(field: Field): MenuItem[] {
  const items: MenuItem[] = [];
  if (field.value) {
    items.push({ label: t("copy_command"), icon: "copy", action: () => void app.copy(field.value) });
  }
  if (field.history.length) {
    const df = new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" });
    items.push({ kind: "sep" });
    for (const h of [...field.history].sort((a, b) => b.time - a.time).slice(0, 10)) {
      items.push({
        label: `${h.value} — ${df.format(new Date(h.time))}`,
        action: () => void app.copy(h.value),
      });
    }
  }
  return items;
}

function openWebsite(value: string) {
  const url = value.startsWith("http") ? value : `https://${value}`;
  void backend.openExternal(url);
}

async function saveAttachment(name: string, data: string) {
  const saved = await backend.saveBinaryFile(name, data);
  if (saved) toast.show(`${t("file_saved_message")} ${saved}`);
}

function addMissingFields(specIdx: number) {
  const spec = TEMPLATES[specIdx];
  if (!spec || !card.value) return;
  const c = card.value;
  for (const f of spec.fields) {
    const name = db(f.nameKey);
    if (!c.fields.some((x) => x.name === name)) {
      c.fields.push({ ...newField(name), type: f.type, autofill: f.autofill });
    }
  }
  c.modified = Date.now();
  app.saveDebounced();
}

const addFieldMenu = computed<MenuItem[]>(() =>
  TEMPLATES.map((spec, i) => ({ label: db(spec.titleKey), action: () => addMissingFields(i) })),
);

function shareCard(c: Card) {
  void app.copy(asPlainText(c), t("text_copied_message"));
}

/** reference design shows a type icon at the left of each field name */
function fieldIcon(type: Field["type"]): string {
  switch (type) {
    case "login": return "user";
    case "password": return "lock";
    case "pin": return "lock-keyhole";
    case "number": return "credit-card";
    case "date": return "clock";
    case "phone": return "phone";
    case "website": return "link";
    case "email": return "mail";
    case "one_time_password": return "timer";
    case "expiry": return "hourglass";
    case "secret": return "key-round";
    default: return "file";
  }
}

function moreMenu(c: Card): MenuItem[] {
  return [
    { label: t("edit_command"), icon: "pencil", action: () => (app.editDraft = { card: c, isNew: false }) },
    { label: t("share_menu"), icon: "share", action: () => shareCard(c) },
    { kind: "sep" },
    { label: t("delete_command"), icon: "trash", destructive: true, action: () => app.trashCard(c.id) },
  ];
}
</script>

<template>
  <div class="detail col" v-if="card">
    <div class="scroll grow">
      <div class="content col">
        <!-- header -->
        <div class="head row">
          <CardIcon
            class="head-icon"
            :symbol="card.symbol"
            :color="card.color"
            :size="54"
            :credit-card-number="card.fields.find((f) => f.type === 'number')?.value ?? null"
          />
          <div class="col grow head-texts">
            <div class="card-title">{{ card.title || "—" }}</div>
            <button
              v-if="websiteValue"
              class="head-link row"
              @click="openWebsite(websiteValue)"
            >
              {{ websiteValue }}
            </button>
            <!-- label chips under the title (reference design) -->
            <div class="chips row">
              <span
                v-for="label in cardLabels"
                :key="label.id"
                class="chip"
                :style="{
                  color: colorCss(label.color),
                  background: `color-mix(in srgb, ${colorCss(label.color)} 16%, transparent)`,
                }"
              >{{ label.name }}</span>
              <button
                class="chip add-chip"
                :title="t('set_labels_button')"
                @click="app.openSheet({ kind: 'labels', cardId: card.id })"
              >
                <AppIcon name="plus" :size="12" />
              </button>
            </div>
            <div class="badges row">
              <span v-if="isExpired(card)" class="badge destructive">
                <AppIcon name="calendar-x" :size="10" /> {{ t("card_expired_warning") }}
              </span>
              <span v-else-if="isExpiring(card)" class="badge warning">
                <AppIcon name="hourglass" :size="10" /> {{ t("card_expiring_warning") }} {{ expiringInDays(card) }}
              </span>
              <span v-if="app.hasWeakPasswords(card)" class="badge destructive">
                <AppIcon name="triangle-alert" :size="10" /> {{ t("weak_password_message") }}
              </span>
              <span v-if="app.isCompromisedOffline(card)" class="badge destructive">
                <AppIcon name="shield-alert" :size="10" /> {{ t("compromised_password_message") }}
              </span>
            </div>
          </div>
          <button
            class="icon-btn star-btn"
            :class="{ fav: card.favorite }"
            :title="db('favorites_label')"
            @click="app.toggleFavorite(card.id)"
          >
            <AppIcon name="star" :size="17" :class="{ filled: card.favorite }" />
          </button>
          <PopMenu :items="moreMenu(card)" trigger="click">
            <button class="icon-btn" :title="t('more_info_button')">
              <AppIcon name="ellipsis" :size="17" />
            </button>
          </PopMenu>
        </div>

        <!-- fields: one card per field -->
        <template v-if="card.fields.length">
          <PopMenu
            block
            v-for="field in card.fields"
            :key="field.id"
            :items="fieldMenu(field)"
            trigger="contextmenu"
          >
            <div class="field-card shadcn-card col">
              <div class="field-name row">
                <AppIcon :name="fieldIcon(field.type)" :size="11" />
                <span>{{ field.name }}</span>
              </div>
              <div class="field-value row">
                <OtpField v-if="field.type === 'one_time_password'" :raw-value="field.value" />
                <div
                  v-else-if="isHiddenType(field.type) && !revealed[field.id] && settings.s.hidePasswords && field.value"
                  class="col grow pw-block"
                >
                  <span class="pw-dots">{{ "•".repeat(Math.max(6, Math.min([...field.value].length, 16))) }}</span>
                  <StrengthIndicator
                    v-if="field.type === 'password' && field.value"
                    :strength="scorePassword(field.value)"
                    class="pw-strength"
                  />
                </div>
                <div v-else-if="isHiddenType(field.type)" class="col grow pw-block">
                  <span class="pw-text mono selectable">{{ field.value }}</span>
                  <StrengthIndicator
                    v-if="field.type === 'password' && field.value"
                    :strength="scorePassword(field.value)"
                    class="pw-strength"
                  />
                </div>
                <button
                  v-else-if="field.type === 'website' && field.value"
                  class="value-link selectable"
                  @click="openWebsite(field.value)"
                >
                  {{ field.value }}
                </button>
                <span v-else class="value selectable">{{ field.value }}</span>
                <div class="grow" />
                <div class="field-actions row">
                  <button
                    v-if="isHiddenType(field.type) && field.value"
                    class="icon-btn mini"
                    @click="revealed[field.id] = !revealed[field.id]"
                  >
                    <AppIcon :name="revealed[field.id] ? 'eye-off' : 'eye'" :size="14" />
                  </button>
                  <button
                    v-else-if="field.type === 'website' && field.value"
                    class="icon-btn mini"
                    @click="openWebsite(field.value)"
                  >
                    <AppIcon name="globe" :size="13" />
                  </button>
                  <button
                    v-if="field.value"
                    class="icon-btn mini"
                    :title="t('copy_command')"
                    @click="app.copy(field.value)"
                  >
                    <AppIcon name="copy" :size="14" />
                  </button>
                </div>
              </div>
            </div>
          </PopMenu>

          <PopMenu v-if="!card.template" block :items="addFieldMenu" trigger="click">
            <button class="add-field row">
              <AppIcon name="plus" :size="13" />
              <span>{{ t("add_field_button") }}</span>
            </button>
          </PopMenu>
        </template>

        <!-- notes -->
        <div v-if="card.notes" class="notes-card shadcn-card col">
          <div class="row notes-head">
            <span class="field-name row">
              <AppIcon name="sticky-note" :size="11" />
              <span>{{ t("notes_tab") }}</span>
            </span>
            <div class="grow" />
            <button class="icon-btn mini" :title="t('edit_button')" @click="app.editDraft = { card, isNew: false }">
              <AppIcon name="pencil" :size="13" />
            </button>
          </div>
          <div class="notes selectable">{{ card.notes }}</div>
        </div>

        <!-- images -->
        <div v-if="card.images.length" class="col section">
          <div class="section-title">{{ db("images_label") }}</div>
          <div class="row imgs">
            <img
              v-for="img in card.images"
              :key="img.id"
              :src="`data:image/jpeg;base64,${img.data}`"
              class="img-thumb"
              alt=""
              @contextmenu.prevent="app.copy(img.data)"
            />
          </div>
        </div>

        <!-- files -->
        <div v-if="card.files.length" class="col section">
          <div class="section-title">{{ db("files_label") }}</div>
          <div v-for="file in card.files" :key="file.id" class="file-row row shadcn-card">
            <div class="file-icon">
              <AppIcon name="file" :size="14" />
            </div>
            <span class="grow file-name">{{ file.name }}</span>
            <span class="caption muted">{{ fmtBytes(base64Bytes(file.data)) }}</span>
            <button class="btn link" @click="saveAttachment(file.name, file.data)">
              {{ t("save_button") }}
            </button>
          </div>
        </div>

        <!-- metadata -->
        <div class="meta-card shadcn-card col">
          <div class="meta-row row">
            <span class="meta-label row">
              <AppIcon name="clock" :size="12" />
              {{ t("created_prompt") }}
            </span>
            <span class="meta-value">{{ fullDate(card.created) }}</span>
          </div>
          <div class="meta-row row">
            <span class="meta-label row">
              <AppIcon name="pencil" :size="12" />
              {{ t("modified_prompt") }}
            </span>
            <span class="meta-value">{{ fullDate(card.modified) }}</span>
          </div>
        </div>

        <!-- trash actions -->
        <div v-if="card.trashed || card.archived" class="row trash-actions">
          <template v-if="card.trashed">
            <button class="btn outline sm" @click="app.restoreCard(card.id)">{{ t("restore_card_command") }}</button>
            <button class="btn destructive sm" @click="app.deleteCardPermanentlyById(card.id)">{{ t("delete_button") }}</button>
          </template>
          <button v-else-if="card.archived" class="btn outline sm" @click="app.unarchiveCard(card.id)">
            {{ t("unarchive_command") }}
          </button>
        </div>
      </div>
    </div>

    <!-- bottom action bar -->
    <div class="bottom-bar row">
      <button class="btn outline sm" @click="app.editDraft = { card, isNew: false }">
        <AppIcon name="pencil" :size="12" />
        {{ t("edit_button") }}
      </button>
      <button class="btn ghost sm" @click="app.openSheet({ kind: 'labels', cardId: card.id })">
        <AppIcon name="tag" :size="12" />
        {{ t("set_labels_button") }}
      </button>
      <label class="row autofill">
        <input
          type="checkbox"
          :checked="card.autofillEnabled"
          @change="app.setCardAutofill(card.id, ($event.target as HTMLInputElement).checked)"
        />
        <span>{{ t("use_for_autofill_button") }}</span>
      </label>
      <div class="grow" />
      <button class="icon-btn" :title="t('share_menu')" @click="shareCard(card)">
        <AppIcon name="share" :size="14" />
      </button>
    </div>
  </div>

  <!-- empty state -->
  <div v-else class="detail col empty-state">
    <div class="grow empty-center col">
      <div class="empty-icon">
        <AppIcon name="shield-check" :size="22" :stroke-width="1.8" />
      </div>
      <span class="empty-text">{{ app.emptyStateText(app.selection) }}</span>
      <button class="btn outline sm" @click="app.openSheet({ kind: 'addCard' })">
        <AppIcon name="plus" :size="12" />
        {{ t("add_button") }}
      </button>
    </div>
    <div class="bottom-bar row">
      <button class="btn outline sm" disabled>
        <AppIcon name="pencil" :size="12" />
        {{ t("edit_button") }}
      </button>
      <button class="btn ghost sm" disabled>
        <AppIcon name="tag" :size="12" />
        {{ t("set_labels_button") }}
      </button>
    </div>
  </div>
</template>

<style scoped>
.detail { height: 100%; background: var(--bg); min-width: 0; }
.scroll { overflow-y: auto; }
.content {
  max-width: 560px;
  margin: 0 auto;
  padding: 22px 24px 24px;
  gap: 14px;
  align-items: stretch;
}

/* header */
.head { gap: 14px; align-items: flex-start; }
.head-icon {
  box-shadow: var(--shadow-sm), inset 0 1px 0 rgba(255, 255, 255, 0.22);
}
.head-texts { gap: 3px; min-width: 0; padding-top: 3px; }
.card-title { font-size: 18px; font-weight: 700; letter-spacing: -0.02em; line-height: 1.2; }
.head-link {
  background: none;
  border: none;
  padding: 0;
  font: inherit;
  font-size: 12px;
  color: var(--tint);
  cursor: pointer;
  text-align: left;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  max-width: 100%;
}
.head-link:hover { text-decoration: underline; }
.badges { gap: 6px; flex-wrap: wrap; margin-top: 5px; }
.badges:empty { margin-top: 0; }
.star-btn { color: var(--muted-fg); }
.star-btn.fav { color: var(--star); }
.star-btn .filled :deep(svg) { fill: currentColor; }

/* label chips */
.chips { gap: 8px; flex-wrap: wrap; margin-top: 5px; }
.chips:has(.add-chip:only-child) { margin-top: 0; }
.chip {
  display: inline-flex;
  align-items: center;
  font-size: 11.5px;
  font-weight: 500;
  line-height: 1;
  padding: 5px 12px;
  border-radius: 999px;
  border: 1px solid transparent;
}
.add-chip {
  width: 24px;
  height: 24px;
  padding: 0;
  justify-content: center;
  background: var(--card);
  border-color: var(--border);
  color: var(--muted-fg);
  cursor: pointer;
  font: inherit;
  transition: color 0.12s ease, border-color 0.12s ease;
}
.add-chip:hover { color: var(--fg); border-color: var(--border-strong); }

/* field cards */
.field-card { gap: 4px; padding: 11px 14px 12px; }
.field-name {
  gap: 6px;
  font-size: 11px;
  font-weight: 500;
  color: var(--muted-fg);
}
.field-value { gap: 6px; min-height: 24px; }
.value { font-size: 13.5px; word-break: break-all; }
.value-link {
  background: none;
  border: none;
  padding: 0;
  font: inherit;
  font-size: 13.5px;
  color: var(--tint);
  cursor: pointer;
  text-align: left;
  word-break: break-all;
}
.value-link:hover { text-decoration: underline; }
.pw-block { gap: 7px; margin: 2px 0; }
.pw-dots { font-size: 15px; letter-spacing: 2.5px; line-height: 1; }
.pw-text { font-size: 13.5px; word-break: break-all; }
.pw-strength { max-width: 300px; }
.field-actions { gap: 2px; }
.icon-btn.mini { width: 26px; height: 26px; }

.add-field {
  gap: 6px;
  background: none;
  border: 1px dashed var(--border-strong);
  color: var(--muted-fg);
  font: inherit;
  font-size: 12px;
  font-weight: 500;
  cursor: pointer;
  padding: 10px 14px;
  border-radius: var(--radius-lg);
  transition: background 0.12s ease, color 0.12s ease, border-color 0.12s ease;
}
.add-field:hover { background: var(--accent-fill); color: var(--fg); border-color: var(--border); }

/* notes */
.notes-card { padding: 11px 14px 13px; gap: 6px; }
.notes-head { min-height: 22px; }
.notes { white-space: pre-wrap; font-size: 13px; line-height: 1.55; }

/* sections */
.section { gap: 8px; }
.section-title {
  font-size: 11px;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  color: var(--muted-fg);
}
.imgs { gap: 10px; overflow-x: auto; }
.img-thumb {
  width: 96px;
  height: 96px;
  object-fit: cover;
  border-radius: var(--radius-md);
  border: 1px solid var(--border);
}
.file-row { gap: 10px; padding: 8px 12px; }
.file-icon {
  width: 28px;
  height: 28px;
  border-radius: var(--radius-sm);
  background: var(--accent-fill);
  color: var(--fg-secondary);
  display: inline-flex;
  align-items: center;
  justify-content: center;
  flex: none;
}
.file-name { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 13px; }

/* metadata */
.meta-card { padding: 4px 14px; }
.meta-row { padding: 9px 0; font-size: 12.5px; }
.meta-row + .meta-row { border-top: 1px solid color-mix(in srgb, var(--border) 70%, transparent); }
.meta-label { color: var(--muted-fg); gap: 7px; }
.meta-value { margin-left: auto; font-variant-numeric: tabular-nums; }

.trash-actions { gap: 8px; }

/* bottom bar */
.bottom-bar {
  flex: none;
  border-top: 1px solid var(--border);
  padding: 8px 16px;
  gap: 6px;
  background: var(--bg);
}
.autofill { gap: 7px; font-size: 12px; color: var(--fg-secondary); margin-left: 4px; }

/* empty state */
.empty-center {
  align-items: center;
  justify-content: center;
  gap: 14px;
}
.empty-icon {
  width: 60px;
  height: 60px;
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
  max-width: 320px;
  text-align: center;
}
</style>
