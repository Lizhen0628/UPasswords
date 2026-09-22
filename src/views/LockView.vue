<script setup lang="ts">
// LockWindowController — Safe 锁屏 1:1:500×380 小窗,应用图标(黄圆+白盾+钥匙孔)
// 居中;「输入密码:」+ 输入框与「确定」同行 + 「显示密码」;底部 Touch ID / 选择
// 数据库 / 帮助。纹理背景来自 LockTextures(17 种程序化渐变)。
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
const fieldFocused = ref(false);
const touchIdAsked = ref(false);
const fastUnlockReady = ref(false);

onMounted(async () => {
  fieldFocused.value = true;
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
  }
}

const textStyle = () => (settings.s.lockWhiteText ? "#fff" : "var(--fg)");
</script>

<template>
  <div class="lock col" :style="{ background: textureCss(settings.s.lockTexture) }">
    <div class="grow" />
    <div class="app-icon">
      <span class="disc">
        <AppIcon name="shield-check" :size="40" :stroke-width="1.6" />
        <span class="keyhole"><span class="hole" /><span class="slot" /></span>
      </span>
    </div>

    <div class="field-block col" :class="{ shake: shake }">
      <label class="prompt" :style="{ color: textStyle() }">{{ t("enter_password_prompt") }}</label>
      <div class="row unlock-row">
        <input
          v-model="password"
          :type="showPassword ? 'text' : 'password'"
          ref="fieldFocused"
          autofocus
          :style="{ color: textStyle() }"
          @keydown.enter="unlock"
        />
        <button class="btn" @click="unlock">{{ t("ok_button") }}</button>
      </div>
      <label class="show-pw row" :style="{ color: textStyle() }">
        <input v-model="showPassword" type="checkbox" />
        <span>{{ t("show_password_button") }}</span>
      </label>
      <div v-if="error" class="error">{{ error }}</div>
    </div>

    <div class="grow" />

    <div class="bottom row">
      <button
        v-if="fastUnlockReady && settings.s.fastUnlock"
        class="plain-btn row touch-id"
        :style="{ color: textStyle() }"
        @click="app.unlockWithFastUnlock()"
      >
        <AppIcon name="fingerprint" :size="21" />
        <span>{{ t("touch_id_button") }}</span>
      </button>
      <button
        v-if="app.dbsList.length > 1"
        class="plain-btn select-db"
        :style="{ color: textStyle() }"
        @click="app.openSheet({ kind: 'selectDatabase' })"
      >
        {{ t("select_database_title") }}
      </button>
      <div class="grow" />
      <button class="plain-btn" :style="{ color: textStyle() }" @click="app.openSheet({ kind: 'about' })">
        <AppIcon name="circle-help" :size="16" />
      </button>
    </div>
    <div class="title-strip" :style="{ color: textStyle() }">{{ tBranded("app_title") }}</div>
  </div>
</template>

<style scoped>
.lock {
  height: 100%;
  padding: 0 14px 10px;
  position: relative;
}
.app-icon { display: flex; justify-content: center; margin-bottom: 38px; margin-top: 24px; }
.disc {
  width: 78px;
  height: 78px;
  border-radius: 50%;
  background: radial-gradient(circle at 50% 38%, #ffd961, #f7b82e);
  display: inline-flex;
  align-items: center;
  justify-content: center;
  color: #fff;
  position: relative;
  box-shadow: 0 4px 12px rgba(0, 0, 0, 0.25);
  margin-top: 28px;
}
.keyhole {
  position: absolute;
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 1px;
  transform: translateY(8px);
}
.hole { width: 10px; height: 10px; border-radius: 50%; background: #1c1c1e; }
.slot { width: 4.5px; height: 11px; border-radius: 2px; background: #1c1c1e; }

.field-block {
  width: 320px;
  margin: 0 auto;
  gap: 7px;
  animation-duration: 0.12s;
}
.field-block.shake { animation: shake 0.12s ease-in-out 3; }
@keyframes shake {
  0%, 100% { transform: translateX(0); }
  50% { transform: translateX(-8px); }
}
.prompt { font-size: 13px; }
.unlock-row { gap: 8px; }
.unlock-row input { flex: 1; background: rgba(255, 255, 255, 0.9); border: none; }
.show-pw { gap: 6px; font-size: 12px; }
.error { font-size: 11px; color: #ffb4ab; }

.bottom { gap: 14px; }
.plain-btn {
  background: none;
  border: none;
  padding: 0;
  font: inherit;
  font-size: 13px;
  cursor: pointer;
  opacity: 0.9;
  display: inline-flex;
  align-items: center;
}
.touch-id { gap: 7px; }
.select-db { font-size: 12px; opacity: 0.8; }
.title-strip {
  position: absolute;
  top: 0;
  left: 0;
  right: 0;
  height: 28px;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 13px;
  font-weight: 600;
  opacity: 0.75;
  -webkit-mask: linear-gradient(#000, transparent);
}
</style>
