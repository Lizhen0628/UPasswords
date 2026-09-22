<script setup lang="ts">
// EditCardWindowController — tabbed editor (Fields / Notes / Images / Files)
// presented as a modal over the main window, with the AddField/EditField
// sub-editor.
import { computed, ref } from "vue";
import AppIcon from "../components/AppIcon.vue";
import CardIcon from "../components/CardIcon.vue";
import PopMenu, { type MenuItem } from "../components/PopMenu.vue";
import StrengthIndicator from "../components/StrengthIndicator.vue";
import { useAppStore } from "../stores/app";
import { useSettingsStore } from "../stores/settings";
import { useToastStore } from "../stores/toast";
import { t, db } from "../lib/i18n";
import { AUTOFILLS, FIELD_TYPES, type Autofill, type Field, type FieldType, isHiddenType, newField, uuid } from "../lib/models";
import { autofillLocalizedName, fieldTypeLocalizedName } from "../lib/models";
import { TEMPLATES } from "../lib/templates";
import { generatorInstance, passwordTypeName } from "../lib/generator";
import { scorePassword } from "../lib/strength";
import { parseTotp, totpCode } from "../lib/totp";
import { colorCss } from "../lib/sidebar";
import * as backend from "../lib/backend";

const app = useAppStore();
const settings = useSettingsStore();
const toast = useToastStore();

const tab = ref<"fields" | "notes" | "images" | "files">("fields");
const TABS = [
  { key: "fields", label: t("fields_tab") },
  { key: "notes", label: t("notes_tab") },
  { key: "images", label: t("images_tab") },
  { key: "files", label: t("files_tab") },
] as const;

const draft = computed({
  get: () => app.editDraft!,
  set: (v) => (app.editDraft = v),
});
const card = computed(() => draft.value.card);

const fieldEditor = ref<{ field: Field; isNew: boolean } | null>(null);

const templateMenu = computed<MenuItem[]>(() =>
  TEMPLATES.map((spec) => ({
    label: db(spec.titleKey),
    action: () => applyTemplate(spec.id),
  })),
);

function applyTemplate(specId: number) {
  const spec = TEMPLATES.find((s) => s.id === specId);
  if (!spec) return;
  card.value.title = db(spec.titleKey);
  card.value.symbol = spec.symbol;
  card.value.autofillEnabled = spec.autofill;
  card.value.fields = spec.fields.map(
    (f): Field => ({ ...newField(db(f.nameKey)), type: f.type, autofill: f.autofill }),
  );
}

function addField() {
  fieldEditor.value = { field: newField(""), isNew: true };
}

function saveFieldEditor(field: Field) {
  const i = card.value.fields.findIndex((f) => f.id === field.id);
  if (i >= 0) card.value.fields[i] = field;
  else card.value.fields.push(field);
}

function generateFor(field: Field, type: number) {
  field.value = generatorInstance.password(settings.s.pwd.passwordLength, type, settings.s.pwd);
  generatorInstance.addPasswordToHistory(field.value);
}

function commitFieldEditor() {
  if (fieldEditor.value && fieldEditor.value.field.name) {
    saveFieldEditor(fieldEditor.value.field);
  }
  fieldEditor.value = null;
}

function fieldRowMenu(field: Field): MenuItem[] {
  const items: MenuItem[] = [
    { label: t("edit_field_title"), icon: "pencil", action: () => (fieldEditor.value = { field, isNew: false }) },
  ];
  if (field.history.length) {
    items.push({ kind: "sep" });
    for (const h of [...field.history].sort((a, b) => b.time - a.time).slice(0, 8)) {
      items.push({ label: h.value, action: () => (field.value = h.value) });
    }
  }
  items.push({ kind: "sep" }, { label: t("delete_button"), destructive: true, action: () => deleteField(field) });
  return items;
}

function deleteField(field: Field) {
  card.value.fields = card.value.fields.filter((f) => f.id !== field.id);
}

function moveField(index: number, dir: -1 | 1) {
  const fields = card.value.fields;
  const target = index + dir;
  if (target < 0 || target >= fields.length) return;
  [fields[index], fields[target]] = [fields[target], fields[index]];
}

const revealed = ref<Record<string, boolean>>({});
const otpPreview = ref<Record<string, string>>({});

async function refreshOtp(field: Field) {
  if (field.type !== "one_time_password" || !field.value) return;
  try {
    otpPreview.value[field.id] = await totpCode(parseTotp(field.value));
  } catch {
    delete otpPreview.value[field.id];
  }
}
void card.value.fields.filter((f) => f.type === "one_time_password").forEach((f) => void refreshOtp(f));

async function pickImages() {
  const files = await backend.pickFiles("image");
  for (const f of files) {
    card.value.images.push({ id: uuid(), name: f.name, data: f.data });
  }
}

async function pickFilesAttach() {
  const files = await backend.pickFiles("file");
  for (const f of files) {
    const bytes = Math.floor((f.data.length * 3) / 4);
    if (bytes > 150 * 1024) {
      toast.show(t("attach_file_error"));
      continue;
    }
    card.value.files.push({ id: uuid(), name: f.name, data: f.data });
  }
}

function fmtBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
  return `${(n / 1024 / 1024).toFixed(1)} MB`;
}
function b64bytes(b64: string): number {
  const pad = b64.endsWith("==") ? 2 : b64.endsWith("=") ? 1 : 0;
  return Math.max(0, Math.floor((b64.length * 3) / 4) - pad);
}

function saveAsTemplate() {
  app.saveAsTemplate(card.value);
  toast.show(t("template_saved_message"));
  app.editDraft = null;
}

function saveAndClose() {
  app.upsertCard(card.value);
  app.editDraft = null;
}

function cancel() {
  app.editDraft = null;
}

// pickers hosted through the sheet system target the edit draft
function openSymbolPicker() {
  app.openSheet({ kind: "selectSymbol" });
}
function openColorPicker() {
  app.openSheet({ kind: "selectColor" });
}
</script>

<template>
  <div class="modal-backdrop" @mousedown.self="cancel">
    <div class="modal edit-modal col">
      <!-- header -->
      <div class="head row">
        <button class="icon-btn" :title="t('select_symbol_command')" @click="openSymbolPicker">
          <CardIcon :symbol="card.symbol" :color="card.color" :size="44" />
        </button>
        <button class="icon-btn" :title="t('select_color_command')" @click="openColorPicker">
          <span class="color-dot" :style="{ background: colorCss(card.color) }" />
        </button>
        <input v-model="card.title" type="text" class="title-input" :placeholder="t('title_hint')" />
        <PopMenu :items="templateMenu" trigger="click">
          <button class="btn outline sm templates-btn row">
            <AppIcon name="layers" :size="12" />
            {{ db("templates_label") }}
          </button>
        </PopMenu>
        <button
          class="icon-btn"
          :class="{ fav: card.favorite }"
          :title="t('favorites_label')"
          @click="card.favorite = !card.favorite"
        >
          <AppIcon name="star" :size="14" :class="{ filled: card.favorite }" />
        </button>
      </div>
      <div class="divider" />

      <!-- tabs -->
      <div class="tabs row">
        <button
          v-for="item in TABS"
          :key="item.key"
          class="tab"
          :class="{ active: tab === item.key }"
          @click="tab = item.key"
        >{{ item.label }}</button>
      </div>

      <!-- body -->
      <div class="body grow">
        <!-- fields tab -->
        <div v-if="tab === 'fields'" class="fields col">
          <div v-for="(field, i) in card.fields" :key="field.id" class="frow row">
            <div class="row field-controls">
              <button class="icon-btn mini" title="↑" :disabled="i === 0" @click="moveField(i, -1)">
                <AppIcon name="chevron-up" :size="12" />
              </button>
              <button class="icon-btn mini" title="↓" :disabled="i === card.fields.length - 1" @click="moveField(i, 1)">
                <AppIcon name="chevron-down" :size="12" />
              </button>
            </div>
            <input v-model="field.name" type="text" class="name-input" :placeholder="t('field_name_prompt')" />

            <input
              v-if="field.type === 'one_time_password'"
              v-model="field.value"
              type="text"
              class="value-input mono"
              :placeholder="db('one_time_password_field')"
              @input="refreshOtp(field)"
            />
            <template v-else-if="isHiddenType(field.type)">
              <input
                v-model="field.value"
                :type="revealed[field.id] ? 'text' : 'password'"
                class="value-input mono"
                :placeholder="t('field_value_prompt')"
              />
              <button class="icon-btn" @click="revealed[field.id] = !revealed[field.id]">
                <AppIcon :name="revealed[field.id] ? 'eye-off' : 'eye'" :size="12" />
              </button>
            </template>
            <input v-else v-model="field.value" type="text" class="value-input" :placeholder="t('field_value_prompt')" />

            <span v-if="otpPreview[field.id]" class="otp-preview mono">{{ otpPreview[field.id] }}</span>

            <StrengthIndicator
              v-if="field.type === 'password' && field.value"
              :strength="scorePassword(field.value)"
              class="strength"
            />

            <PopMenu
              v-if="field.type === 'password'"
              :items="[0, 1, 2, 3].map((type) => ({ label: passwordTypeName(type), action: () => generateFor(field, type) }))"
              trigger="click"
            >
              <button class="icon-btn" :title="t('generate_password_title')">
                <AppIcon name="wand-sparkles" :size="13" />
              </button>
            </PopMenu>

            <PopMenu :items="fieldRowMenu(field)" trigger="click">
              <button class="icon-btn">
                <AppIcon name="ellipsis" :size="13" />
              </button>
            </PopMenu>
          </div>
          <button class="btn outline sm add-field" @click="addField">
            <AppIcon name="plus" :size="12" /> {{ t("add_field_button") }}
          </button>
        </div>

        <!-- notes tab -->
        <textarea v-else-if="tab === 'notes'" v-model="card.notes" class="notes" />

        <!-- images tab -->
        <div v-else-if="tab === 'images'" class="col images">
          <div v-if="!card.images.length" class="hint muted">{{ t("attach_image_warning") }}</div>
          <div class="img-grid">
            <div v-for="img in card.images" :key="img.id" class="img-cell col">
              <img :src="`data:image/jpeg;base64,${img.data}`" alt="" />
              <button class="btn link danger" @click="card.images = card.images.filter((x) => x.id !== img.id)">
                {{ t("delete_button") }}
              </button>
            </div>
          </div>
          <button class="btn outline sm" @click="pickImages">
            <AppIcon name="image" :size="12" /> {{ t("attach_image_button") }}
          </button>
        </div>

        <!-- files tab -->
        <div v-else class="col files">
          <div v-if="!card.files.length" class="hint muted">{{ t("attach_file_warning") }}</div>
          <div v-for="file in card.files" :key="file.id" class="file-row row shadcn-card">
            <AppIcon name="file" :size="13" />
            <span class="grow">{{ file.name }}</span>
            <span class="caption muted">{{ fmtBytes(b64bytes(file.data)) }}</span>
            <button class="icon-btn" @click="card.files = card.files.filter((x) => x.id !== file.id)">
              <AppIcon name="trash" :size="12" />
            </button>
          </div>
          <button class="btn outline sm" @click="pickFilesAttach">
            <AppIcon name="paperclip" :size="12" /> {{ t("attach_file_button") }}
          </button>
        </div>
      </div>
      <div class="divider" />

      <!-- footer -->
      <div class="footer row">
        <button v-if="!draft.isNew" class="btn ghost" @click="saveAsTemplate">
          {{ t("save_as_template_button") }}
        </button>
        <div class="grow" />
        <button class="btn outline" @click="cancel">{{ t("cancel_button") }}</button>
        <button class="btn" @click="saveAndClose">{{ t("save_and_close_button") }}</button>
      </div>
    </div>

    <!-- AddField / EditField sub-editor -->
    <div v-if="fieldEditor" class="modal-backdrop nested" @mousedown.self="fieldEditor = null">
      <div class="modal sub col" @keydown.esc="fieldEditor = null" @keydown.enter="commitFieldEditor">
        <div class="modal-title">
          {{ fieldEditor.isNew ? t("add_field_title") : t("edit_field_title") }}
        </div>
        <div class="divider" />
        <div class="modal-body col" style="gap: 10px">
          <label class="col">
            <span class="caption muted">{{ t("field_name_prompt") }}</span>
            <input v-model="fieldEditor.field.name" type="text" />
          </label>
          <label class="col">
            <span class="caption muted">{{ t("type_prompt") }}</span>
            <select v-model="fieldEditor.field.type">
              <option v-for="ft in FIELD_TYPES" :key="ft" :value="ft">{{ fieldTypeLocalizedName(ft) }}</option>
            </select>
          </label>
          <label class="col">
            <span class="caption muted">{{ t("autofill_title", "自动填充") }}</span>
            <select v-model="fieldEditor.field.autofill">
              <option v-for="af in AUTOFILLS" :key="af" :value="af">{{ autofillLocalizedName(af) }}</option>
            </select>
          </label>
        </div>
        <div class="divider" />
        <div class="modal-footer">
          <div class="grow" />
          <button class="btn outline sm" @click="fieldEditor = null">{{ t("cancel_button") }}</button>
          <button class="btn sm" :disabled="!fieldEditor.field.name" @click="commitFieldEditor">
            {{ t("ok_button") }}
          </button>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.edit-modal { min-width: 560px; width: min(720px, 92vw); height: min(520px, 88vh); }
.head { gap: 12px; padding: 12px; flex: none; }
.color-dot { width: 18px; height: 18px; border-radius: 50%; display: inline-block; border: 1px solid var(--border); }
.title-input { font-size: 16px; font-weight: 500; flex: 1; }
.templates-btn { gap: 5px; }
.icon-btn.fav { color: #eab308; }
.icon-btn.fav .filled :deep(svg) { fill: currentColor; }

.tabs { flex: none; padding: 12px 12px 0; gap: 2px; border-bottom: 1px solid var(--border); }
.tab {
  border: none;
  background: none;
  font: inherit;
  font-size: 13px;
  padding: 6px 14px;
  cursor: pointer;
  color: var(--muted-fg);
  border-bottom: 2px solid transparent;
  border-radius: 6px 6px 0 0;
}
.tab.active { color: var(--fg); border-bottom-color: var(--tint); }

.body { overflow: auto; padding: 12px; }

.fields { gap: 6px; }
.frow { gap: 8px; align-items: center; padding: 2px 0; flex-wrap: nowrap; }
.field-controls { flex: none; }
.icon-btn.mini { width: 18px; height: 18px; }
.name-input { width: 130px; flex: none; }
.value-input { flex: 1; min-width: 120px; }
.otp-preview { color: var(--tint); font-size: 12px; flex: none; }
.strength { width: 160px; flex: none; }
.add-field { align-self: flex-start; gap: 5px; display: inline-flex; align-items: center; }

.notes { flex: 1; resize: none; padding: 12px; height: 100%; }
.images, .files { gap: 12px; height: 100%; }
.hint { text-align: center; max-width: 440px; align-self: center; padding: 20px; }
.img-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(120px, 1fr)); gap: 12px; }
.img-cell { gap: 4px; align-items: center; }
.img-cell img { width: 110px; height: 110px; object-fit: cover; border-radius: 8px; }
.danger { color: var(--destructive); }
.file-row { gap: 10px; padding: 8px; }

.footer { padding: 12px; gap: 8px; flex: none; }

.modal-backdrop.nested { z-index: 120; background: rgba(0, 0, 0, 0.2); }
.sub { min-width: 380px; }
</style>
