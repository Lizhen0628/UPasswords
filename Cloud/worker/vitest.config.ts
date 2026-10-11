import { defineConfig } from "vitest/config";
import { cloudflareTest } from "@cloudflare/vitest-plugin";

// miniflare 本地跑 D1:每测试独立存储;schema 在 setup 中按测试重建;
// SMTP 走 mock(验证码改由确定性派生,测试可自行算出)。
export default defineConfig({
  plugins: [
    cloudflareTest({
      main: "src/index.ts",
      miniflare: {
        compatibilityDate: "2026-01-01",
        d1Databases: ["DB"],
        r2Buckets: ["VAULTS"],
        bindings: {
          APP_KEK: "11".repeat(32),
          ADMIN_TOKEN: "test-admin-token",
          SMTP_MOCK: "1",
        },
      },
    }),
  ],
  test: {
    include: ["test/**/*.test.ts"],
    setupFiles: ["test/apply-schema.ts"],
  },
});
