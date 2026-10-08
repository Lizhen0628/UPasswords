# UPasswords

**一款独立开发的密码管理器**（macOS 优先：SwiftUI + AppKit；领域核心为跨平台 Swift 包，
macOS 14+ / iOS 17+）。

核心能力：AES-256-GCM 加密数据库容器（PBKDF2-SHA256 ×310,000）、Touch ID 快速解锁、
15 个内置模板、密码生成与强度评估、TOTP 一次性代码、WebDAV/iCloud Drive 云同步
（条目级合并 + 冲突裁决）、自动备份、18 种第三方密码管理器数据导入、XML/CSV/TXT 导出、
泄露密码检查（haveibeenpwned k-匿名）、菜单栏常驻、中英双语界面。

## 仓库结构

```
UPasswords/
├── UPasswords.xcworkspace          根工作区（指向 Apple/UPasswords.xcodeproj）
├── Apple/
│   ├── UPasswords.xcodeproj        xcodegen 生成（Apple/project.yml）
│   │   ├── UPasswords-macOS        macOS 应用 target
│   │   ├── UPasswords-iOS          iOS 应用 target（完整界面，消费领域包）
│   │   ├── UPasswordsAutoFill      iOS 凭据自动填充扩展 target
│   │   └── SafariWebExtension      Safari Web 扩展 target
│   ├── macOS/                      macOS 应用（SPM 可执行包 + 测试）
│   ├── iOS/                        iOS 应用：App/Services(Vault 会话层)/Models/Views
│   │                               + AutoFill/（ASCredentialProvider 扩展）
│   └── Shared/                     iOS 主 App 与扩展共享：品牌组件、
│                                   App Group 库容器（SharedVaultStore）、产品常量
├── WebExtensions/
│   ├── shared/                     Safari + Chrome 共享 TS（core/storage/messaging/platform）
│   ├── safari/                     Safari 扩展（manifest + background/content/popup）
│   └── chrome/                     Chrome MV3 扩展（同构壳）
├── SwiftPackages/
│   ├── Core/                       UPasswordsCore — 模型、XML 编解码、加密、生成器、
│   │                               强度、TOTP、日志、本地化字符串表
│   ├── Persistence/                UPasswordsPersistence — 文件存储、钥匙串、备份、
│   │                               云同步（WebDAV/iCloud）、导入导出
│   └── Networking/                 UPasswordsNetworking — HIBP 泄露检查
├── Contracts/                      数据交换契约（JSON Schema + 说明）
├── package.json / pnpm-workspace.yaml   Web 扩展 monorepo
├── scripts/make-app.sh             .app 打包
└── .github/workflows/ci.yml        build + test（Swift ×4 包 / xcodebuild 双平台 / pnpm）
```

## 构建与测试

```bash
# Swift 包（每个包独立构建/测试）
cd SwiftPackages/Core && swift build && swift test        # 领域核心
cd SwiftPackages/Persistence && swift build && swift test # 存储与同步
cd SwiftPackages/Networking && swift build && swift test  # 泄露检查
cd Apple/macOS && swift build && swift test               # macOS 应用

# Xcode 工程（三 target：macOS App / iOS App / Safari 扩展）
cd Apple && xcodegen generate
xcodebuild -workspace UPasswords.xcworkspace -scheme UPasswords-macOS build
xcodebuild -workspace UPasswords.xcworkspace -scheme UPasswords-iOS \
  -destination 'generic/platform=iOS Simulator' build

# Web 扩展（共享 TS 编译 + Safari/Chrome 打包）
pnpm install && pnpm build

./scripts/make-app.sh             # 打包 dist/UPasswords.app 并可直接运行
```

## 模块速览

| 模块 | 实现 |
|---|---|
| 数据模型 | `SwiftPackages/Core/…/CoreModels.swift`（`Card / Field / CardLabel / Attachment / HistoryEntry` 等值类型） |
| XML 解析/序列化 | `SwiftPackages/Core/…/DatabaseXML.swift`（逐属性往返 + 删除墓碑，支撑同步合并） |
| 加密容器 | `SwiftPackages/Core/…/DatabaseCipher.swift` — `.upw` 容器：PBKDF2-SHA256 ×310,000 + AES-256-GCM |
| 数据库/会话 | `SwiftPackages/Persistence/…/DatabaseStore.swift` + `Apple/macOS/…/App/AppContext.swift` |
| 内置模板 | `SwiftPackages/Core/…/Templates.swift`（15 个，`@string/…` 经字符串表解析） |
| 密码生成器 | `SwiftPackages/Core/…/PasswordGenerator.swift`（随机/便于记忆/字母数字/纯数字 4 型 + 历史） |
| 强度评估 | `SwiftPackages/Core/…/PasswordStrength.swift`（模式分析：常见密码/重复/键盘序列/日期/词典） |
| TOTP | `SwiftPackages/Core/…/TOTP.swift`（RFC 6238，SHA1/256/512，otpauth:// URI） |
| 钥匙串 | `SwiftPackages/Persistence/…/PasswordStore.swift`（GenericPassword + `.userPresence` 快速解锁） |
| 导入导出 | `SwiftPackages/Persistence/…/Import/` — 18 种导入 + XML / CSV / TXT 导出（含明文警告） |
| 泄露检查 | `SwiftPackages/Networking/…/CompromisedService.swift` — SHA-1 k-匿名 Range API + 离线演示集 |
| 云同步 | `SwiftPackages/Persistence/…/CloudSync.swift` — WebDAV（PROPFIND/MKCOL/PUT/GET + 条目级合并）与 iCloud Drive |
| 自动备份 | `DatabaseStore.backup/restore/prune`（默认保留 10 份） |
| 主窗口 | `Apple/macOS/…/Views/Main/` 三栏布局 + `Views/Window/` 自绘工具栏 |
| 弹窗 | `Apple/macOS/…/Views/Sheets/`（SheetFactory 统一登记，按域分组） |
| Web 扩展 | `WebExtensions/shared`（TS 核心：host 规范化/匹配、storage 封装、消息协议、Safari/Chrome 适配器）+ `safari/`、`chrome/` 壳 |
| 数据契约 | `Contracts/schemas/`（数据库 JSON 镜像 + 扩展消息 Schema） |
| 菜单与快捷键 | `Apple/macOS/…/App/Commands.swift` |
| 本地化 | `SwiftPackages/Core/…/Resources/{zh-Hans,en}.lproj/` |

## 数据与安全

- 数据库：`~/Library/Application Support/UPasswords/Databases/<名称>.upw`
- 容器格式：`"UPWDB1\0\0"` magic + 版本 + 迭代次数 + 16B 盐 + AES-GCM 密封盒
- 密码/Touch ID 副本存 Keychain（`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`）
- 自动备份：`~/Library/Application Support/UPasswords/Backups/<名称>/`（加密备份）
- XML 交换格式支持导入导出（可导入 SafeInCloud 导出的 XML）
- 日志：`~/Library/Application Support/UPasswords/Logs/UPasswords.log`（超 1MB 自动轮转为
  `.old.log`）。DEBUG 构建记录 debug 级，release 默认 info 级；排查问题时可用
  `UP_LOG_LEVEL=debug` 环境变量或 `defaults write com.upasswords.UPasswords log.level -string debug`
  提升详细程度。日志只记录操作/对象名/长度/错误，绝不记录密码与字段内容

## 实现说明

1. **加密**：PBKDF2-SHA256 ×310,000 派生密钥 + AES-256-GCM 认证加密（`.upw` 容器）。
2. **图标/纹理**：全部使用 SF Symbol 与程序化渐变自绘，不含第三方素材。
3. **云同步**：WebDAV 与 iCloud Drive 可用（含测试连接/条目级合并/冲突裁决）。
   Google Drive/Dropbox/OneDrive 需要厂商 OAuth 应用凭据，界面保留但标注“未配置”。
4. **iOS / Safari / Chrome 扩展**：iOS 端为完整应用（锁屏/首页/列表/详情/编辑/生成器/安全/设置
   七大界面），数据落在 App Group 容器的真实加密库，与 macOS 共用 Core/Persistence/Networking；
   AutoFill 凭据扩展经钥匙串/主密码解锁后按站点匹配填充。真机运行需配置签名与
   App Group entitlement（`group.com.upasswords.shared`）；浏览器扩展可构建加载。
5. **高级功能（Premium）**：无商店集成，界面仅作信息展示。
6. **Passkey**：密钥只能在移动端创建（空状态提示）。
7. **UI**：SwiftUI 实现；主窗口为隐藏系统标题栏 + 自绘工具栏条带。

## 开发规范

Swift 代码开发规范（命名/格式/可选值/错误处理/并发/性能 + 本项目特定约定与提交自查清单）
见 [AGENTS.md](AGENTS.md)，所有贡献者与编码 Agent 必须遵守。

## 许可

MIT（见 LICENSE）。本项目为独立开发的密码管理器，与其他密码管理器软件无任何隶属关系。
