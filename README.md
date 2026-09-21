# UPasswords

**Safe.app（"Passwords & Codes - safe"，SafeInCloud 25.3.5 / 2503005，App Store 版）的 Swift 1:1 复刻。**

本工程基于同级逆向还原工程 [../PasswordsCodes](../PasswordsCodes)（5363 类接口级还原 +
逆向分析报告）实现：原应用的**功能、数据格式、模板、字符串与交互结构**逐一对照复刻，
实现代码为全新编写，不含任何原应用素材（图标/纹理为自绘等价物，字符串仅采用功能性短标签）。

```bash
swift build          # 构建（macOS 14+, Swift 5.9+）
swift test           # 51 项单元测试（含 RFC 6238 官方向量）
swift run            # 运行
./scripts/make-app.sh   # 打包 UPasswords.app
```

## 复刻映射表（Safe.app → UPasswords）

| 原类（逆向还原） | 本项目实现 |
|---|---|
| `XItem / XCard / XField / XLabel / XFile / XImage / XHistory` | `Models/CoreModels.swift`（`Card / Field / CardLabel / Attachment / HistoryEntry`） |
| `XDatabase` + XML 格式（`<database><card><field>…`） | `Services/DatabaseXML.swift`（逐属性往返解析/序列化 + 幽灵墓碑） |
| `DatabaseCipher`（CCCrypt 线索） | `Services/DatabaseCipher.swift` — PBKDF2-SHA256 ×310,000 + AES-256-GCM（见“如实标注的等价实现”） |
| `DatabaseAdapter` / `DatabaseManager` / `DatabaseConfig` | `Services/DatabaseStore.swift` + `App/AppContext.swift` |
| 15 个内置模板（`Resources/database.xml`） | `Models/Templates.swift`（字段序列 1:1） |
| `PasswordGenerator` / `PasswordSettings` | `Services/PasswordGenerator.swift`（随机/便于记忆/字母数字/纯数字 4 型 + 历史） |
| `PasswordStrength` / zxcvbn（`_zxcvbn` + dictionary.txt） | `Services/PasswordStrength.swift`（自实现模式分析：常见密码/重复/键盘序列/日期/词典） |
| `StrengthIndicator.crackTimeWithSeconds:` | `PasswordStrength.crackTime`（原版单位字符串） |
| TOTP（`one_time_password` 字段） | `Services/TOTP.swift`（RFC 6238，SHA1/256/512，otpauth:// URI） |
| `PasswordStore`（钥匙串） | `Services/PasswordStore.swift`（GenericPassword + `.userPresence` 快速解锁） |
| `MainWindowController` + 三 ViewController | `Views/MainWindow.swift` — 按 nib 反解规格复刻：970×640 窗口、三栏 213/355/余量、`main_toolbar` 8 个纯图标按钮（add/sync ‖ sorting/generator/置顶/delete/lock/preferences）+ 弹性空隙 |
| `LabelListViewController`（源列表式可折叠分组行 + 计数徽章，nib: LabelListGroupCell/LabelListCell 25pt）+ 18 个 `*Label` 特殊侧栏项 | `Views/MainWindow.swift` SidebarView + `Models/SidebarModels.swift`（全部项目/收藏/历史/密码/一次性代码/笔记/文件/图片/密钥/信用卡/弱密码/相同密码/已泄露/即将到期/已过期/已归档/回收站/模板） |
| `EditCardWindowController` + 4 个 `EditCard*Tab` + 5 种 Cell | `Views/EditCardSheet.swift`（条目/笔记/图片/文件 4 选项卡 + 字段编辑器） |
| `SetLabelsSheetController` 等 40+ `*SheetController` | `Views/CardSheets.swift` / `Views/DataSheets.swift`（逐个对应） |
| `SelectSymbolViewController` / `SymbolModel`（46 TIFF） | `Models/SymbolModel.swift`（同名词表 + SF Symbol 自绘渲染 + IIN 卡组织识别） |
| `SelectTextureSheetController`（texture_1..17.jpg） | `LockTextures`（17 种程序化渐变，不复制原图） |
| `LockWindowController`（nib: 500×350 窗口、代码构建内容） / `LockedState` | `Views/SetupAndLock.swift`（500×350 纹理窗口）+ 自动锁定计时/后台锁定 |
| `SetupWindowController` / `SetupPlanViewController`（8 项任务） | `SetupWindowView` / `SetupPlanSheet`（侧栏“初始化 n/8”） |
| `ImportFormat` 族（64 适配器） | `Services/ImportExport.swift` — 18 种：SafeInCloud XML、Chrome/Brave/Edge/Opera/Firefox、LastPass、Bitwarden CSV+JSON、Dashlane、1Password、Safari、NordPass、Proton Pass、KeePass、Keeper、RoboForm、通用 CSV |
| `ExportCardsTask` / `ExportAsSheetController` | XML / CSV / TXT 导出（含明文警告） |
| `CompromisedPasswordsSheetController`（haveibeenpwned） | `Services/SecurityServices.swift` — SHA-1 k-匿名 Range API + 离线演示集 |
| `WebDavDriver` / `CloudDriver` / `SyncTask` | `Services/CloudSync.swift` — WebDAV 同步可用（PROPFIND/MKCOL/PUT/GET + 条目级合并） |
| `AutoBackupViewController` / `BackupDatabaseTask` | `DatabaseStore.backup/restore/prune`（默认保留 10 份） |
| 主菜单（MainMenu.nib：文件/编辑/工具/视图…） | `App/Commands.swift`（含 addCard:/sync:/lock: 等全部动作与快捷键） |
| 本地化（zh-Hans/en，512+111 键） | `Resources/{zh-Hans,en}.lproj/`（原键值直接沿用） |

## 数据与安全

- 数据库：`~/Library/Application Support/UPasswords/Databases/<名称>.upw`
- 容器格式：`"UPWDB1\0\0"` magic + 版本 + 迭代次数 + 16B 盐 + AES-GCM 密封盒
- 密码/Touch ID 副本存 Keychain（`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`）
- 自动备份：`~/Library/Application Support/UPasswords/Backups/<名称>/`（加密备份）
- XML 交换格式与 SafeInCloud 完全兼容，可互导

## 如实标注的等价实现（与原版差异）

1. **加密参数**：原二进制仅暴露 `CCCryptor`/SHA 引用，具体参数不可从 Mach-O 还原；
   本复刻采用逆向报告给出的现代等价方案 PBKDF2-SHA256×310,000 + AES-256-GCM，
   因此 `.upw` 容器**不能**与原版 SafeInCloud 直接互换（XML 层互换不受影响）。
2. **图标/纹理**：原 `*_Template.tiff` 与 `texture_*.jpg` 未复制；以同名词表的 SF Symbol
   与程序化渐变替代。符号名、分组、颜色名与原版一致。
3. **云同步**：仅 WebDAV 可用（含测试连接/条目级合并）。Google Drive/Dropbox/OneDrive
   需要厂商 OAuth 应用凭据，界面保留但标注“未配置”。
4. **自动填充**：macOS 自动填充需要 Credential Provider 扩展与签名分发，本复刻不含；
   设置页保留说明界面。
5. **高级功能（Premium/Adapty）**：无商店集成，界面仅作信息展示。
6. **Passkey**：按原版行为，密钥只能在移动端创建（空状态提示）。
7. **UI 框架**：原版为 AppKit + nib；复刻用 SwiftUI（Swift 原生等价）。主窗口/侧栏/列表/
   锁定窗的几何与控件规格从原版 nib（NIBArchive 格式）直接反解得出并逐项对齐；图标使用
   SF Symbol 等价物而非原版 TIFF 素材。

## 目录结构

```
UPasswords/
├── Package.swift                  SPM（macOS 14+，可执行目标 + 测试目标）
├── Sources/UPasswords/
│   ├── App/                       入口 / AppContext / 设置 / 菜单 / 本地化助手
│   ├── Models/                    X* 模型族、模板、符号、侧栏、排序
│   ├── Services/                  加密、XML、生成器、强度、TOTP、钥匙串、
│   │                              存储、备份、云同步、导入导出、泄露检查
│   ├── Views/                     主窗口、编辑器、锁定/初始化、全部 Sheet、设置
│   └── Resources/{zh-Hans,en}.lproj/   Localizable + Database 字符串
├── Tests/UPasswordsTests/         51 项测试
├── scripts/make-app.sh            .app 打包
└── .github/workflows/ci.yml       build + test
```

## 许可

MIT（见 LICENSE）。本项目为独立编写的互操作性研究复刻，与 SafeInCloud / SAFEINCLOUD S.A.S.
无任何隶属关系；请勿用于分发原应用素材。
