import { defineConfig } from "vite";
import vue from "@vitejs/plugin-vue";

// NOTE: outDir is "dist-web" — the repo root "dist/" holds the Swift .app bundle.
export default defineConfig({
  plugins: [vue()],
  clearScreen: false,
  server: {
    port: 5173,
    strictPort: true,
  },
  envPrefix: ["VITE_", "TAURI_ENV_"],
  build: {
    target: "safari15",
    outDir: "dist-web",
    minify: "esbuild",
    sourcemap: false,
  },
});
