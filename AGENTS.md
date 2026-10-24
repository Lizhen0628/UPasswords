# AGENTS.md — UPasswords 开发规范

项目当前开发版本统一为 v1。本规范覆盖当前工作树的客户端、云服务与文档维护约定。

【必须】为硬性要求；【推荐】默认遵守，偏离需说明理由；【可选】按需使用。

## 1. 开发边界与架构

- 【必须】客户端与文档在本地仓库开发；服务端在 `service-admin:~/UPasswords` 开发。两端同时改动时，分别修改并核对接口契约与部署状态。
- 【必须】本地和服务端均直接使用 `main`；除非用户要求，不创建或切换功能分支。
- 【必须】基线为 swift-tools 5.9、macOS 14+；库包另支持 iOS 17+。库包禁止依赖 AppKit 等 macOS 专属框架，跨平台类型放库包，macOS UI 绑定留在 `Apple/macOS`。
- 【必须】沿用 SwiftUI MV + `ObservableObject`，不引入 `@Observable`。macOS 会话为 `@MainActor AppContext` 单例；`AppSettings` 同样隔离于主 actor。
- 【必须】模型优先 `struct`，状态用枚举；`Card`、`Field`、`PasswordDatabase` 保持值类型，会话/服务单例使用 `class`。
- 【必须】macOS 数据变更统一经 `AppContext` 方法，以 `saveDebounced()` 持久化；视图不得直接改 `database`。
- 【必须】依赖方向：Apple 应用 → Core/Persistence/Networking，Persistence/Networking → Core。库包对外类型与成员须 `public`，包括显式构造器。

## 2. 项目导航

| 路径 | 职责与约定 |
|---|---|
| `UPasswords.xcworkspace` | Xcode 开发入口 |
| `Apple/project.yml` | Xcode 工程唯一真源；改 target、依赖或 Info.plist 属性后运行 `cd Apple && xcodegen generate` |
| `Apple/macOS/` | SPM 可执行应用；`Sources/UPasswords/` 按 App、Models、Services、Views 分层；资源经 `AppResources` 兼容 SPM/Xcode 构建 |
| `Apple/iOS/` | iOS 应用，会话层为 `Services/Vault.swift`；`AutoFill/` 为凭据自动填充扩展 |
| `Apple/Shared/` | iOS 与 AutoFill 共享品牌组件、`SharedVaultStore`（App Group 库容器）和应用标识；macOS 不编译此目录 |
| `Apple/SafariWebExtension/` | Safari 原生消息桥；JS/manifest 来自 `WebExtensions/safari`，manifest 放 appex 资源根，src 保持目录结构 |
| `SwiftPackages/Core/` | 领域模型、模板、数据库编解码/加密、密码生成/评分、TOTP、日志、本地化 |
| `SwiftPackages/Persistence/` | 库文件、备份恢复、钥匙串、同步、中继 API、导入导出 |
| `SwiftPackages/Networking/` | HIBP k-匿名泄露检查与本地清单 |
| `WebExtensions/` | pnpm workspace；shared 为严格模式 TS，共享存储/消息/平台适配；Safari/Chrome/Edge/Firefox 消费共享逻辑 |
| `Cloud/` | 云端协调服务；生产 API 为 `api/` Go + chi；MariaDB 存账户与条目密文，R2 存附件和网站图标；数据库设计见 `DATABASE.md`，DDL 与迁移位于 `database/` |
| `Contracts/` | 跨端 schema 与协议说明；改动须同步 Core 模型、shared TS 和 schemas |
| `FEATURES.md` | 功能清单；改功能时同步更新 |
| `scripts/make-app.sh` | Release 打包主应用与 Safari 宿主，复制资源 bundle、同步 `/Applications` 并注册扩展 |
| `.github/workflows/ci.yml` | 四个 Swift 包测试、Xcode 双平台构建、Web 构建测试与打包 |

生成物不得手改或入库：`Apple/UPasswords.xcodeproj`、各包 `.build/`、`dist/`、`node_modules/`、`WebExtensions/shared/dist/`、`WebExtensions/{safari,chrome}/src/shared/`。

## 3. 隐私、日志与文案

- 【必须】密码、密钥、字段值、笔记等敏感数据不得进入日志或通知；只记录操作、对象名/ID、长度、错误与耗时。密码相关缓存以 SHA-256 散列作键，参考 `PasswordStrength.scoreCache`。
- 【必须】统一使用 `Log.debug/info/warn/error("分类", "消息")`，分类沿用短英文（如 db/sync/ui/keychain），禁止提交 `print`。
- 【必须】新增或修改关键路径必须补齐日志；修 bug 时同时检查事故路径。后台/异步任务记录起止与耗时：
  - `info`：用户动作、状态转换、重要分支；定位问题依赖的日志必须在 Release 可见，不得降为 debug，也不得为排查将整体日志级别调为 debug。
  - `debug`：逐键输入、hitTest 等高频细节。
  - `warn/error`：异常、降级和失败；失败日志包含操作、对象及错误。
- 【必须】可见文案使用 `L10n.t` / `L10n.db`，缺键使用 `fallback`，品牌名使用 `L10n.tBranded`。新增键同步维护 Core 资源下 en/zh-Hans 的对应字符串表，`Localizable.strings` 与 `Database.strings` 的语言间键集合分别齐平；iOS 键沿用 `ios_` 前缀。
- 【必须】代码注释、文档与可见文案不得使用“复刻 / 逆向 / 对应原版”等描述，不得引用其他商业软件的类名、nib 或内部资料。

## 4. Swift 编码与文件组织

- 【必须】使用清晰英文命名，禁止拼音、中文、混合命名及 `_`/`$` 开头；类型与文件用 UpperCamelCase，方法/参数/变量/枚举成员用 lowerCamelCase；缩略词整体大写或小写（`IDUtil` / `idToString`），不用含糊缩写。
- 【必须】一个文件一个主类型；同类型职责扩展放 `Type+职责.swift`，杂项扩展可用 `TypeExtensions.swift`；弹窗按域放 `Views/Sheets/` 并在 `SheetFactory` 登记。
- 【必须】能用 `let` 不用 `var`；魔法值提取为命名常量；默认 `internal` 不写；访问修饰符放 extension 内的成员上，不修饰 extension。
- 【必须】左花括号不换行，else/else if 紧跟前一右括号，case 与 switch 左对齐；冒号前无空格，冒号/逗号/注释符后留一格，运算符与 `->` 两侧留空格。
- 【必须】不用分号连接语句，每行只声明一个变量，空大括号写 `{}`，方法间空一行；重载相邻并按参数从少到多排列。
- 【必须】成员初始化器够用时不手写 init，构造调用省略 `.init`；只读属性省略 get，简单字面量省略类型注解；枚举值用点语法，switch-case 不写 break，无返回不写 `-> Void`。
- 【必须】省略无必要的 `self.`（构造器、闭包内消歧除外）；及时删除无用代码，不保留注释掉的死代码；函数参数不超过 8 个，否则引入参数对象。
- 【必须】跨文件复用或行为非直观的声明使用 `///` 文档注释，方法注明适用的 Parameter/Returns/Throws；说明性注释放代码上一行，简短“逻辑保证”标注可放行尾；块注释仅用于大段设计说明。
- 【推荐】访问级别尽量收窄；跨文件扩展所需成员可放宽为 internal，并注释原因；不可重写的类/方法标 final；修饰符顺序为注解 → 访问限制 → static → final，`@objc` 等注解独占一行。
- 【推荐】每行 ≤ 100 字符，多行集合末元素保留逗号；系统 import 在前并按字母序排列，只引入所需模块；使用 MARK/TODO/FIXME 分区或标记。
- 【推荐】目录用 UpperCamelCase 单数，工具文件可用复数；布尔属性/方法以 is 开头；使用尾随闭包、filter/map/for where，优先函数而非自定义操作符，少污染全局命名空间。
- 【推荐】协议保持单一职责，每个协议在单独 extension 实现；单例采用 `static let shared` + `private init()`，ObservableObject 可按需放宽初始化器，但业务代码不得构造第二实例。

## 5. 可选值与错误处理

- 【必须】使用 guard 提前返回，避免深层嵌套；guard let 在无冲突时沿用原名。默认逻辑优先 `?.` / `??`，复杂默认值拆为局部常量；禁止先判非 nil 再强解包。
- 【必须】每处 `!` / `as!` / `try!` 都须有充分依据：仅限框架保证、测试断言解包或局部逻辑已保证的情况；框架及逻辑保证须在相邻注释中写明依据。跨状态边界的“应该非空”不成立，其余使用安全解包或转换；`try!` 还须保证不抛错。
- 【必须】IUO 仅限 init 期无法赋值的框架注入点；本项目无 Storyboard，新代码使用构造注入、普通 Optional 和 guard。
- 【必须】do-catch 按错误类型分支处理，不得空 catch；失败至少记录 `Log.error`，应用层经 `AppToast` 告知用户，参考 `AppContext.save()`；`try?` 仅用于只关心成败的场景。
- 【推荐】可选值变换用 map/flatMap；同步或单步异步操作用 throws，批量或跨边界传递错误用 Result；自定义错误用本地化的 `LocalizedError` 枚举。

## 6. 并发、内存与性能

- 【必须】UI 状态集中于 `@MainActor` 类型，跨隔离调用使用 await；新代码使用 async/await、async let、withTaskGroup，不用 GCD 派发；存量 GCD 注释说明回主线程路径，Log 的串行同步队列除外。
- 【必须】确认在主线程执行的高频回调（如 NSEvent 本地监视器）使用 `MainActor.assumeIsolated`，不得逐事件创建 `Task { @MainActor … }`。
- 【必须】逃逸闭包捕获 self 使用 `[weak self]` 并确认有效；其他闭包也优先弱引用，只有生命周期严格短于持有者且评审说明时可用 unowned。Timer/Notification/KVO 必须处理持有关系与失效时机。
- 【推荐】跨并发域共享类型遵守 Sendable；确需绕过检查时使用 `nonisolated(unsafe)` 并说明同步手段；委托/回调引用用 weak 防循环引用。
- 【推荐】不驱动 UI 的高频状态不标 `@Published`，按需手动控制 `objectWillChange`，参考 editDraft/lastActivity。
- 【推荐】合并数组用 append(contentsOf:)，拼接字符串用插值；条件中不隐藏重计算或副作用，长表达式拆为局部常量；计数不做排序等无用功。
- 【推荐】纯函数重计算使用有界、线程安全缓存；门控日志等开销用 `@autoclosure` 延迟求值。

## 7. 构建与测试

在对应目录执行；Swift 构建须无警告、测试全绿后方可提交。

| 目录 | 命令 |
|---|---|
| `SwiftPackages/Core`、`Persistence`、`Networking`（分别执行） | `swift build && swift test` |
| `Apple/macOS` | `swift build && swift test` |
| `Apple` | `xcodegen generate`，随后从仓库根用 `xcodebuild -workspace UPasswords.xcworkspace …` 构建所需 scheme |
| `Cloud/api` | `docker compose -f compose.test.yaml up --abort-on-container-exit --exit-code-from test` |
| 仓库根（Web 扩展） | `pnpm install && pnpm build && pnpm test` |

- 【推荐】新逻辑在所属包的测试目录或 `WebExtensions/shared/test/` 配测试。
- 【必须】测试不得依赖机器语言、时区或绝对路径；文案期望值通过同一 L10n 键获取，fixture 路径由 `#filePath` 推导仓库根。
- 【可选】SwiftLint/SwiftFormat 规则以本文为准，未引入配置前不阻塞 CI。
- 参考实现：macOS 的 `AppContext+CardList.swift`（guard/分组），Core 的 `AppLog.swift`（日志/并发）与 `PasswordStrength.swift`（缓存/隐私）。

## 8. 交付与启动

- 【必须】每轮代码修改后自动执行 `./scripts/make-app.sh`，更新 `dist/UPasswords.app`，并在答复中报告部署结果；以 Release 打包版为主要自测版本。
- 【必须】打包成功后自动启动供用户测试：旧实例运行时先用 `osascript -e 'tell application "UPasswords" to quit'` 温和退出，再用 `open dist/UPasswords.app` 启动新版。
- 【必须】不要自行截图或操作界面做视觉验证，由用户验收；完成构建与测试检查即可。
- 提交信息用英文一行概括主题，与既有 git log 风格一致。提交前核对本文的隐私、日志、可选值、内存、本地化、文件组织和构建测试要求。

## 9. 完成通知

【必须】每轮任务结束（部署完成、长任务结束或需用户验收/介入）发送 Bark 通知；标题带机器名前缀，正文一行说明结果及所需动作，group 固定为 UPasswords。通知不得含敏感数据，发送失败不阻塞主流程。

```bash
machineName=$(rg -m1 '^export MACHINE_NAME=' ~/.zshrc | cut -d'"' -f2)
title=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1], safe=""))' "[${machineName:-$(hostname -s)}] 标题")
body=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1], safe=""))' "正文")
curl --fail --silent --show-error --max-time 15 -G "https://api.day.app/Ujcj9UtWAosDUPDuWKANCR/$title/$body" \
  --data-urlencode 'group=UPasswords' --data-urlencode 'ttl=600'
```
