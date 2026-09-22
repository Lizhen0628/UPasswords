<script setup lang="ts">
// First-run wizard — centered shadcn-style card: brand mark, step list and a
// grouped form (name / password / confirm + Touch ID) with a full-width CTA.
import { ref } from "vue";
import AppIcon from "../components/AppIcon.vue";
import { useAppStore } from "../stores/app";
import { useSettingsStore } from "../stores/settings";
import { t, tBranded } from "../lib/i18n";

const app = useAppStore();
const settings = useSettingsStore();

const name = ref("");
const password = ref("");
const confirm = ref("");
const touchID = ref(true);
const error = ref("");

async function create() {
  if (password.value.length < 4) {
    error.value = t("minimum_password_length_error");
    return;
  }
  if (password.value !== confirm.value) {
    error.value = t("passwords_do_not_match_error");
    return;
  }
  try {
    await app.createDatabase(name.value, password.value, touchID.value);
  } catch (e) {
    error.value = settings.errorText(String(e));
  }
}
</script>

<template>
  <div class="setup col">
    <div class="aurora" data-tauri-drag-region />

    <div class="center col">
      <div class="brand col">
        <div class="logo"><AppIcon name="shield-check" :size="26" :stroke-width="2" /></div>
        <div class="title">{{ t("database_setup_title") }}</div>
        <div class="subtitle muted">{{ tBranded("app_title") }}</div>
      </div>

      <div class="card shadcn-card col">
        <div class="step row">
          <span class="step-no">1</span>
          <b>{{ t("database_setup_item_1") }}</b>
        </div>

        <div class="form col">
          <div class="field col">
            <label class="form-label">{{ t("database_name_prompt") }}</label>
            <input v-model="name" type="text" placeholder="Main" />
          </div>
          <div class="field col">
            <label class="form-label">{{ t("set_password_prompt") }}</label>
            <input v-model="password" type="password" />
          </div>
          <div class="field col">
            <label class="form-label">{{ t("confirm_password_prompt") }}</label>
            <input v-model="confirm" type="password" @keydown.enter="create" />
          </div>
          <label class="row touch-id">
            <input v-model="touchID" type="checkbox" />
            <span>{{ t("touch_id_login_query") }}</span>
          </label>
          <div class="caption muted">{{ t("password_restore_warning") }}</div>
        </div>

        <div class="divider" />

        <div class="step row muted-step">
          <span class="step-no">2</span>
          <span>{{ t("database_setup_item_2") }}</span>
        </div>
        <div class="step row muted-step">
          <span class="step-no">3</span>
          <span>{{ t("database_setup_item_3") }}</span>
        </div>

        <button class="btn outline" disabled :title="t('not_configured_state')">
          <AppIcon name="cloud" :size="14" />
          {{ t("restore_from_cloud_button") }}
        </button>

        <div v-if="error" class="error row">
          <AppIcon name="triangle-alert" :size="12" />
          <span>{{ error }}</span>
        </div>

        <button class="btn continue" :disabled="!name || !password" @click="create">
          {{ t("continue_button") }}
        </button>
      </div>
    </div>
  </div>
</template>

<style scoped>
.setup {
  height: 100%;
  position: relative;
  background: var(--bg);
  overflow: hidden;
}
.aurora {
  position: absolute;
  inset: 0;
  pointer-events: none;
  background:
    radial-gradient(720px 420px at 50% -12%, color-mix(in srgb, var(--tint) 12%, transparent), transparent 65%);
}
.center {
  position: relative;
  flex: 1;
  align-items: center;
  justify-content: center;
  gap: 20px;
  padding: 24px;
  overflow-y: auto;
}

.brand { align-items: center; gap: 6px; }
.logo {
  width: 52px;
  height: 52px;
  border-radius: 15px;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  color: var(--primary-fg);
  background: linear-gradient(160deg, var(--primary), color-mix(in srgb, var(--primary) 78%, var(--tint)));
  box-shadow: var(--shadow-md), inset 0 1px 0 rgba(255, 255, 255, 0.18);
  margin-bottom: 6px;
}
.title { font-size: 18px; font-weight: 700; letter-spacing: -0.01em; }
.subtitle { font-size: 12px; }

.card {
  width: 420px;
  max-width: calc(100vw - 48px);
  padding: 20px;
  gap: 14px;
  border-radius: var(--radius-xl);
  box-shadow: var(--shadow-lg);
}

.step { gap: 10px; align-items: center; font-size: 13px; }
.step-no {
  width: 20px;
  height: 20px;
  flex: none;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  font-size: 11px;
  font-weight: 600;
  color: var(--fg-secondary);
  background: var(--accent-fill);
  border-radius: 50%;
}
.muted-step { color: var(--muted-fg); }

.form { gap: 10px; }
.field { gap: 5px; }
.form-label { font-size: 12px; font-weight: 500; color: var(--fg-secondary); }
.touch-id { gap: 8px; font-size: 12px; margin-top: 2px; }

.error {
  gap: 6px;
  font-size: 12px;
  color: var(--destructive);
  background: color-mix(in srgb, var(--destructive) 8%, transparent);
  border: 1px solid color-mix(in srgb, var(--destructive) 25%, transparent);
  border-radius: var(--radius-md);
  padding: 7px 10px;
}

.continue { width: 100%; min-height: 34px; }
</style>
