# UPasswords

**Safe.app（"Passwords & Codes - safe"，SafeInCloud 25.3.5 / 2503005，App Store 版）的复刻。**

`main` 分支为 SwiftUI 版；**本分支（`tauri-vue3-rewrite`）使用 Tauri 2 + Vue 3 + Vite 重构**，
数据格式与 SwiftUI 版完全互通（同一 `.upw` 容器、同一 SafeInCloud XML 交换格式、同一钥匙串条目、
同一 `~/Library/Application Support/UPasswords/` 目录）。

```bash
pnpm install
pnpm tauri dev     # 开发模式（HMR）
pnpm tauri build   # 产出 UPasswords.app（src-tauri/target/release/bundle/macos/）
pnpm test          # 前端 20 项测试（TOTP RFC 6238 官方向量 / 强度 / CSV / 导入器）
cargo test         # Rust 3 项测试（加密容器往返 / XML 往返 / 未知类型降级）
```

## 架构（Tauri 2 + Vue 3）

```
├── src/                        Vue 3 前端（vite, pinia, @lucide/vue）
│   ├── lib/                    纯逻辑层（Swift 服务层的 TS 移植）
│   │   ├── models.ts           XCard/XField/XLabel/XGhost + merge + 搜索
│   │   ├── templates.ts        15 个内置模板（字段序列 1:1）
│   │   ├── symbols.ts          46 名词符号目录（lucide 等价物）+ IIN 卡组织识别
│   │   ├── sidebar.ts          18 个特殊侧栏项 / 排序 / 颜色表
│   │   ├── totp.ts             RFC 6238（WebCrypto HMAC，SHA1/256/512，otpauth://）
│   │   ├── generator.ts        4 型密码生成器 + 历史 + 词库
│   │   ├── strength.ts         zxcvbn 式强度评估（0–4 + 破解时间）
│   │   ├── importer.ts         CSV 引擎 + 18 种导入格式 + XML/CSV/TXT 导出
│   │   ├── i18n/               zh-Hans/en 字符串表（由 .strings 生成）
│   │   └── backend.ts          invoke 桥（与 Rust 命令一一对应）
│   ├── stores/                 Pinia：app（AppContext 移植）/ settings / toast
│   ├── views/                  初始化 / 锁定（17 纹理）/ 主窗口三栏 / 编辑器
│   ├── sheets/                 约 30 个 Sheet（模板选择、生成器、导入导出、
│   │                           泄露检查、云同步、备份、偏好设置…）
│   └── styles/theme.css        shadcn/ui 设计语言（zinc 色板、明暗自适应）
├── src-tauri/                  Rust 后端
│   ├── cipher.rs               PBKDF2-SHA256 ×310,000 + AES-256-GCM 容器
│   │                           （"UPWDB1\0\0" magic，与 Swift 版字节兼容）
│   ├── xml.rs                  SafeInCloud XML 逐属性解析/序列化 + 幽灵墓碑
│   ├── model.rs                数据模型 + XDatabase.mergeWithDatabase 条目级合并
│   ├── store.rs                Databases/Backups 目录、自动备份（保留 10 份）
│   ├── keychain.rs             macOS 钥匙串（UPasswords-<db>，与 Swift 版同名条目）
│   ├── webdav.rs               WebDAV 驱动（PROPFIND/MKCOL/PUT/GET + 同步合并）
│   ├── compromised.rs          haveibeenpwned k-匿名 Range API + 离线演示集
│   ├── templates.rs            15 模板 @string 引用表（前端解析本地化）
│   └── commands.rs             22 个 #[tauri::command]
├── tests/                      vitest 前端测试
└── Sources/, Tests/, Package.swift   SwiftUI 版（保留在仓库，构建见下）
```

## 功能（与 SwiftUI 版对照）

- 相位流转：初始化（500×680 向导）→ 锁定（500×380 纹理窗，快速解锁）→ 主窗口
  （970×640，Overlay 标题栏 + 66pt 自绘工具栏 8 钮 + 侧栏 213 / 列表 355 / 详情）
- 卡片 CRUD：模板实例化、字段编辑（12 类型 + 9 自动填充令牌）、收藏/归档/回收站/
  置顶、重复、存为模板、字段历史（保留 20 条）
- 安全侧栏：弱密码 / 相同密码 / 已泄露（HIBP）/ 即将到期 / 已过期
- TOTP 实时码（列表徽标 + 详情行 + 编辑器预览，30s 翻转倒计时）
- 云同步：WebDAV（条目级合并、墓碑防复活）；GDrive/Dropbox/OneDrive 界面保留标注未配置
- 自动备份 / 恢复（默认保留 10 份）；多数据库管理（主库/重命名/删除/切换）
- 导入 18 种格式（Chrome/Brave/Edge/Opera/Firefox/LastPass/Bitwarden CSV+JSON/
  Dashlane/1Password/Safari/NordPass/Proton/KeePass/Keeper/RoboForm/CSV/SafeInCloud XML）
- 导出 XML/CSV/TXT（明文警告）；剪贴板复制 + 自动清除（10s/30s/1m/2m）
- 自动锁定（空闲计时 + 后台锁定）、错误尝试自毁（可选）、初始化 8 项任务清单
- 中英双语即时切换（语言覆盖设置）；shadcn/ui 明暗自适应主题

## 与 Swift 版的已知差异

1. **快速解锁**：keyring crate 无法附加 `userPresence` 访问控制，「生物识别」条目
   为普通钥匙串条目（服务/账户名与 Swift 版一致，可互相读取）。
2. **图标**：SF Symbols → lucide 等价物；品牌图标（Facebook/X/…）以近似通用图标代替。
3. **自动填充**：与 SwiftUI 版一致，仅保留说明界面。
4. **Premium/Adapty**：信息展示，无商店集成。

## 数据与安全

- 数据库：`~/Library/Application Support/UPasswords/Databases/<名称>.upw`（与 Swift 版共用）
- 容器格式：`"UPWDB1\0\0"` magic + 版本 + 迭代次数 + 16B 盐 + AES-GCM 密封盒
- 备份：`~/Library/Application Support/UPasswords/Backups/<名称>/yyyyMMdd-HHmmss.upw`
- 设置：localStorage（键 `upasswords.settings`）

## SwiftUI 版（保留）

```bash
swift build && swift run        # macOS 14+, Swift 5.9+（51 项测试：swift test）
./scripts/make-app.sh           # 打包旧版 UPasswords.app
```

## 许可

MIT（见 LICENSE）。本项目为独立编写的互操作性研究复刻，与 SafeInCloud / SAFEINCLOUD
S.A.S. 无任何隶属关系；请勿用于分发原应用素材。
