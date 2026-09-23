# AGENTS.md — UPasswords Swift 代码开发规范

本文件是本项目（macOS 密码管理器，SwiftUI + AppKit + SPM 可执行目标）的统一开发规范，
**所有编码 Agent 与贡献者必须遵守**。规范综合以下来源并结合本项目实践整理：

- [Swift 编程代码规范指南（杨充）](https://yccoding.com/pages/swift-style-guide/)（章节编号沿用，如 7.4）
- [Swift 开发规范·修订版（CoderStar）](https://juejin.cn/post/6979966262591881246)
- [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/)

## 0. 要求等级

| 等级 | 含义 |
|---|---|
| 【必须】 | 无条件遵守；代码审查时违反即打回（对应部分文献的【强制】） |
| 【推荐】 | 默认遵守；确有更好方案时可偏离，但需在评审中说明理由 |
| 【可选】 | 团队按场景自行取舍 |

---

## 1. 项目速览（动手前必读）

```
Sources/UPasswords/
├── App/          入口、AppDelegate、StatusItemController、AppContext(+扩展)、设置、命令、本地化
├── Models/       Card/Field/CardLabel 等值类型模型、模板、侧栏、符号
├── Services/     加密、XML、存储、钥匙串、生成器、强度、TOTP、云同步、日志（Import/ 为导入导出）
├── Views/        Main/ Window/ Sheets/ Setup/ Preferences/ Components/
└── Resources/    lproj 字符串 + 菜单栏图标
```

- 构建：`swift build`；测试：`swift test`；打包：`./scripts/make-app.sh`
- 基线：swift-tools 5.9 / macOS 14+（见 `Package.swift`），可用 API 以 macOS 14 为界；
  状态管理沿用 `ObservableObject` 既有模式，不引入 `@Observable` 宏（如要切换需先修订本规范）。
- 架构：SwiftUI MV + 单例会话 `AppContext`（@MainActor ObservableObject）；
  数据层为值类型 `PasswordDatabase`（struct），动作全部经由 `AppContext` 方法进入。
- **隐私红线【必须】**：密码、字段值、笔记内容等敏感数据**绝不进入日志**，
  只记录操作、对象名/ID、字节长度、错误与耗时。内存中需要以密码为键缓存时，
  使用 SHA-256 散列作键（参考 `PasswordStrength.scoreCache`）。

---

## 2. 命名规约

1. 【必须】严禁拼音/中文/中英混合命名；不以 `_`、`$` 开头。
2. 【必须】文件名、class、struct、enum、protocol 用 **UpperCamelCase**；
   方法、参数、变量、枚举成员用 **lowerCamelCase**。
3. 【必须】缩略词全大写或全小写，以首字母为准：`IDUtil` / `idToString`，禁 `IdUtils` / `iDToString`。
4. 【必须】不用不规范缩写，宁可名字长也要表意完整（`RoundAnimatingButton` 而非 `AbsClass`）。
5. 【推荐】扩展文件命名 `原始类型名+扩展名.swift`，本项目实例：
   `AppContext+CardList.swift`、`AppContext+Sync.swift`；功能杂糅时用 `TypeExtensions.swift`。
6. 【推荐】文件夹用 UpperCamelCase 单数；工具类文件名可用复数（如 `Templates.swift`）。
7. 【推荐】布尔属性/方法以 `is` 前缀：`isExpiring`、`isSearchable`。

## 3. 声明与修饰规约

1. 【必须】能用 `let` 不用 `var`。
2. 【必须】不使用魔法值，常量先命名再使用。
3. 【必须】`extension` 上不加访问修饰符，修饰符加在扩展内的成员上：

   ```swift
   // ✅ 正例
   extension AppContext {
       func backupNow() {}
   }
   // ❌ 反例
   public extension AppContext {}
   ```
4. 【必须】省略默认访问级别（internal 不写）。
5. 【推荐】修饰符顺序：注解 → 访问限制 → `static` → `final`；`@objc` 等注解独占一行。
6. 【推荐】不会被重写的类/方法标 `final`（直接派发优化）；单例统一按 10.4 执行。
7. 【推荐】遵循开闭原则收窄访问：能 `private` 不 internal。注意 `private` 是文件作用域，
   跨文件扩展（如 `AppContext+*.swift`）需要访问的成员放宽为 internal 并加注释说明。

## 4. 格式规约

1. 【必须】左大括号不另起一行；`else`/`else if` 跟随前一右括号；`switch` 中 `case` 与 `switch` 左对齐。
2. 【必须】空格规则：注释符与内容间一格；冒号前不空格、冒号后空格（`name: String`）；
   运算符两侧空格；`->` 两侧空格；逗号后一格。
3. 【必须】禁止用分号把多条语句写在同一行；每行只声明一个变量；空大括号写 `{}`；方法之间空一行。
4. 【必须】重载声明放在一起，按参数从少到多排列。
5. 【推荐】每行 ≤ 100 字符；多元素字面量每元素一行时末尾保留逗号（便于后续 diff）。
6. 【推荐】同一文件多种类型/逻辑时用 `// MARK: - 分组` 分区（本项目既有风格）。
7. 【推荐】import 排序：系统框架在前，按字母序；只 import 用到的模块。

## 5. 简洁写法规约

1. 【必须】成员初始化器够用就不要手写 `init`；构造调用省略 `.init`（`UIView()`）。
2. 【必须】只读计算属性省略 `get`；简单类型靠字面量推断（`var info = ""` 不写 `: String`）。
3. 【必须】枚举值用点语法缩写（`.male`）；`switch-case` 不写 `break`；无返回不写 `-> Void`。
4. 【必须】实例成员访问不加 `self.`（构造器、闭包内消歧除外）。
5. 【必须】**无用代码及时删除**，不留注释掉的死代码——历史由 Git 保管。
6. 【推荐】闭包用尾随闭包与最简写；过滤/转换优先 `filter`/`map`/`for where` 高阶函数。
7. 【推荐】每个协议在单独 `extension` 中实现。

## 6. 注释规约

1. 【必须】文档注释用 `///`（不用 `/** */`，后者留给大段设计说明）；
   跨文件复用或行为非直观的类型/方法/属性必须有文档注释，方法带 `- Parameter` / `- Returns` / `- Throws`。
2. 【必须】说明性注释放代码**上一行**，不放行尾；仅 7.4 要求的"逻辑保证"等简短标注可放行尾。
3. 【推荐】使用 `// MARK: -`、`// TODO:`、`// FIXME:` 地标注释；
   本项目约定：对应原版类时在注释中标注来源（如 `// LockWindowController + LockedState.enter`）。

## 7. 可选值处理 ★（核心章节）

### 7.1 guard 提前返回 【必须】

【必须】避免判断嵌套过深，用 `guard` 提前返回；`guard let` 解包沿用原名（作用域不冲突时）。

```swift
// ✅ 正例
func upsertCard(_ card: Card) {
    guard let i = database.cards.firstIndex(where: { $0.id == card.id }) else { return }
    database.cards[i] = card
}
```

### 7.2 可选链与 nil 合并 【必须】

优先 `?.` 与 `??` 表达默认逻辑；不要让 `??` 默认值再嵌套复杂运算（拆行）。

### 7.3 可选值变换 【推荐】

需要变换时用 `map`/`flatMap` 而不是手动解包再包装：
`selectedCardId.flatMap { database.card(id: $0) }`。

### 7.4 强制解包边界 【必须】

**代码审查时每个 `!` 都必须有充分理由。** 仅以下场景可接受：

1. 系统/框架保证非空的出口（如 `FileManager.urls(for:in:).first!` 取系统目录——
   使用时须在注释中标注"逻辑保证"）；
2. 测试代码中的断言解包；
3. 程序逻辑已保证的极少数情况（如硬编码字面量构造、上一步刚 `filter` 非空的集合），
   且**必须在相邻注释中写明保证依据**。

```swift
// ✅ 可接受：pools 上一行已 filter 非空，注释说明依据
let all = pools.joined()  // pools 非空 → all 非空
chars.append(all.randomElement()!)

// ❌ 禁止：跨状态边界的"应该不为空"
let card = ctx.editDraft!.card        // 应 guard var draft = ctx.editDraft
let time = DateFormatter.localizedString(from: lastSync!, …)  // 应引入局部 let
```

其余一律 `if let` / `guard let` / `?.` / `??`。禁止"先 `x != nil` 判断再 `x!` 解包"的写法——
直接 `if let x`。

### 7.5 隐式解包可选值（IUO）【必须】

IUO（`var x: T!`）仅允许用于 init 期无法赋值的框架注入点（本项目无 Storyboard，原则上
**不应出现** IUO）。新代码用构造注入 + 普通 Optional + `guard` 替代。

## 8. 错误处理

1. 【推荐】选型：同步/单步异步操作用 `throws`；批量操作、需存储/跨边界传递错误用 `Result`。
2. 【必须】`do-catch` 按错误类型分支捕获；**禁止空 `catch` 吞错**——至少 `Log.error` 记录
   （本项目错误还要经 `AppToast` 告知用户，参考 `AppContext.save()`）。
3. 【必须】`try?` 用于只关心成败的场景；`try!` 与 `!` 同规（7.4），仅限逻辑保证不抛错。
4. 【推荐】自定义错误用枚举实现 `LocalizedError`，分支清晰、文案本地化（参考
   `DatabaseCipher.CipherError`、`TOTP.TOTPError`）。
5. 【必须】失败路径要有日志：操作名 + 对象名 + 错误，参考 `Log.error("db", "save … failed: \(error)")`。

## 9. 函数与闭包

1. 【必须】函数参数 ≤ 8 个；超出则引入参数对象。
2. 【必须】逃逸闭包持有 `self` 时使用捕获列表 `[weak self]` 并在闭包开始确认有效性：

   ```swift
   saveDebounce = Just(())
       .delay(for: .milliseconds(600), scheduler: RunLoop.main)
       .sink { [weak self] _ in self?.save() }
   ```
3. 【推荐】优先创建函数而非自定义操作符；尽量少污染全局命名空间。
4. 【推荐】委托/回调属性用 `weak` 修饰防循环引用。

## 10. 类型设计

1. 【必须】能用 `struct` 不用 `class`：值语义、无线程共享隐患。本项目模型层
   （`Card`/`Field`/`PasswordDatabase`）全部是 struct；仅会话/服务单例
   （`AppContext`/`AppSettings`）用 class。
2. 【必须】状态用枚举建模而非字符串/魔法数（参考 `AppContext.Phase`、`AppContext.SyncState`）。
3. 【推荐】协议小而精，一个协议一件事；协议实现在单独 extension。
4. 【推荐】单例：`static let shared = X()` + `private init()`（`private init` 对
   `ObservableObject` 可按需放宽，但禁止业务代码再构造第二实例）。

## 11. 并发规约

1. 【必须】UI 状态集中在 `@MainActor` 类型（本项目 `AppContext`/`AppSettings` 均为 @MainActor）；
   跨隔离调用用 `await`，不要假设线程。
2. 【必须】用 async/await 结构化并发（`async let`/`withTaskGroup`），新代码不使用 GCD 派发；
   存量 GCD 调用须注释说明回主线程的路径（`Log` 串行队列是 11.4 允许的例外）。
3. 【必须】确认在主线执行的高频回调（如 `NSEvent` 本地监视器）用
   `MainActor.assumeIsolated`，不要逐事件 `Task { @MainActor … }`（调度开销）。
4. 【推荐】需要跨并发域共享的类型遵守 `Sendable`；确需绕过检查时用
   `nonisolated(unsafe)` 并注释说明同步手段（本项目 `Log` 用串行队列保护）。
5. 【推荐】高频写入且不需驱动 UI 的状态不要标 `@Published`（本项目 `editDraft`、
   `lastActivity` 的先例：手动控制 `objectWillChange`，避免逐键重渲染）。

## 12. 内存管理

1. 【必须】闭包捕获 `self` 时优先 `[weak self]`；仅当生命周期严格短于持有者才用
   `[unowned self]`（崩溃风险自负，评审需说明）。
2. 【必须】Timer/Notification/KVO 等系统回调注意持有关系与失效时机。
3. 【推荐】值类型优先，天然规避大部分引用循环。

## 13. 性能与编译效率

1. 【推荐】数组合并用 `append(contentsOf:)`；字符串拼接用插值 `"\(a)\(b)"` 而非 `+`。
2. 【推荐】不在 `if` 条件中隐藏重计算或副作用；长表达式拆分为命名中间值。
3. 【推荐】纯函数型重计算加有界缓存（本项目先例：`PasswordStrength.scoreCache`，
   FIFO 512 条、NSLock 保护、SHA-256 作键）。
4. 【推荐】计数场景不做排序等无用功（先例：`count(for:)` 走未排序的 `filteredCards`）。
5. 【推荐】日志等可门控的开销用 `@autoclosure` 延迟求值（先例：`Log.debug` 被级别
   挡掉时零插值开销）。

## 14. 本项目特定约定

1. 【必须】**日志**：统一走 `Log.debug/info/warn/error("分类", "消息")`；分类用短英文
   （`db`/`sync`/`ui`/`lifecycle`/`keychain`/`backup`/`autolock`/`app`/`chrome`，非穷尽，沿用既有分类即可）。
   禁止 `print` 提交入库；遵守第 1 节隐私红线。
2. 【必须】**改动必带日志**：不论是新增还是修改代码，关键路径必须补齐日志，
   以便用户测试反馈后能直接凭日志定位问题（本项目多次仅凭日志定位疑难 bug，
   反例代价：release 过滤 debug 级导致一轮排查无据可查）。具体要求：
   - **info 级**（release 可见）：用户可见动作与状态转换——打开/关闭、保存/取消、
     新建/删除、重要分支决策点（如 `edit sheet save cardId=…`、`upsertCard …`）；
   - **debug 级**：高频事件与细节探针（逐键写入、hitTest 等避免刷盘的内容）；
   - **warn/error 级**：异常、降级、失败路径（如钥匙串读取失败回退）；
   - 修改 bug 时顺带检查事故路径是否缺日志，缺则一并补上；
   - 后台/异步任务记录起止与耗时。隐私红线不变：只记操作、ID、长度、耗时，绝不含敏感数据。
3. 【必须】**可见文案**走 `L10n.t("key")` / `L10n.db("key")`，键名沿用原版字符串表；
   缺键用 `L10n.t("key", fallback: "…")`。品牌名用 `L10n.tBranded`。
   新增键必须同步更新 `en.lproj` 与 `zh-Hans.lproj` 两张 `Localizable.strings`，禁止只加一边。
4. 【必须】**数据变更**统一经 `AppContext` 方法进入并以 `saveDebounced()` 持久化；
   视图不直接改 `database`。
5. 【必须】**文件组织**：一个文件一个主类型；同类型职责扩展放 `Type+职责.swift`（细则见 2.5）；
   弹窗视图按域放 `Views/Sheets/` 并在 `SheetFactory` 登记。
6. 【推荐】注释中标注与原版 Safe.app 的对应关系（逆向复刻项目的可追溯性约定）。
7. 【推荐】新逻辑配测试：`Tests/UPasswordsTests/`，运行 `swift test` 全绿方可提交
   （已知历史遗留失败 `testCrackTimeText` 除外，修复它时请单独提交；豁免项修复后从本条移除）。

## 15. 常见反模式（禁止清单）

| 反模式 | 正确做法 |
|---|---|
| `if x != nil { f(x!) }` | `if let x { f(x) }` |
| 空 `catch {}` 吞错 | 分支捕获 + `Log.error` + 用户提示 |
| 魔法值 `if count == 5` | 命名常量 |
| 嵌套 3 层以上的 if | `guard` 提前返回 |
| `self.foo()` 无处不加 self | 省略 `self.` |
| 注释掉的死代码 | 删除，Git 留档 |
| `DispatchQueue.main.async` 回跳 | `@MainActor` + `await` |
| `@Published` 逐键高频写入 | 手动 `objectWillChange` 控制粒度 |
| 密码/字段值进日志 | 只记操作、ID、长度、错误 |
| `try!` / `as!` / IUO | 同 7.4 边界，仅逻辑保证 + 注释依据 |
| 新增/修改代码不带日志，出事无从查 | 关键路径必带日志（14.2），分级正确 |

## 16. 提交前自查清单

提交信息用英文一行式概括主题（可附括号补充细节），与既有 git log 风格一致。

- [ ] 无 `!` 强制解包/强转，或每处都有注释标注的逻辑保证（7.4）
- [ ] 无 `try!`、无空 `catch`、失败路径有日志与用户提示
- [ ] 新增/修改的关键路径已补日志（info=用户动作与状态转换，见 14.2），无敏感数据
- [ ] 逃逸闭包 `[weak self]`；无新增循环引用
- [ ] 新代码无 `print`，日志走 `Log` 且不含敏感数据
- [ ] 可见文案走 `L10n`，无硬编码字符串
- [ ] 无魔法值；`let` 优先；访问级别收窄
- [ ] 死代码已删除；`swift build` 无警告、`swift test` 通过（已知豁免见 14.7）
- [ ] 文件放置符合目录结构；扩展文件命名 `Type+Ext.swift`

## 17. 工具链（可选增强）

- 【可选】SwiftLint / SwiftFormat 可在本地安装辅助检查，配置文件未入库前不阻塞 CI；
  若引入，规则以本文档为准裁剪。
- 参考实现就在仓库中：拿不准风格时，先看 `AppContext+CardList.swift`（guard/策略分组）、
  `Services/AppLog.swift`（门控与并发保护）、`Services/PasswordStrength.swift`（缓存与隐私）。
