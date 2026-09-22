<script setup lang="ts">
// ViewCardViewController — detail pane: title block with a large circular icon
// (star at its left), form-style field rows (caption / value / hairline),
// notes, images, files, footer timestamps and the bottom action bar.
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
import * as backend from "../lib/backend";

const app = useAppStore();
const settings = useSettingsStore();
const toast = useToastStore();

const card = computed(() => app.selectedCard);
const revealed = reactive<Record<string, boolean>>({});

const labelNames = computed(() =>
  card.value
    ? card.value.labelIds
        .map((id) => app.database.labels.find((l) => l.id === id)?.name)
        .filter((n): n is string => !!n)
        .join(", ")
    : "",
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
</script>

<template>
  <div class="detail col" v-if="card">
    <div class="scroll grow">
      <div class="content col">
        <!-- header -->
        <div class="head row">
          <div class="col grow">
            <div class="card-title">{{ card.title || "—" }}</div>
            <div v-if="labelNames" class="labels-text muted">{{ labelNames }}</div>
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
          <button class="icon-btn" :class="{ fav: card.favorite }" @click="app.toggleFavorite(card.id)">
            <AppIcon name="star" :size="16" :class="{ filled: card.favorite }" />
          </button>
          <CardIcon
            :symbol="card.symbol"
            :color="card.color"
            :size="64"
            :credit-card-number="card.fields.find((f) => f.type === 'number')?.value ?? null"
          />
        </div>

        <!-- fields -->
        <div v-if="card.fields.length" class="fields col">
          <PopMenu
            v-for="field in card.fields"
            :key="field.id"
            :items="fieldMenu(field)"
            trigger="contextmenu"
          >
            <div class="field col">
              <div class="field-name">{{ field.name }}</div>
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
                <span v-else class="value selectable">{{ field.value }}</span>
                <div class="grow" />
                <button
                  v-if="isHiddenType(field.type) && field.value"
                  class="icon-btn"
                  @click="revealed[field.id] = !revealed[field.id]"
                >
                  <AppIcon :name="revealed[field.id] ? 'eye-off' : 'eye'" :size="13" />
                </button>
                <button
                  v-else-if="field.type === 'website' && field.value"
                  class="icon-btn"
                  @click="openWebsite(field.value)"
                >
                  <AppIcon name="globe" :size="13" />
                </button>
              </div>
              <div class="hairline" />
            </div>
          </PopMenu>

          <PopMenu v-if="!card.template" :items="addFieldMenu" trigger="click">
            <button class="add-field row">
              <AppIcon name="circle-plus" :size="12" />
              <span>{{ t("add_field_button") }}</span>
            </button>
          </PopMenu>
        </div>

        <!-- notes -->
        <div v-if="card.notes" class="col section">
          <div class="section-title">{{ t("notes_tab") }}</div>
          <div class="notes shadcn-card selectable">{{ card.notes }}</div>
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
            <AppIcon name="file" :size="13" />
            <span class="grow file-name">{{ file.name }}</span>
            <span class="caption muted">{{ fmtBytes(base64Bytes(file.data)) }}</span>
            <button class="btn link" @click="saveAttachment(file.name, file.data)">
              {{ t("save_button") }}
            </button>
          </div>
        </div>

        <!-- footer -->
        <div class="footer col">
          <span>{{ t("modified_prompt") }} {{ fullDate(card.modified) }}</span>
          <span>{{ t("created_prompt") }} {{ fullDate(card.created) }}</span>
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
        {{ t("edit_button") }}
      </button>
      <button class="btn outline sm" @click="app.openSheet({ kind: 'labels', cardId: card.id })">
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
        <AppIcon name="share" :size="13" />
      </button>
    </div>
  </div>

  <!-- empty state: flat blank, disabled bottom bar -->
  <div v-else class="detail col empty-state">
    <div class="grow" />
    <div class="bottom-bar row">
      <button class="btn outline sm" disabled>{{ t("edit_button") }}</button>
      <button class="btn outline sm" disabled>{{ t("set_labels_button") }}</button>
    </div>
  </div>
</template>

<style scoped>
.detail { height: 100%; background: var(--bg); min-width: 0; }
.empty-state > .grow { background: var(--sidebar-bg); }
.scroll { overflow-y: auto; }
.content {
  max-width: 680px;
  margin: 0 auto;
  padding: 24px;
  gap: 18px;
  align-items: stretch;
}

.head { gap: 14px; align-items: flex-start; }
.card-title { font-size: 22px; font-weight: 700; line-height: 1.2; }
.labels-text { font-size: 13px; margin-top: 4px; }
.badges { gap: 6px; flex-wrap: wrap; margin-top: 6px; }
.icon-btn.fav { color: #eab308; }
.icon-btn.fav .filled :deep(svg) { fill: currentColor; }

.fields { gap: 10px; }
.field { gap: 2px; }
.field-name { font-size: 11px; color: var(--muted-fg); }
.field-value { padding-bottom: 4px; gap: 8px; min-height: 22px; }
.value { font-size: 14px; }
.pw-block { gap: 6px; margin: 4px 0; }
.pw-dots { font-size: 14px; letter-spacing: 1px; }
.pw-text { font-size: 14px; }
.pw-strength { max-width: 280px; }
.hairline { height: 1px; background: var(--border); }
.add-field {
  gap: 5px;
  background: none;
  border: none;
  color: var(--muted-fg);
  font-size: 11px;
  cursor: pointer;
  padding: 0;
  align-self: flex-start;
  font-family: inherit;
}
.add-field:hover { color: var(--fg); }

.section { gap: 8px; }
.section-title { font-size: 11px; font-weight: 700; color: var(--muted-fg); }
.notes { padding: 12px; white-space: pre-wrap; font-size: 13px; }
.imgs { gap: 10px; overflow-x: auto; }
.img-thumb { width: 96px; height: 96px; object-fit: cover; border-radius: 8px; }
.file-row { gap: 10px; padding: 8px; }
.file-name { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }

.footer {
  align-items: flex-end;
  gap: 3px;
  font-size: 11px;
  color: var(--muted-fg);
}
.trash-actions { gap: 8px; }

.bottom-bar {
  flex: none;
  border-top: 1px solid var(--border);
  padding: 8px 24px;
  gap: 10px;
  background: var(--bg);
}
.autofill { gap: 6px; font-size: 12px; }
</style>
