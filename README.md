# UPasswords

> 项目当前开发版本：**v1**。本文记录当前工作树的实现；容器格式、同步协议和 API 路径各自使用独立版本号，详见下文。

UPasswords 是一款独立开发的密码管理器。领域模型、加密和数据库编解码由跨平台 Swift 包提供，客户端包括 macOS、iOS、iOS AutoFill，以及 Safari、Chrome、Edge、Firefox 扩展。

核心能力包括本地加密密码库、密码生成与强度分析、TOTP、数据导入导出、备份恢复、泄露密码检查和个人多设备同步。完整功能范围与部分实现边界见 [FEATURES.md](FEATURES.md)。

## 文档导航

| 文档 | 内容 |
|---|---|
| [维护导航](MAINTENANCE.md) | 代码阅读入口、状态与密钥边界、保存同步流程、注释维护和验证方法 |
| [决策记录](DECISIONS.md) | 已确认的 v1 实现规格、实施状态与正式开放前事项 |
| [规则一致性审查](DECISIONS_REVIEW.md) | 开发前发现的规则交叉问题、建议口径、实现条件及验收场景 |
| [功能清单](FEATURES.md) | 各客户端、云同步、导入导出及已知功能边界 |
| [数据库设计](Cloud/DATABASE.md) | 本地数据模型、云端 MariaDB 表结构、SQL、ER 图与已确认规格 |
| [云服务设计](Cloud/DESIGN.md) | 云端部署形态、安全模型、同步流程与 API 版本 |
| [云服务运维](Cloud/README.md) | Go API、数据库、部署与运维入口 |
| [API 部署说明](Cloud/api/README.md) | Go + chi 生产 API 的配置、验证和启动 |
| [跨端契约](Contracts/README.md) | 加密库明文 XML 与扩展消息契约 |
| [浏览器扩展](WebExtensions/README.md) | 构建、加载方式和扩展安全边界 |
| [开发规范](AGENTS.md) | 架构、隐私、代码风格、测试、打包和交付要求 |

## 项目结构

| 路径 | 职责 |
|---|---|
| Apple/macOS | SwiftUI + AppKit macOS 应用，使用 Core、Persistence、Networking |
| Apple/iOS | iOS 应用和凭据自动填充扩展 |
| Apple/Shared | iOS App 与扩展共享的品牌组件、App Group 库存储和产品常量 |
| Apple/SafariWebExtension | Safari 扩展的原生消息桥 |
| SwiftPackages/Core | 领域模型、加密容器、XML、密码生成、强度、TOTP、本地化 |
| SwiftPackages/Persistence | 加密库文件、备份、钥匙串、同步、导入与导出 |
| SwiftPackages/Networking | HIBP k-匿名泄露检查 |
| WebExtensions/shared | 浏览器扩展共享 TypeScript 核心、存储和消息协议 |
| Cloud/api | Go + chi 云 API 与隔离 MariaDB 集成测试 |
| Cloud/database | MariaDB 初始化 DDL 与按序迁移脚本 |
| Contracts | 跨端 JSON Schema 与协议说明 |

Xcode 工程由 [Apple/project.yml](Apple/project.yml) 生成。生成的 Apple/UPasswords.xcodeproj 不手工编辑。

## 数据与安全

- macOS 与 iOS 的本地密码库是 XML 数据经 VEK 使用 AES-GCM 加密后的 .upw 容器；主密码经 PBKDF2-SHA256 派生密钥，保护 .upwkey 中的 VEK 信封。格式细节以 [DatabaseCipher.swift](SwiftPackages/Core/Sources/UPasswordsCore/DatabaseCipher.swift) 为准。
- 本地数据模型包括卡片、标签和独立用户资料；字段、历史、附件、笔记和卡片标签引用序列化在加密库中。永久删除会移除记录，不保存本地永久墓碑。
- 云同步使用条目级密文和 revision。同步游标、修订基线及待同步集合保存在 .upwsync sidecar；该文件不保存密码或字段明文。
- 生产云 API 运行于 Go + chi，MariaDB 保存账户、会话、密码库元数据、条目密文与变更日志；R2 提供附件和网站图标对象接口。服务端不解密条目内容。当前 MariaDB DDL 与表关系见 [Cloud/DATABASE.md](Cloud/DATABASE.md)。
- 生产 API 已于 2026-10-28 发布 `/v1` 与同步协议 5；数据库迁移 `0001`–`0010` 已应用，旧协议同步请求会被拒绝。数据库不是可丢弃的测试数据，任何生产重置都必须另行授权并先核验备份。协议上线不代表新客户端已正式分发或完成跨版本验收。
- UserProfile kind=3 个人资料同步及版本化附件的服务端接口已部署。macOS/iOS 与浏览器端已接入附件同步和图片预览；生产跨端端到端验收仍待完成。原生端与四种扩展已支持含附件候选裁决及活动冲突候选连附件另存为新条目；四种扩展也支持受限字段组合。候选永久损坏后的独立隔离修复与待处理修改的超期人工恢复已实现。四种扩展备份导入和独立本地副本、原生端候选 rekey 已实现。
- SwiftData 与 IndexedDB 已按相同业务 schema 保存本地用户数据；`.upw` 继续作为兼容/回退双写源。本地仅保存当前用户数据，云端保存所有用户数据及服务端运营数据。
- 密码、密钥、字段内容和笔记不得进入日志。产品版本 v1 与下列技术版本相互独立：本地容器格式 v2、行同步能力版本 5、唯一 API 路径 /v1、MariaDB 初始化脚本 0001。

本地库默认位于用户 Application Support 目录；macOS 数据库、备份、钥匙串和同步状态的具体路径及保留策略由 [DatabaseStore.swift](SwiftPackages/Persistence/Sources/UPasswordsPersistence/DatabaseStore.swift) 与 [数据库设计文档](Cloud/DATABASE.md) 定义。恢复加密库仍需要相应主密码。

## 构建与测试

Swift 包分别构建和测试：

~~~sh
(cd SwiftPackages/Core && swift build && swift test)
(cd SwiftPackages/Persistence && swift build && swift test)
(cd SwiftPackages/Networking && swift build && swift test)
(cd Apple/macOS && swift build && swift test)
~~~

Apple 工程与浏览器扩展：

~~~sh
cd Apple && xcodegen generate
cd ..
xcodebuild -workspace UPasswords.xcworkspace -scheme UPasswords-macOS build
xcodebuild -workspace UPasswords.xcworkspace -scheme UPasswords-iOS -destination 'generic/platform=iOS Simulator' build
pnpm install && pnpm build && pnpm test
~~~

云端 Go API 的隔离集成测试见 [Cloud/api/README.md](Cloud/api/README.md)；Release macOS 应用由 scripts/make-app.sh 打包。

## 技术基线

- Swift tools 5.9；macOS 14+；Core、Persistence、Networking 另支持 iOS 17+。
- SwiftUI MV + ObservableObject；Core/Persistence/Networking 不依赖 AppKit。
- 包依赖方向：Apple 应用 → Core/Persistence/Networking；Persistence 与 Networking → Core。
- 浏览器扩展共享代码为严格模式 TypeScript，四个平台从共享核心构建。

## 许可

MIT，详见 [LICENSE](LICENSE)。
