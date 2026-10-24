# UPasswords 维护导航

本文说明当前 v1 工作树的代码阅读入口、状态边界和变更检查方法。具体行为以实现和测试为准；开发约束见 [AGENTS.md](AGENTS.md)，功能状态见 [FEATURES.md](FEATURES.md)。

## 按问题定位代码

| 维护事项 | 主要入口 | 阅读时需要关注的边界 |
|---|---|---|
| macOS 启动、解锁、保存和自动锁定 | `Apple/macOS/Sources/UPasswords/App/AppContext.swift` | 主 actor 会话、解锁阶段、库密钥和延迟保存 |
| macOS 卡片、标签、历史和选择状态 | 同目录 `AppContext+Actions.swift`、`AppContext+CardList.swift` | 值副本提交、修改时间、保存安排及列表身份 |
| macOS 同步、改密和本地快照提交 | 同目录 `AppContext+Sync.swift` | await 后会话检查、同步副本和持久化失败处理 |
| iOS 会话与同步 | `Apple/iOS/Services/Vault.swift`、`Vault+Sync.swift` | App Group 根目录、锁定代次、前后台与异步结果提交 |
| iOS 自动填充 | `Apple/iOS/AutoFill/`、`Apple/Shared/SharedVaultStore.swift` | 独立扩展进程、共享存储和系统凭据接口 |
| 领域模型、XML 与同步条目 | `SwiftPackages/Core/Sources/UPasswordsCore/` 下的 `CoreModels.swift`、`DatabaseXML.swift`、`DatabaseItem.swift`、`UserProfile.swift` | 身份、时间单位、XML 持久化字段和整条目合并 |
| 本地容器及信封格式 | Core 下的 `DatabaseCipher.swift` | 本体密钥与主密码的区别、迭代上下限及字节布局 |
| 文件保存、恢复及事务恢复 | `SwiftPackages/Persistence/Sources/UPasswordsPersistence/DatabaseStore.swift` | 本体、信封、同步 sidecar 的配套关系 |
| 云端 API 与同步引擎 | Persistence 下的 `RelayClient.swift`、`RowSync.swift`、`RelaySync.swift` | 请求契约、CAS、游标、密钥轮换和账户绑定 |
| 导入导出 | Persistence 下的 `Import/` | 格式探测不等于成功解析，导入工作副本由会话层提交 |
| 密码泄露检查 | `SwiftPackages/Networking/Sources/UPasswordsNetworking/CompromisedService.swift` | SHA-1 前缀请求、完整散列的本地匹配和失败结果 |
| 浏览器账户、密文缓存与解锁态 | `WebExtensions/shared/src/storage/` | 持久化密文与受限会话明文、CAS 版本、账户失效代次 |
| 浏览器增量同步与编辑 | `WebExtensions/shared/src/sync/vault-sync.ts`、`core/item-editor.ts` | 先校验再提交、密码版本与会话 generation |
| 浏览器入口与平台差异 | `WebExtensions/{safari,chrome,edge,firefox}/src/`、`shared/src/platform/` | background/content/popup 的权限和消息来源 |
| 云端事务与路由 | `service-admin:~/UPasswords/Cloud/api/internal/api/` | Go 生产运行时、账户归属、库锁、SQL 提交和对象清理 |
| 云端 schema 与迁移 | `Cloud/database/` | 初始化基线、迁移顺序和生产兼容性 |

建议先读模型和容器，再沿“用户动作 → 会话方法 → 存储或网络 → 会话提交”阅读具体功能。Swift 包不依赖 AppKit；macOS 的窗口、剪贴板和视图绑定留在应用目录。`Apple/Shared` 只供 iOS 应用和 AutoFill 编译。

## 数据身份与时间

- `Card`、`CardLabel`、`UserProfile` 的 UUID 是跨端条目身份。字段和附件的内存 UUID 不写入当前 XML，不能用它们跨重新加载匹配对象。
- `CardLabel` 的相等判断只比较 UUID。判断标签内容是否变化时，须显式比较所需属性或使用同步修改时间，不能依赖标签的 `==`。
- `created`、`modified`、标签 `timeStamp`、字段历史时间和同步 `modifiedMs` 均使用 Unix 毫秒。信封尾部 `changedAt` 使用 Unix 秒数的 Double，小端编码。Swift `TimeInterval` 本身不能表达单位，跨端读写须检查转换位置。
- `Field.isHidden` 决定默认遮蔽展示，不为字段增加独立加密。字段、历史、笔记、附件和个人资料在已解锁模型中都是明文。
- 卡片回收站和归档使用状态标志。永久删除会从本地集合移除记录；同步 sidecar 根据已同步基线收集删除，不能把“本地无墓碑”理解为“不需要同步删除状态”。

## 本地修改与保存

macOS 视图通过 `AppContext` 提交修改，iOS 通过 `Vault` 提交修改。编辑界面可以维护草稿值，确认后交给会话入口刷新修改时间、处理历史并持久化。新增字段或状态时，应同时检查模型、XML、单条目编码、导入导出以及对应页面。

macOS `saveDebounced()` 将连续修改合并到最后一次调用约 600 毫秒后的保存。普通 `save()` 使用当前库密钥写本体并推送 Safari 加密快照；该方法内部处理错误，返回不表示可供上层确认的成功事务。需要立即保存的边界应检查现有即时保存路径。

同步快照使用 `DatabaseStore.commitSyncSnapshot` 将本体和同步状态配套提交，必要时同时提交信封。暂存文件写好后才写事务标记；标记存在后的恢复方向是完成这代快照。遇到提交失败不能继续使用旧内存会话覆盖新文件，应沿会话层现有失效和恢复路径处理。

`DatabaseStore` 的递归锁只协调同一进程内的存储访问。App Group 并不把主应用与 AutoFill 变成同一进程，不能据此假定跨进程写入已被锁保护。

## 同步与异步提交

原生应用的常规同步流程为：

1. 捕获库名、库密钥和 `syncSessionID`，在数据库与 `RowSyncState` 的局部副本上执行网络工作。
2. 用修改时间与 `syncedMtimes` 差分收集待推送项；下行应用修订，上行以 `baseRevision` 执行 CAS。
3. 每次关键 await 后验证会话仍有效。锁定、切库或换密钥后的旧任务不得提交到新会话。
4. 合并网络等待期间的本地编辑，持久化配套快照，再发布会话中的数据库和同步状态。具体顺序见两端会话实现。

`RowSync` 负责内存编解码、加密和收敛，不自行落盘。它的 inout 参数可能在抛错前已经改变，因此必须使用工作副本。普通内容冲突按条目修改时间裁决，相等时保留本地；删除有专门的收敛规则，不逐字段合并。

游标过期需要全量重建并补拉重建期间的增量。原生引擎具有分页和批次上限，不能仅凭方法返回就认定所有工作已排空。密码版本前进要求重新获取信封、输入新密码并重建；旧密钥不能继续处理换代后的密文。

浏览器的持久化缓存仅保存密文行和元数据：

- 缓存 scope 由 API origin、账户 ID 和库 ID 组成；快照 version 用于提交时的 CAS。
- `accountEpoch` 在账户清理时前进，阻止登出前启动的请求重新写回旧缓存。
- 解锁态由受限 session storage 或后台内存保存，generation、ticket 和失效代次用于拒绝过期工作。读取轮询不应延长空闲期限。
- content script 获取的数据范围由消息协议及来源验证限制。修改消息时同步检查发送者、页面导航和 iframe 边界。

## 密钥与云端边界

主密码经 PBKDF2 派生密钥，用来包裹随机 256 位库密钥；库密钥用于 AES-GCM 加密本体和同步条目。同步条目的 AAD 绑定 UUID，大小写处理须与 Swift 和 TypeScript 实现一致。

改主密码由会话层编排库密钥轮换、本体重加密和信封替换；绑定云端时另走 rekey 暂存及提交协议。旧文件副本仍可用旧密码读取，轮换无法撤销已经复制出去的旧数据。

Go API 不解密客户端条目。服务端应用密钥用于保护账户元数据等服务端数据，与客户端库密钥职责不同。条目写入、计数、revision 和变更高水位在数据库事务中协调；R2 对象操作不受 SQL 回滚保护，需要 staging、提交和维护清理配合。

服务端开发位于 `service-admin:~/UPasswords`。本地 `Cloud/` 文档或源码快照不证明生产已部署同一版本。修改 kind、schema 或接口时，要分别核对 Swift、shared TS、Contracts、服务端迁移以及实际部署状态，特别是个人资料 kind=3 和独立附件通道。

## 已有行为中容易误判的部分

| 入口 | 当前实现含义 |
|---|---|
| `DatabaseCipher.isV2Container` | 只检查最小头部长度和魔数，不能证明密文认证或 XML 有效 |
| `DatabaseCipher.deriveKey` | 底层派生失败会记录错误，但仍返回缓冲区内容；调用方不能把返回值本身当作派生成功凭据 |
| `DatabaseItemCodec.parse` | 按 kind 取首个匹配类型并验证 UUID；不能当作严格的“只有一个 XML 元素”验证器 |
| `DatabaseStore.backup` | 本体写入成功不保证配套信封也写入成功，恢复前须检查文件对 |
| `DatabaseStore.restore` | 校验容器和信封后分别原子写入，不验证主密码，也不是一次多文件事务 |
| iOS `Vault.verifyMaster` | 同步尝试加载和解密本地库；文件或格式失败也返回 false |
| iOS `Vault.copyToClipboard` | 延迟任务按字符串是否仍相同决定清除，未使用剪贴板 changeCount |
| `CompromisedService.sha1Prefixes` | 当前返回完整 SHA-1 集合；方法名和 prefixLength 参数不能作为截断语义依据 |

这些说明用于准确维护现有行为。修正行为时应同步更新相邻注释和相关测试。

## 注释维护约定

公共类型和跨文件使用的非直观入口使用 Swift `///`、TypeScript JSDoc 或 Go 声明注释说明责任。方法根据需要说明参数、返回值、错误、副作用和调用前提；属性应说明单位、身份、有效期或非恒定计算成本。

流程内注释优先解释约束及原因，例如事务顺序、await 后的失效检查、兼容降级、重试上限和资源释放。简单赋值无需逐行复述。涉及隐私的示例和注释不能写入真实凭据；日志只保留允许的操作元数据。

接口、格式或流程发生变化时，将注释与代码作为同一改动维护。现有注释不应被用来推断部署结果、绕过实际校验，或承诺实现没有提供的原子性。

## 验证与交付入口

| 改动范围 | 检查入口 |
|---|---|
| Core、Persistence、Networking、macOS SPM 应用 | 在对应目录执行 `swift build && swift test`，构建无警告、测试通过 |
| Apple 应用、共享代码、扩展目标 | `cd Apple && xcodegen generate`，从根 workspace 构建相关 macOS/iOS scheme |
| 浏览器扩展 | 根目录 `pnpm install --frozen-lockfile && pnpm build && pnpm test` |
| Go API | 服务端 `Cloud/api/compose.test.yaml` 中的隔离 MariaDB、race 测试和 vet |
| 云端 schema | 按序新增 `Cloud/database/` 迁移；应用到生产前先备份并验证 Go API 兼容性 |
| macOS 交付 | 根目录 `./scripts/make-app.sh`，确认主应用与 Safari 的各自结果，温和退出旧实例后启动 `dist/UPasswords.app` |

加密向量测试可能重写浏览器 fixture；若仅维护注释，应核对并恢复这类随机输出，避免混入无关数据变更。工程、构建目录、共享核心分发副本和 dist 均是生成物。界面由用户验收，开发代理不自行截图或操作界面做视觉验证。
