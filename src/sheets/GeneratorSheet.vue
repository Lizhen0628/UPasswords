<script setup lang="ts">
// PasswordOptionsSheetController — generator with options + history.
import { onMounted, ref } from "vue";
import AppIcon from "../components/AppIcon.vue";
import SheetShell from "../components/SheetShell.vue";
import LabeledRow from "../components/LabeledRow.vue";
import StrengthIndicator from "../components/StrengthIndicator.vue";
import { useAppStore } from "../stores/app";
import { useSettingsStore } from "../stores/settings";
import { t } from "../lib/i18n";
import { generatorInstance, passwordTypeName } from "../lib/generator";
import { scorePassword } from "../lib/strength";

const app = useAppStore();
const settings = useSettingsStore();
const generated = ref("");
const showOptions = ref(false);

function regenerate() {
  generated.value = generatorInstance.password(
    settings.s.pwd.passwordLength,
    settings.s.pwd.passwordType,
    settings.s.pwd,
  );
  generatorInstance.addPasswordToHistory(generated.value);
}
onMounted(regenerate);

const TYPES = [0, 1, 2, 3];
</script>

<template>
  <SheetShell
    :title="t('generate_password_title')"
    :min-width="460"
    :ok-title="t('close_button')"
    @cancel="app.activeSheet = null"
    @ok="app.activeSheet = null"
  >
    <div class="col" style="gap: 14px">
      <button class="opt-toggle row" @click="showOptions = !showOptions">
        <AppIcon name="chevron-right" :size="12" class="chev" :class="{ open: showOptions }" />
        <AppIcon name="sliders-horizontal" :size="13" />
        <span>{{ t("options_title") }}</span>
      </button>

      <div v-if="showOptions" class="col options">
        <label class="col gap4">
          <span class="caption muted">{{ t("type_prompt") }}</span>
          <select v-model.number="settings.s.pwd.passwordType">
            <option v-for="ty in TYPES" :key="ty" :value="ty">{{ passwordTypeName(ty) }}</option>
          </select>
        </label>
        <div class="row length-row">
          <span>{{ t("length_prompt") }}</span>
          <span class="muted mono">{{ settings.s.pwd.passwordLength }}</span>
          <div class="grow" />
          <input
            type="range" min="4" max="64"
            :value="settings.s.pwd.passwordLength"
            @input="settings.s.pwd.passwordLength = Number(($event.target as HTMLInputElement).value)"
          />
          <button class="btn outline sm" @click="settings.s.pwd.passwordLength = Math.max(4, settings.s.pwd.passwordLength - 1)">−</button>
          <button class="btn outline sm" @click="settings.s.pwd.passwordLength = Math.min(64, settings.s.pwd.passwordLength + 1)">+</button>
        </div>
        <LabeledRow :label="t('password_symbols_prompt')">
          <input v-model="settings.s.pwd.symbolsAlphabet" type="text" />
        </LabeledRow>
        <LabeledRow :label="t('password_separators_prompt')">
          <input v-model="settings.s.pwd.separatorAlphabet" type="text" />
        </LabeledRow>
        <label class="row" style="gap: 6px">
          <input v-model="settings.s.pwd.excludeSimilarCharacters" type="checkbox" />
          <span>{{ t("exclude_similar_characters_prompt") }}</span>
        </label>
      </div>

      <div class="generated mono selectable">{{ generated }}</div>

      <StrengthIndicator v-if="generated" :strength="scorePassword(generated)" />

      <div class="row" style="gap: 8px">
        <button class="btn outline" @click="regenerate">
          <span class="row" style="gap: 6px"><AppIcon name="refresh-cw" :size="12" />{{ t("generator_button") }}</span>
        </button>
        <div class="grow" />
        <button class="btn" :disabled="!generated" @click="app.copy(generated)">
          {{ t("copy_command") }}
        </button>
      </div>

      <template v-if="generatorInstance.history.length">
        <div class="divider" />
        <div class="col" style="gap: 4px">
          <div class="caption bold muted">{{ t("history_title") }}</div>
          <div v-for="h in generatorInstance.history.slice(0, 5)" :key="h" class="row hist-row">
            <span class="mono hist-text">{{ h }}</span>
            <div class="grow" />
            <button class="icon-btn" @click="app.copy(h)">
              <AppIcon name="copy" :size="12" />
            </button>
          </div>
          <button class="btn link caption" @click="generatorInstance.clearHistory()">
            {{ t("clear_button") }}
          </button>
        </div>
      </template>
    </div>
  </SheetShell>
</template>

<style scoped>
.opt-toggle {
  gap: 8px;
  background: none;
  border: none;
  font: inherit;
  font-weight: 600;
  color: var(--fg);
  cursor: pointer;
  padding: 0;
}
.chev { transition: transform 0.15s; }
.chev.open { transform: rotate(90deg); }
.options { gap: 10px; border-left: 1px solid var(--border); padding-left: 12px; margin-left: 6px; }
.gap4 { gap: 4px; }
.length-row { gap: 10px; }
.length-row input[type="range"] { flex: 1; }
.generated {
  font-size: 20px;
  text-align: center;
  word-break: break-all;
  padding: 8px;
}
.hist-row { gap: 8px; }
.hist-text {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  font-size: 13px;
}
.bold { font-weight: 700; }
</style>
