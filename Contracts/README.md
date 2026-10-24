# Contracts — 数据交换契约

本目录集中存放跨端（macOS / iOS / Safari 与 Chrome 扩展、导入导出）共享的数据契约。
契约变更是破坏性变更，须与 `SwiftPackages/Core`（模型与 XML 编解码）、
`WebExtensions/shared`（扩展侧镜像类型）同步修改。

项目当前开发版本统一记为 v1。容器格式 v2 与行级同步能力版本 2 是独立技术版本，不能用于替代产品版本号。

| 契约 | 用途 | 消费方 |
|---|---|---|
| `schemas/upw-database.schema.json` | `.upw` 数据库解密后的明文 XML 结构（JSON Schema 描述） | Core 的 `DatabaseXML`、扩展侧 `types.ts` |
| `schemas/extension-message.schema.json` | 扩展内部消息（popup ↔ background ↔ 原生 App） | WebExtensions/shared 的 `protocol.ts` |

## 加密容器（`.upw`）说明

- 明文为 XML（见 schema），外层为 `DatabaseCipher` 加密容器：magic 头 + 随机盐 +
  PBKDF2 派生密钥 + AES-GCM；容器格式细节以 `SwiftPackages/Core/DatabaseCipher.swift` 为准。
- **v2 信封加密（双密钥）**：数据库本体（`UPWDB2` magic）由随机生成的库密钥（VEK，256 位）加密；主密码通过信封（`<名>.upwkey`，`UPWKEY1` magic）保护 VEK。改主密码会轮换 VEK、重加密数据库本体并更新信封；云同步提交将本体密文、信封与同步状态作为一致事务处理。改密后旧备份仍需对应的旧密码解密。
  v2 为唯一受支持的容器格式（容器格式 v1 已下线，旧库需先用旧版应用打开迁移；这里的 v1 不代表产品开发版本）。
- 时间戳一律为 Unix epoch **毫秒**。
- 条目标识 `id` 为 **UUID v4 字符串**（行级同步的条目身份，客户端生成，
  XML 属性 `id` 直接携带 uuid 字符串）。
- 标签的 `timeStamp` 落盘为 `<label … time="…">` 属性，**仅当 >0 时写出**
  （存量库未编辑过的标签为 0、不写属性，XML 字节与历史版本一致，不扰动
  同步哈希基线）；标签合并与卡片同样走 LWW（新者胜，平局本地胜）。
- **无墓碑**：删除的卡片/标签在本地直接移除；同步层的删除事实由
  服务端条目表缺席承载（行库即权威，见 [云同步设计](../Cloud/DESIGN.md)），XML 格式
  不再有 `<ghost>` 元素。

## 扩展消息

扩展按本地优先模型工作：IndexedDB 仅保存逐条密文、信封与同步游标，并通过事务原子提交密文数据和游标；不得在 `storage.local` 或 IndexedDB 保存明文或 VEK。解锁期间的 VEK 仅保留于扩展可信的 `storage.session` 或后台进程内存；锁定、会话退出或清理会删除该密钥。账户云端授权与本地解锁相互独立：授权过期时仍可用本地信封与主密码解锁，但同步需重新登录；退出登录清除账户缓存与授权状态，不应因此把本地密文库当作已解锁。

`vault-session` 消息仅接受来自自身弹窗的请求。后台须验证发送者、账户/库绑定、期限和版本，并限制明文 `fragments` 只由 `decrypt` 请求返回给可信 popup；不得将明文 fragment 转发至网页或 content script。`vaultKey` 仅可出现在受信任的请求，不得出现在任何响应。JSON Schema 描述消息形状，不能代替运行时的 sender 与请求/响应动作校验。`context.userId` 可选。

会话 actions 包含 `decrypt` 和 `refresh`。`commit` 必须包含 32 个 0…255 字节的 `vaultKey` 与正整数 `passwordVersion`；当前协议的 `snapshotVersion` 也要求提供且为非负整数，客户端为兼容旧调用可在迁移期间省略该字段。`decrypt` 携带密文行 `rows`，每行含 `uuid`、`kind`（1=card、2=label、3=user profile）、正整数 `revision`、`bodyB64` 和 `modifiedMs`；`refresh` 携带 `expectedSnapshotVersion`、`snapshotVersion`、`passwordVersion` 及既有形状的 `items`。`replace` 可携带 `expectedSnapshotVersion` 与 `snapshotVersion` 做版本对齐。响应可包含 `fragments`、`snapshotVersion`、`passwordVersion` 及 `code`；失败时允许 `unlocked: false` 同时返回 `code`。这里的 `code` 是 vault-session 业务错误标识，不影响通用 `{type: "error", message}` 响应。只有解密响应可含明文 fragment，fragment 结构见 schema。

明文 XML 与服务端 revision 只在可信 popup 解密和处理，用于保留未知数据与执行联网 CAS 编辑。编辑继续要求重新认证且联网，版本冲突时拒绝覆盖。手动同步不再要求重复输入主密码。首次全量同步，以及 `cursorExpired` 或 rekey 后重建快照，是需要全量处理的例外；同步将密文、信封与游标按本地事务一致更新。

`site-hint` 由后台按发送页和当前页的同源校验计算，仅返回匹配数量与解锁状态；`open-vault` 请求打开插件弹窗，不自动填充。只有显式选择、匹配当前网站的条目才可填充，填充负载排除原始 XML、笔记与无关字段，内容脚本还校验自身插件弹窗来源及 `expectedOrigin`。
消息形状见 `extension-message.schema.json`，TypeScript 定义见 `WebExtensions/shared/src/messaging/protocol.ts`。

个人资料独立于 cards：本地加密库中的 userProfiles 集合以 user_profile XML 元素序列化，并参与备份、恢复和改密。行级同步使用 kind=1（card）、kind=2（label）、kind=3（user profile）。Go API 将 kind=3 的客户端密文保存于 vault_user_profiles，通过 vault_sync_items 视图统一处理快照、增量、配额和 rekey；姓名、电话、地址等值不成为 SQL 明文列。

同一库中 UUID 在两个物理条目表之间保持唯一，由库行锁串行化写入。旧个人资料卡可用相同 UUID、匹配的 baseRevision 和 kind=3 上行迁入专表：保留创建时间、计数和 UUID，revision 加一。服务端不能识别密文是否属于个人资料，由升级后的客户端明确请求迁移。其他种类变更返回 409 record_type_changed；旧客户端用过期 revision 写入则仍走 CAS conflict。删除按服务端现存种类选表，兼容旧客户端的 kind=1 删除请求。所有类型共享 purge/not_found、游标及改密规则，见 [Cloud/DATABASE.md](../Cloud/DATABASE.md)。

启用该 API 前须先应用 0002_user_profiles.sql；已提交实现与生产部署状态应分别核实。
