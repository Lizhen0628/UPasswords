<script setup lang="ts">
// SheetHost — renders the active sheet over whatever phase is showing
// (mirrors SheetFactory.view(for:) in Views/DataSheets.swift).
import { computed, defineAsyncComponent } from "vue";
import { useAppStore } from "../stores/app";

const app = useAppStore();

const MAP: Record<string, ReturnType<typeof defineAsyncComponent>> = {
  addCard: defineAsyncComponent(() => import("./AddCardSheet.vue")),
  addNote: defineAsyncComponent(() => import("./AddNoteSheet.vue")),
  addLabel: defineAsyncComponent(() => import("./AddLabelSheet.vue")),
  editCardLabel: defineAsyncComponent(() => import("./EditLabelSheet.vue")),
  selectColorCardLabel: defineAsyncComponent(() => import("./SelectColorLabelSheet.vue")),
  sorting: defineAsyncComponent(() => import("./SortingSheet.vue")),
  generator: defineAsyncComponent(() => import("./GeneratorSheet.vue")),
  labels: defineAsyncComponent(() => import("./SetLabelsSheet.vue")),
  selectSymbol: defineAsyncComponent(() => import("./SelectSymbolSheet.vue")),
  selectColor: defineAsyncComponent(() => import("./SelectColorSheet.vue")),
  selectTexture: defineAsyncComponent(() => import("./SelectTextureSheet.vue")),
  exportAs: defineAsyncComponent(() => import("./ExportSheet.vue")),
  importData: defineAsyncComponent(() => import("./ImportSheet.vue")),
  databaseInfo: defineAsyncComponent(() => import("./DatabaseInfoSheet.vue")),
  compromised: defineAsyncComponent(() => import("./CompromisedSheet.vue")),
  changePassword: defineAsyncComponent(() => import("./ChangePasswordSheet.vue")),
  configureCloud: defineAsyncComponent(() => import("./ConfigureCloudSheet.vue")),
  eraseData: defineAsyncComponent(() => import("./EraseDataSheet.vue")),
  manageDatabases: defineAsyncComponent(() => import("./ManageDatabasesSheet.vue")),
  selectDatabase: defineAsyncComponent(() => import("./SelectDatabaseSheet.vue")),
  preferences: defineAsyncComponent(() => import("./PreferencesModal.vue")),
  about: defineAsyncComponent(() => import("./AboutSheet.vue")),
  whatsNew: defineAsyncComponent(() => import("./WhatsNewSheet.vue")),
  premium: defineAsyncComponent(() => import("./PremiumSheet.vue")),
  setupPlan: defineAsyncComponent(() => import("./SetupPlanSheet.vue")),
  expiredCards: defineAsyncComponent(() => import("./ExpiredCardsSheet.vue")),
  restoreTemplates: defineAsyncComponent(() => import("./RestoreTemplatesSheet.vue")),
  passwordHistory: defineAsyncComponent(() => import("./PasswordHistorySheet.vue")),
};

const comp = computed(() => (app.activeSheet ? MAP[app.activeSheet.kind] : null));
</script>

<template>
  <div v-if="app.activeSheet && comp" class="modal-backdrop" @mousedown.self="app.activeSheet = null">
    <component :is="comp" :sheet="app.activeSheet" />
  </div>
</template>
