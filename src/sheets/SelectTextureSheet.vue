<script setup lang="ts">
// SelectTextureSheetController — 17 lock-screen textures + text color.
import AppIcon from "../components/AppIcon.vue";
import SheetShell from "../components/SheetShell.vue";
import { useAppStore } from "../stores/app";
import { useSettingsStore } from "../stores/settings";
import { t } from "../lib/i18n";
import { LOCK_TEXTURE_COUNT, textureCss } from "../lib/lockTextures";

const app = useAppStore();
const settings = useSettingsStore();

function setTextWhite(white: boolean) {
  settings.s.lockWhiteText = white;
}
</script>

<template>
  <SheetShell
    :title="t('select_texture_title')"
    :min-width="520"
    @cancel="app.activeSheet = null"
    @ok="app.activeSheet = null"
  >
    <div class="col" style="gap: 10px">
      <div class="caption muted">
        {{ t("lock_screen_background_prompt") }} {{ t("lock_screen_preview_prompt") }}
      </div>
      <div class="grid">
        <button
          v-for="i in LOCK_TEXTURE_COUNT"
          :key="i"
          class="texture"
          :style="{ background: textureCss(i - 1) }"
          @click="settings.s.lockTexture = i - 1"
        >
          <AppIcon v-if="settings.s.lockTexture === i - 1" name="circle-check" :size="16" class="check" />
        </button>
      </div>
      <div class="row" style="gap: 16px">
        <label class="row" style="gap: 5px">
          <input
            type="radio"
            :checked="settings.s.lockWhiteText"
            @change="setTextWhite(true)"
          />
          {{ t("white_text_text") }}
        </label>
        <label class="row" style="gap: 5px">
          <input
            type="radio"
            :checked="!settings.s.lockWhiteText"
            @change="setTextWhite(false)"
          />
          {{ t("black_text_text") }}
        </label>
      </div>
    </div>
  </SheetShell>
</template>

<style scoped>
.grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(110px, 1fr));
  gap: 10px;
}
.texture {
  height: 64px;
  border: none;
  border-radius: 8px;
  cursor: pointer;
  display: flex;
  align-items: flex-start;
  justify-content: flex-end;
  padding: 4px;
}
.check { color: #fff; }
</style>
