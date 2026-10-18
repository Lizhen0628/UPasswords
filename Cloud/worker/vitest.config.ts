import { defineConfig } from "vitest/config";

// 集成测试跑在 Node 运行时(vitest workers-pool 内的 workerd 不支持
// mysql2 的 net/tls),经 UPW_TEST_DB_URL 直连 MariaDB:本地走 ssh 隧道
// (127.0.0.1:16033),CI 走 service 容器。schema 由 test/apply-schema.ts 准备。
export default defineConfig({
  test: {
    environment: "node",
    include: ["test/**/*.test.ts"],
    setupFiles: ["test/apply-schema.ts"],
    testTimeout: 90_000,
    hookTimeout: 120_000,
    fileParallelism: false,
  },
});
