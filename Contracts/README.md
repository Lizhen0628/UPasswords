# Contracts — 数据交换契约

本目录集中存放跨端（macOS / iOS / Safari 与 Chrome 扩展、导入导出）共享的数据契约。
契约变更是破坏性变更，须与 `SwiftPackages/Core`（模型与 XML 编解码）、
`WebExtensions/shared`（扩展侧镜像类型）同步修改。

| 契约 | 用途 | 消费方 |
|---|---|---|
| `schemas/upw-database.schema.json` | `.upw` 数据库解密后的明文 XML 结构（JSON Schema 描述） | Core 的 `DatabaseXML`、扩展侧 `types.ts` |
| `schemas/extension-message.schema.json` | 扩展内部消息（popup ↔ background ↔ 原生 App） | WebExtensions/shared 的 `protocol.ts` |

## 加密容器（`.upw`）说明

- 明文为 XML（见 schema），外层为 `DatabaseCipher` 加密容器：magic 头 + 随机盐 +
  PBKDF2 派生密钥 + AES-GCM；容器格式细节以 `SwiftPackages/Core/DatabaseCipher.swift` 为准。
- **v2 信封加密（双密钥）**：数据库本体（`UPWDB2` magic）由随机生成的「库密钥」
  （vault key, 256 位, 永不变）加密；主密码只加密 ~100 字节的信封文件
  （`<名>.upwkey`, `UPWKEY1` magic, PBKDF2 派生密钥包裹库密钥 + 改密时间戳）。
  改主密码只重写并同步信封，本体不动——改密传播零重写、无竞态窗口。
  v1 容器（`UPWDB1`, 主密码直加解密）在加载时自动迁移为 v2。
- 时间戳一律为 Unix epoch **毫秒**。
- `ghosts`（墓碑）用于会聚式同步合并：删除的卡片/标签以 `(id, time)` 记录，
  合并时抑制过期副本复活。

## 扩展消息

扩展不接触主密钥：原生 App 按来源 host 过滤后，把可填充条目推给扩展
（字段值仅在填充瞬间存在于内存）。消息形状见 `extension-message.schema.json`，
TypeScript 定义见 `WebExtensions/shared/src/messaging/protocol.ts`。
