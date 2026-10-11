// 每个测试前重建 D1 schema(独立存储下保证干净起点)。

import { env } from "cloudflare:test";
import { beforeEach } from "vitest";
import schema0001 from "../migrations/0001_init.sql?raw";
import schema0002 from "../migrations/0002_vault_body.sql?raw";

async function applyRaw(raw: string): Promise<void> {
  // 先去注释再切分:注释里可能含分号(如"-- SHA-256(令牌);…")
  const statements = raw
    .replace(/--[^\n]*/g, "")
    .split(";")
    .map((statement) => statement.trim())
    .filter(Boolean);
  for (const statement of statements) {
    await env.DB.prepare(statement).run();
  }
}

beforeEach(async () => {
  // 存储不随测试自动隔离:先 DROP 再重建,保证每测试全新库
  const drops = [
    "DROP TABLE IF EXISTS audit_log",
    "DROP TABLE IF EXISTS vaults",
    "DROP TABLE IF EXISTS sessions",
    "DROP TABLE IF EXISTS email_codes",
    "DROP TABLE IF EXISTS users",
  ];
  for (const drop of drops) {
    await env.DB.prepare(drop).run();
  }
  await applyRaw(schema0001);
  await applyRaw(schema0002);
});
