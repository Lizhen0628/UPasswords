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
  v2 为唯一受支持的容器格式（v1 已下线，旧库需先用旧版应用打开迁移）。
- 时间戳一律为 Unix epoch **毫秒**。
- 条目标识 `id` 为 **UUID v4 字符串**（v7 行级同步的条目身份，客户端生成，
  XML 属性 `id` 直接携带 uuid 字符串）。
- 标签的 `timeStamp` 落盘为 `<label … time="…">` 属性，**仅当 >0 时写出**
  （存量库未编辑过的标签为 0、不写属性，XML 字节与历史版本一致，不扰动
  同步哈希基线）；标签合并与卡片同样走 LWW（新者胜，平局本地胜）。
- **无墓碑（v7）**：删除的卡片/标签在本地直接移除；同步层的删除事实由
  服务端条目表缺席承载（行库即权威，见 Cloud/DESIGN.md §6.6），XML 格式
  不再有 `<ghost>` 元素。

## 扩展消息

扩展不接触主密钥：原生 App 按来源 host 过滤后，把可填充条目推给扩展
（字段值仅在填充瞬间存在于内存）。消息形状见 `extension-message.schema.json`，
TypeScript 定义见 `WebExtensions/shared/src/messaging/protocol.ts`。
