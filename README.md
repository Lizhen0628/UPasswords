# UPasswords

**一款独立开发的 macOS 密码管理器**（SwiftUI + AppKit，SPM 可执行目标，macOS 14+）。

核心能力：AES-256-GCM 加密数据库容器（PBKDF2-SHA256 ×310,000）、Touch ID 快速解锁、
15 个内置模板、密码生成与强度评估、TOTP 一次性代码、WebDAV 云同步（条目级合并）、
自动备份、18 种第三方密码管理器数据导入、XML/CSV/TXT 导出、泄露密码检查
（haveibeenpwned k-匿名）、菜单栏常驻、中英双语界面。

```bash
swift build             # 构建
swift test              # 单元测试（含 RFC 6238 官方向量）
swift run               # 运行
./scripts/make-app.sh   # 打包 UPasswords.app
```

## 模块速览

| 模块 | 实现 |
|---|---|
| 数据模型 | `Models/CoreModels.swift`（`Card / Field / CardLabel / Attachment / HistoryEntry` 等值类型） |
| XML 解析/序列化 | `Services/DatabaseXML.swift`（逐属性往返 + 删除墓碑，支撑同步合并） |
| 加密容器 | `Services/DatabaseCipher.swift` — `.upw` 容器：PBKDF2-SHA256 ×310,000 + AES-256-GCM |
| 数据库/会话 | `Services/DatabaseStore.swift` + `App/AppContext.swift` |
| 内置模板 | `Models/Templates.swift`（15 个，`@string/…` 经字符串表解析） |
| 密码生成器 | `Services/PasswordGenerator.swift`（随机/便于记忆/字母数字/纯数字 4 型 + 历史） |
| 强度评估 | `Services/PasswordStrength.swift`（模式分析：常见密码/重复/键盘序列/日期/词典） |
| TOTP | `Services/TOTP.swift`（RFC 6238，SHA1/256/512，otpauth:// URI） |
| 钥匙串 | `Services/PasswordStore.swift`（GenericPassword + `.userPresence` 快速解锁） |
| 主窗口 | `Views/Main/`（RootView / SidebarView / CardListView / CardDetailView）三栏布局 + `Views/Window/` 自绘工具栏（8 个图标按钮） |
| 弹窗 | `Views/Sheets/`（SheetFactory 统一登记，按域分组） |
| 图标 | `Models/SymbolModel.swift`（SF Symbol 词表 + IIN 卡组织识别）、`Services/BrandIcons.swift` 品牌方砖 |
| 锁屏纹理 | `App/AppSettings.swift` `LockTextures`（17 种程序化渐变） |
| 锁定/初始化 | `Views/Setup/SetupAndLock.swift`（锁定窗 + 首次运行向导，8 项初始化任务） |
| 导入导出 | `Services/Import/` — 18 种导入：SafeInCloud XML、Chrome/Brave/Edge/Opera/Firefox、LastPass、Bitwarden CSV+JSON、Dashlane、1Password、Safari/Apple 密码、NordPass、Proton Pass、KeePass、Keeper、RoboForm、通用 CSV；XML / CSV / TXT 导出（含明文警告） |
| 泄露检查 | `Services/SecurityServices.swift` — SHA-1 k-匿名 Range API + 离线演示集 |
| 云同步 | `Services/CloudSync.swift` — WebDAV（PROPFIND/MKCOL/PUT/GET + 条目级合并） |
| 自动备份 | `DatabaseStore.backup/restore/prune`（默认保留 10 份） |
| 菜单与快捷键 | `App/Commands.swift` |
| 本地化 | `Resources/{zh-Hans,en}.lproj/` |

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
3. **云同步**：WebDAV 可用（含测试连接/条目级合并）。Google Drive/Dropbox/OneDrive
   需要厂商 OAuth 应用凭据，界面保留但标注“未配置”。
4. **自动填充**：macOS 自动填充需要 Credential Provider 扩展与签名分发，暂未包含；
   密码可从任意字段复制。
5. **高级功能（Premium）**：无商店集成，界面仅作信息展示。
6. **Passkey**：密钥只能在移动端创建（空状态提示）。
7. **UI**：SwiftUI 实现；主窗口为隐藏系统标题栏 + 自绘工具栏条带。

## 目录结构

```
UPasswords/
├── Package.swift                  SPM（macOS 14+，可执行目标 + 测试目标）
├── Sources/UPasswords/
│   ├── App/                       入口 / AppDelegate / StatusItemController /
│   │                              AppContext(+列表/动作/同步扩展) / 设置 / 菜单 / 本地化
│   ├── Models/                    Card 等值类型模型、模板、符号、侧栏、排序
│   ├── Services/                  加密、XML、生成器、强度、TOTP、钥匙串、日志、
│   │                              存储、备份、云同步、导入导出（Import/）、泄露检查
│   ├── Views/                     Main(主窗口) / Window(chrome+工具栏) / Sheets(全部弹窗) /
│   │                              Setup(锁定/初始化) / Preferences(设置) / Components(共享组件)
│   └── Resources/                 {zh-Hans,en}.lproj 字符串 + 菜单栏图标
├── Tests/UPasswordsTests/         单元测试
├── scripts/make-app.sh            .app 打包
└── .github/workflows/ci.yml       build + test
```

## 开发规范

Swift 代码开发规范（命名/格式/可选值/错误处理/并发/性能 + 本项目特定约定与提交自查清单）
见 [AGENTS.md](AGENTS.md)，所有贡献者与编码 Agent 必须遵守。

## 许可

MIT（见 LICENSE）。本项目为独立开发的密码管理器，与其他密码管理器软件无任何隶属关系。
