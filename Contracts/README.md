# Contracts — 数据交换契约

本目录集中存放跨端（macOS / iOS / Safari 与 Chrome 扩展、导入导出）共享的数据契约。
契约变更是破坏性变更，须与 `SwiftPackages/Core`（模型与 XML 编解码）、
`WebExtensions/shared`（扩展侧镜像类型）同步修改。

项目当前开发版本统一记为 v1。容器格式 v2、行级同步协议 5 与 API 路径 `/v1` 是独立技术版本，不能互相替代。

> 本文描述当前已实现的契约。下文服务端缺少持久删除证据、扩展退出清缓存及联网编辑等现有行为，
> 不代表已满足 [v1 目标规则](../DECISIONS.md)。开发前交叉问题见
> [一致性审查](../DECISIONS_REVIEW.md)；新协议须联动模型、Swift/TS 实现和 schema，不能仅修改本文视作已交付。

| 契约 | 用途 | 消费方 |
|---|---|---|
| `schemas/upw-database.schema.json` | `.upw` 数据库解密后的明文 XML 结构（JSON Schema 描述） | Core 的 `DatabaseXML`、扩展侧 `types.ts` |
| `schemas/extension-message.schema.json` | 扩展内部消息（popup ↔ background ↔ 原生 App） | WebExtensions/shared 的 `protocol.ts` |
| `schemas/conflicts.schema.json` | 云端未决冲突与加密候选列表响应 | Go API；原生 `RelayClient` |
| `schemas/conflict-resolution.schema.json` | 云端冲突裁决请求体 | Go API；macOS/iOS 与四种浏览器扩展均提交完整候选集及所选附件版本 |
| `schemas/conflict-resolution-change.schema.json` | 增量同步中的原子裁决事件 | Go API；原生 `RelayClient` 与 `RowSync` |

## 加密容器（`.upw`）说明

- 明文为 XML（见 schema），外层为 `DatabaseCipher` 加密容器：magic 头 + 随机盐 +
  PBKDF2 派生密钥 + AES-GCM；容器格式细节以 `SwiftPackages/Core/DatabaseCipher.swift` 为准。
- **v2 信封加密（双密钥）**：数据库本体（`UPWDB2` magic）由随机生成的库密钥（VEK，256 位）加密；主密码通过信封（`<名>.upwkey`，`UPWKEY1` magic）保护 VEK。改主密码会轮换 VEK、重加密数据库本体并更新信封；云同步提交将本体密文、信封与同步状态作为一致事务处理。改密后旧备份仍需对应的旧密码解密。
  v2 为唯一受支持的容器格式（容器格式 v1 已下线，旧库需先用旧版应用打开迁移；这里的 v1 不代表产品开发版本）。
- 时间戳一律为 Unix epoch **毫秒**。
- 条目标识 `id` 为 **UUID v4 字符串**（行级同步的条目身份，客户端生成，
  XML 属性 `id` 直接携带 uuid 字符串）。
- 新建字段与附件也在 XML 元素上写入规范 UUID `id`；扩展读取字段 ID。
  旧 XML 缺少子项 ID 时继续解码，但只在内存中生成 UI 用临时 ID，序列化时仍省略该 ID。
  已存在的子项 ID 必须是有效 UUID；字段 ID 在同一条目内不可重复，附件 ID 在同一条目内
  （图片和文件合并检查）不可重复。
  ID 持久化只是身份契约，不代表两端已有共同基线；只有共同基线可信且身份可确认时，
  才能对互不重叠的子项修改做自动三方合并。
- 标签的 `timeStamp` 落盘为 `<label … time="…">` 属性，**仅当 >0 时写出**
  （存量库未编辑过的标签为 0、不写属性，XML 字节与历史版本一致，不扰动
  同步哈希基线）。原生同步现在按内容摘要发现修改，分歧保留并暂停，不再以时间决定覆盖。
- **本地 XML 无墓碑**：删除的卡片/标签在本地直接移除，XML 没有 `<ghost>` 元素。
  服务端开发协议以独立 `item_tombstones` 保留长期删除证据；旧日志迁移只能回填仍保留的事件。
  直接丢弃本机未同步内容。整页结构异常或尚未能裁决的分歧会保护性暂停；正确密码版本下的单条
  解密/格式异常由原生端以 VEK 加密隔离，并与游标及数据库快照原子提交后继续同步；四种浏览器扩展也已使用 VEK 和隔离专用认证数据加密保存异常行，并与本地密文快照、游标原子提交，设置页提供重试。
  超期人工恢复按“先备份，再采用云端快照”执行；生产跨端验收仍未完成，见 [云同步设计](../Cloud/DESIGN.md)。

## 云端冲突候选（开发中）

原生客户端只在同字段等无法由共同基线安全三方合并时登记候选；互不重叠字段仍由客户端
合并并按当前 revision 重试。`GET /v1/vaults/{vaultId}/conflicts` 读取未解决候选集；
`POST /v1/vaults/{vaultId}/items/{uuid}/conflicts` 以当前条目 revision 或持久删除序号
作 CAS，登记本地密文及服务端当前版本。upsert 的 `bodyB64` 始终是 VEK 加密密文。

客户端以 VEK 为 HMAC-SHA256 密钥，对带版本域、条目 UUID、baseRevision、kind、操作和
候选明文的上下文生成 `candidateFingerprint`；`candidateId` 是其前 16 字节的十六进制值。
此 keyed fingerprint 用于跨 AES-GCM 随机 nonce 重试的幂等判定，不是普通明文哈希；服务端
只保存 fingerprint 与密文，不持有 VEK。它依赖已认证客户端诚实构造，不用于验证候选明文。

列表项包含来源设备名、平台、服务端提交时间、候选操作/revision 与密文；候选集的
`generation` 为裁决 CAS 令牌。服务端开发 API 已提供原子行级裁决：
`POST /v1/vaults/{vaultId}/conflicts/{conflictId}/resolve` 必须提交完整
`candidateIds`、`generation`、`expectedCurrentRevision` 和 `expectedDeletedSeq`，
服务端在事务中比较它们并确认当前条目 revision 或持久删除序号未变化。活动条目选择
upsert 时使用服务端已存候选密文；删除冲突恢复 upsert 时必须提交新的 `restoreItemUuid`
和为该 UUID 重新加密的 `bodyB64`。服务端不会解密或验证该密文。选择 delete 不复活原身份。

成功裁决只追加一条 `op=resolve` 变更事件。事件 `uuid` 标识被裁决的原条目，
`resolvedItemUuid` 标识最终活动条目；删除结果不含该字段。`revision` 是原身份的最终
revision，`resolvedRevision` 是最终活动身份的 revision。删除后恢复会在同一事务更新旧身份墓碑
的游标序号，并发布新 UUID 下重加密后的密文，客户端据此原子收敛旧、新身份。事件字段见
[`schemas/conflict-resolution-change.schema.json`](schemas/conflict-resolution-change.schema.json)。

备份通过独立只读接口 `GET /v1/vaults/{vaultId}/conflict-history` 获取已裁决且仍在保留期内的
全部候选，包括最终选中候选。接口按最多 100 条候选分页；客户端应固定分页期间的
`snapshotMs` 和 `totalCandidates`，并完整读取到 `nextCursor: null` 后才能确认历史范围。
游标绑定库 ID 和服务端快照，过期或保留集合变化时须重新采集；页面响应见
[`schemas/conflict-history.schema.json`](schemas/conflict-history.schema.json)。该只读历史不属于
实时冲突列表，也不得重新登记为待裁决冲突。

成功裁决后，未选候选保留 30 天，到期由维护任务删除；未解决候选不自动过期。持久删除证据
保存在 `item_tombstones`，不会随 `item_changes` 日志一起清理。普通 upsert 不能复用已删除
UUID。候选登记/列表、原生候选登记与裁决事件消费、服务端行级裁决 API 已部署；
macOS/iOS 与四种浏览器扩展均可查看并选择完整候选；候选均可解密、字段 UUID 可靠且无附件时，也可按字段和整段备注
组合。浏览器验证候选摘要并以完整候选集 CAS 提交合成密文；删除后恢复会以新 UUID/AAD 重新加密。完整候选裁决会连同所选卡片的附件版本清单原子激活；恢复到新条目身份时，服务端在同一事务中迁移所选附件版本归属。字段组合仍拒绝含附件候选。macOS/iOS 与四种浏览器扩展均可把活动候选及其附件另存为新条目；扩展先复制并重新加密附件、复核候选集，结果不确定时禁止重复提交。永久损坏候选在 macOS/iOS 以 VEK 独立加密隔离并可重试；四种扩展可导出保护备份，保留原始候选密文并标记不完整。扩展也支持普通同步行的损坏隔离和重试；iOS AutoFill 会按条目阻止存在待裁决标记的凭据；浏览器端已在实际填充前按稳定字段 ID 门控已知冲突 token，删除、不可解密或身份不可靠时按条目阻止，清单不可取得时 fail-closed，并仅持久化账户/库范围的不含秘密状态。协议 5 和裁决服务已部署，旧协议客户端由门控拒绝同步；新客户端正式分发与混合版本验收尚未完成。
原生端改密会重新加密所有可读候选并更新候选指纹；候选不可解密或清单变化时整笔改密中止。候选附件引用事务已接入；永久损坏候选由原生端独立加密隔离，扩展端可导出保护备份。游标过期触发保护性暂停时，macOS/iOS 同步设置会提示本机数据已保留，并提供“先备份，再采用云端快照”的人工恢复。

生产已部署数据库迁移 `0001`–`0010` 和同步协议 5。同步数据 API 强制要求
`X-UPW-Sync-Protocol: 5`；缺失或旧版本会在读取条目快照/变更事件及执行写入前得到 HTTP 426
和 `client_upgrade_required`。账户认证与库目录路由不受门控影响。协议 5 的卡片 upsert 必须携带完整的
`attachmentRefs` 数组，空卡片也必须显式发送空数组。Swift 与浏览器扩展共享客户端现已声明协议 5，
并能校验和消费原子 `op=resolve` 事件；四种扩展的本地候选查看/裁决界面也已接入，支持范围和限制见上文。
扩展本地构建与测试已通过；新客户端正式分发及混合版本验收仍待完成。隔离 Go/MariaDB
集成测试、race 检查和 vet 已通过。旧版原生客户端会把 `op=resolve` 当作普通 upsert 处理；
删除后恢复为新 UUID 的事件无法被旧客户端正确应用，且旧端仍可能按时间戳重试并覆盖已选结果。
因此服务端已启用升级门控；正式分发前仍须完成 macOS/iOS 与服务端之间的新旧版本混合测试，
并验证浏览器扩展升级对同步可用性的影响。旧客户端不能继续同步。
变更事件默认保留 90 天；游标过期时，有本地待同步修改或待裁决标记的原生端会保护性阻止全量重建，
并在 macOS/iOS 同步设置提供“先备份，再采用云端快照”的恢复入口；备份保留用于比较、另存或恢复。

## 扩展消息

扩展按本地优先模型工作：IndexedDB 保存逐条密文、云端对齐的附件版本元数据、已验证附件对象密文、信封与同步游标，并通过事务原子提交密文数据和游标；不得在 `storage.local` 或 IndexedDB 保存明文或 VEK。解锁期间的 VEK 仅保留于扩展可信的 `storage.session` 或后台进程内存；锁定、会话退出或清理会删除该密钥。账户云端授权与本地解锁相互独立：授权过期时仍可用本地信封与主密码解锁，但同步需重新登录；普通退出登录撤销授权并保留账户密文快照及附件策略，账户 epoch 原子迁移以阻止迟到任务复写；同账户重新登录后仍须重新解锁，不应将保留的本地密文库当作已解锁。

`vault-session` 消息仅接受来自自身弹窗的请求。后台须验证发送者、账户/库绑定、期限和版本，并限制明文 `fragments` 只由 `decrypt` 请求返回给可信 popup；不得将明文 fragment 转发至网页或 content script。`vaultKey` 仅可出现在受信任的请求，不得出现在任何响应。JSON Schema 描述消息形状，不能代替运行时的 sender 与请求/响应动作校验。`context.userId` 可选。

会话 actions 包含 `decrypt` 和 `refresh`。`commit` 必须包含 32 个 0…255 字节的 `vaultKey` 与正整数 `passwordVersion`；当前协议的 `snapshotVersion` 也要求提供且为非负整数，客户端为兼容旧调用可在迁移期间省略该字段。`decrypt` 携带密文行 `rows`，每行含 `uuid`、`kind`（1=card、2=label、3=user profile）、正整数 `revision`、`bodyB64` 和 `modifiedMs`；`refresh` 携带 `expectedSnapshotVersion`、`snapshotVersion`、`passwordVersion` 及既有形状的 `items`。`replace` 可携带 `expectedSnapshotVersion` 与 `snapshotVersion` 做版本对齐。响应可包含 `fragments`、`snapshotVersion`、`passwordVersion` 及 `code`；失败时允许 `unlocked: false` 同时返回 `code`。这里的 `code` 是 vault-session 业务错误标识，不影响通用 `{type: "error", message}` 响应。只有解密响应可含明文 fragment，fragment 结构见 schema。

明文 XML 与服务端 revision 只在可信 popup 解密和处理，用于保留未知数据与执行联网 CAS 编辑。编辑继续要求重新认证且联网，版本冲突时拒绝覆盖。手动同步不再要求重复输入主密码。首次全量同步，以及 `cursorExpired` 或 rekey 后重建快照，是需要全量处理的例外；同步将密文、信封与游标按本地事务一致更新。

`site-hint` 由后台按发送页和当前页的同源校验计算，仅返回匹配数量与解锁状态；`open-vault` 请求打开插件弹窗，不自动填充。只有显式选择、匹配当前网站的条目才可填充，填充负载排除原始 XML、笔记与无关字段，内容脚本还校验自身插件弹窗来源及 `expectedOrigin`。
消息形状见 `extension-message.schema.json`，TypeScript 定义见 `WebExtensions/shared/src/messaging/protocol.ts`。

个人资料独立于 cards：本地加密库中的 userProfiles 集合以 user_profile XML 元素序列化，并参与备份、恢复和改密。行级同步使用 kind=1（card）、kind=2（label）、kind=3（user profile）。Go API 将 kind=3 的客户端密文保存于 vault_user_profiles，通过 vault_sync_items 视图统一处理快照、增量、配额和 rekey；姓名、电话、地址等值不成为 SQL 明文列。

同一库中 UUID 在两个物理条目表之间保持唯一，由库行锁串行化写入。旧个人资料卡可用相同 UUID、匹配的 baseRevision 和 kind=3 上行迁入专表：保留创建时间、计数和 UUID，revision 加一。服务端不能识别密文是否属于个人资料，由升级后的客户端明确请求迁移。其他种类变更返回 409 record_type_changed；旧客户端用过期 revision 写入则仍走 CAS conflict。删除按服务端现存种类选表，兼容旧客户端的 kind=1 删除请求。所有类型共享 purge/not_found、游标及改密规则，见 [Cloud/DATABASE.md](../Cloud/DATABASE.md)。

启用该 API 前须先应用 0002_user_profiles.sql；已提交实现与生产部署状态应分别核实。

## 便携式自包含备份归档

`.upwbackup` 可表示原生备份目录，也可表示单文件、未压缩的 USTAR 归档。归档只封装备份包文件，
不增加第二层加密；密码、快照、附件与冲突候选仍按备份包格式加密，`Info.json` 仅含非敏感索引。
目录包和单文件归档使用相同相对路径：

- 必需根文件：`Info.json`、`Manifest.sealed`、`Snapshot.upw`、`Snapshot.upwkey`
- 可选附件密文：`Attachments/<attachment-uuid>-<content-version-uuid>.cipher`
- 可选冲突候选密文：`Conflicts/<32-lowercase-hex-conflict-id>/<32-lowercase-hex-candidate-id>.cipher`

归档成员只能是普通文件；不允许目录成员、链接、设备文件、绝对路径、`..`、反斜线、非 ASCII 路径、
重复路径或白名单之外的文件。使用 512 字节 USTAR 头块及头校验和，文件类型为普通文件，归档以两个
全零块结束；读取端须验证完整归档后才能解密或恢复，不能只凭索引头认定载荷可信。路径组件及 UUID
的大小写、连字符和长度必须符合以上写法。原生备份目录格式继续受支持。
