// vitest setupFile:测试库准备。CI(UPW_TEST_DB_ADMIN_URL 提供 root 直连)先
// 建库建号并应用 DDL;本地/CI 都会把全部表清空,保证每个测试文件从零开始。

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { createPool, type Pool } from "mysql2/promise";

const here = dirname(fileURLToPath(import.meta.url));

export const TEST_DB_NAME = "upasswords_test";

export function testDbUrl(): string {
  const url = process.env.UPW_TEST_DB_URL;
  if (!url) {
    throw new Error(
      "UPW_TEST_DB_URL is required (local: ssh tunnel 127.0.0.1:16033; CI: service container)",
    );
  }
  return url;
}

/// FK 安全顺序清空全部表(测试数据隔离;TRUNCATE 需 DROP 权限,应用账号没有)。
export const TABLES_IN_ORDER = [
  "rekey_staging",
  "rekeys",
  "attachments",
  "item_changes",
  "vault_items",
  "sessions",
  "email_codes",
  "audit_log",
  "website_domains",
  "websites",
  "vaults",
  "users",
];

async function applySchema(adminPool: Pool): Promise<void> {
  const sql = readFileSync(join(here, "..", "sql", "0001_init.sql"), "utf8");
  await adminPool.query(
    `CREATE DATABASE IF NOT EXISTS ${TEST_DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci`,
  );
  // CI 即弃容器:现场建应用账号(口令来自 UPW_TEST_DB_URL;不设 REQUIRE SSL)
  const testUrl = testDbUrl();
  const user = new URL(testUrl).username;
  const password = decodeURIComponent(new URL(testUrl).password || "");
  await adminPool.query(`CREATE USER IF NOT EXISTS '${user}'@'%' IDENTIFIED BY '${password}'`);
  await adminPool.query(`GRANT SELECT, INSERT, UPDATE, DELETE ON ${TEST_DB_NAME}.* TO '${user}'@'%'`);
  await adminPool.query(`USE ${TEST_DB_NAME}`);
  for (const statement of sql.split(";\n")) {
    const trimmed = statement.trim();
    if (trimmed) await adminPool.query(trimmed);
  }
}

async function main(): Promise<void> {
  // upw_app 账号 REQUIRE SSL:本地隧道直连也须启用 TLS(自签不校验)
  const ssl = process.env.UPW_TEST_DB_SSL === "1" ? { ssl: { rejectUnauthorized: false } } : {};
  const adminUrl = process.env.UPW_TEST_DB_ADMIN_URL;
  if (adminUrl) {
    const adminPool = createPool({ uri: adminUrl, multipleStatements: false });
    await applySchema(adminPool);
    await adminPool.end();
  }
  const pool = createPool({ uri: testDbUrl(), multipleStatements: false, ...ssl });
  for (const table of TABLES_IN_ORDER) {
    await pool.query(`DELETE FROM ${table}`);
  }
  await pool.end();
}

await main();
