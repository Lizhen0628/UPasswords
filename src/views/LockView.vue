<script setup lang="ts">
// Lock screen — centered shadcn-style auth card floating on a soft brand
// gradient (or the user's chosen lock texture). Password input with inline
// reveal toggle, full-width unlock action, Touch ID secondary action.
import { onMounted, ref } from "vue";
import AppIcon from "../components/AppIcon.vue";
import { useAppStore } from "../stores/app";
import { useSettingsStore } from "../stores/settings";
import { textureCss } from "../lib/lockTextures";
import { t, tBranded } from "../lib/i18n";

const app = useAppStore();
const settings = useSettingsStore();

const password = ref("");
const showPassword = ref(false);
const error = ref("");
const shake = ref(false);
const field = ref<HTMLInputElement | null>(null);
const touchIdAsked = ref(false);
const fastUnlockReady = ref(false);

onMounted(async () => {
  field.value?.focus();
  try {
    const { fastUnlockAvailable } = await import("../lib/backend");
    fastUnlockReady.value = await fastUnlockAvailable(app.databaseName);
  } catch {
    fastUnlockReady.value = false;
  }
  if (!touchIdAsked.value && fastUnlockReady.value && settings.s.fastUnlock) {
    touchIdAsked.value = true;
    setTimeout(() => void app.unlockWithFastUnlock(), 400);
  }
});

async function unlock() {
  try {
    await app.unlock(app.databaseName, password.value);
    password.value = "";
    error.value = "";
  } catch (e) {
    error.value = settings.errorText(String(e));
    app.registerFailedAttempt();
    shake.value = !shake.value;
    password.value = "";
    field.value?.focus();
  }
}
</script>

<template>
  <div
    class="lock col"
    :style="{ background: textureCss(settings.s.lockTexture) }"
  >
    <div class="aurora" data-tauri-drag-region />

    <div class="center col">
      <div class="lock-card col" :class="{ shake: shake }">
        <div class="logo">
          <AppIcon name="shield-check" :size="26" :stroke-width="2" />
        </div>

        <div class="headline col">
          <span class="app-name">{{ tBranded("app_title") }}</span>
          <span class="db-name muted">{{ app.databaseName }}</span>
        </div>

        <div class="form col">
          <label class="form-label">{{ t("enter_password_prompt") }}</label>
          <div class="pw-group shadcn-field row">
            <AppIcon name="lock" :size="14" class="muted pw-icon" />
            <input
              ref="field"
              v-model="password"
              class="plain"
              :type="showPassword ? 'text' : 'password'"
              autocomplete="off"
              @keydown.enter="unlock"
            />
            <button
              class="icon-btn eye"
              :title="t('show_password_button')"
              @click="showPassword = !showPassword"
            >
              <AppIcon :name="showPassword ? 'eye-off' : 'eye'" :size="14" />
            </button>
          </div>

          <div v-if="error" class="error row">
            <AppIcon name="triangle-alert" :size="12" />
            <span>{{ error }}</span>
          </div>

          <button class="btn unlock" :disabled="!password" @click="unlock">
            {{ t("ok_button") }}
          </button>

          <button
            v-if="fastUnlockReady && settings.s.fastUnlock"
            class="btn outline touch-id"
            @click="app.unlockWithFastUnlock()"
          >
            <AppIcon name="fingerprint" :size="15" />
            <span>{{ t("touch_id_button") }}</span>
          </button>
        </div>
      </div>

      <div class="below row">
        <button
          v-if="app.dbsList.length > 1"
          class="ghost-link"
          @click="app.openSheet({ kind: 'selectDatabase' })"
        >
          {{ t("select_database_title") }}
        </button>
        <button
          class="ghost-link icon"
          :title="tBranded('app_title')"
          @click="app.openSheet({ kind: 'about' })"
        >
          <AppIcon name="circle-help" :size="14" />
        </button>
      </div>
    </div>
  </div>
</template>

<style scoped>
.lock {
  height: 100%;
  position: relative;
  background: var(--bg);
  overflow: hidden;
}

/* soft brand glow behind the card (visible on the default background) */
.aurora {
  position: absolute;
  inset: 0;
  pointer-events: none;
  background:
    radial-gradient(720px 420px at 50% -12%, color-mix(in srgb, var(--tint) 14%, transparent), transparent 65%),
    radial-gradient(520px 380px at 88% 112%, color-mix(in srgb, var(--tint) 8%, transparent), transparent 60%);
}

.center {
  position: relative;
  flex: 1;
  align-items: center;
  justify-content: center;
  gap: 14px;
  padding: 24px;
}

.lock-card {
  width: 340px;
  padding: 28px 24px 24px;
  gap: 18px;
  align-items: stretch;
  background: color-mix(in srgb, var(--popover) 88%, transparent);
  backdrop-filter: blur(18px);
  border: 1px solid var(--border);
  border-radius: var(--radius-xl);
  box-shadow: var(--shadow-xl);
}
.lock-card.shake { animation: shake 0.4s ease; }
@keyframes shake {
  0%, 100% { transform: translateX(0); }
  20% { transform: translateX(-7px); }
  40% { transform: translateX(6px); }
  60% { transform: translateX(-4px); }
  80% { transform: translateX(3px); }
}

.logo {
  width: 52px;
  height: 52px;
  align-self: center;
  border-radius: 15px;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  color: var(--primary-fg);
  background: linear-gradient(160deg, var(--primary), color-mix(in srgb, var(--primary) 78%, var(--tint)));
  box-shadow: var(--shadow-md), inset 0 1px 0 rgba(255, 255, 255, 0.18);
}

.headline { align-items: center; gap: 3px; margin-top: -6px; }
.app-name { font-size: 16px; font-weight: 600; letter-spacing: -0.01em; }
.db-name { font-size: 12px; }

.form { gap: 12px; }
.form-label { font-size: 12px; font-weight: 500; color: var(--fg-secondary); }

.pw-group {
  gap: 8px;
  padding: 0 6px 0 10px;
  height: 36px;
}
.pw-icon { flex: none; }
.pw-group input { min-height: auto; height: 100%; }
.pw-group .eye { width: 26px; height: 26px; }

.error {
  gap: 6px;
  font-size: 12px;
  color: var(--destructive);
  background: color-mix(in srgb, var(--destructive) 8%, transparent);
  border: 1px solid color-mix(in srgb, var(--destructive) 25%, transparent);
  border-radius: var(--radius-md);
  padding: 7px 10px;
}

.unlock { width: 100%; min-height: 36px; font-size: 13px; }
.touch-id { width: 100%; min-height: 34px; }

.below { gap: 14px; }
.ghost-link {
  background: none;
  border: none;
  padding: 4px 8px;
  font: inherit;
  font-size: 12px;
  color: var(--muted-fg);
  cursor: pointer;
  border-radius: var(--radius-sm);
  display: inline-flex;
  align-items: center;
}
.ghost-link:hover { color: var(--fg); background: var(--accent-fill); }
</style>
