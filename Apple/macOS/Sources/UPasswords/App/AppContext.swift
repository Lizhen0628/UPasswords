import Foundation
import SwiftUI
import Combine
import CryptoKit
import UPasswordsCore
import UPasswordsPersistence
import UPasswordsNetworking

/// Central session controller — owns the session state, database persistence
/// and the card-list strategies per sidebar selection.
///
/// 职责拆分(同类型 extension,便于按域浏览):
/// - 本文件:会话状态、启动引导、锁定/解锁生命周期、持久化、自动锁
/// - AppContext+CardList:侧栏卡片列表策略、搜索、最近打开
/// - AppContext+Actions:卡片/标签 CRUD、初始化清单、历史
/// - AppContext+Sync:修改密码、备份、云同步(WebDAV / iCloud Drive)
@MainActor
final class AppContext: ObservableObject {
    enum Phase: Equatable {
        case setup        // SetupWindowController flow (first launch)
        case locked       // LockWindowController
        case unlocked     // MainWindowController
    }

    // MARK: - Published state
    @Published var phase: Phase = .setup {
        didSet {
            syncSessionID = UUID()
            Log.info("lifecycle", "phase \(oldValue) → \(phase)")
            savePendingPersonalInfoIfNeeded()
        }
    }
    @Published var database = PasswordDatabase()
    /// Memory-only onboarding draft, consumed after creation or restoration unlocks the vault.
    var pendingPersonalInfo: PersonalInfoDraft?
    @Published var databaseName: String = "" {
        didSet {
            guard oldValue != databaseName else { return }
            syncSessionID = UUID()
            Log.info("lifecycle", "databaseName \"\(oldValue.isEmpty ? "∅" : oldValue)\" → \"\(databaseName.isEmpty ? "∅" : databaseName)\"")
        }
    }
    @Published var selection: SidebarSelection = .special(.allCards)
    @Published var selectedCardId: UUID? = nil
    /// 搜索框逐键文本。故意不用 @Published(同 editDraft/lastActivity 先例,规范 11.5):
    /// 逐键广播 objectWillChange 会让整棵视图树重渲染造成输入卡顿;
    /// TextField 编辑期间自绘显示,防抖后的 searchQuery 才驱动列表/计数。
    private(set) var searchText: String = ""
    /// 防抖后真正参与列表/计数过滤的搜索词(防抖逻辑见 SearchInputDebouncer)。
    @Published private(set) var searchQuery: String = ""
    /// 编辑工作副本。故意不用 @Published:填字段值时每个按键都会写入,
    /// @Published 会逐键广播 objectWillChange 让整棵视图树重渲染(输入卡顿)。
    /// didSet 只在「打开(nil → 有值)」和「关闭(有值 → nil)」时通知视图;
    /// 编辑中的键入写入(有值 → 有值)对 UI 不可见,TextField 自己维护显示。
    var editDraft: EditCardModel? = nil {
        didSet {
            let opened = oldValue == nil && editDraft != nil
            let closed = oldValue != nil && editDraft == nil
            if opened || closed {
                objectWillChange.send()
                Log.info("ui", "editDraft \(opened ? "open" : "close") cardId=\(editDraft?.card.id.uuidString.prefix(8) ?? oldValue?.card.id.uuidString.prefix(8) ?? "nil")… isNew=\(editDraft?.isNew ?? false)")
            }
        }
    }
    @Published var activeSheet: AppSheet? = nil {
        didSet {
            guard oldValue != activeSheet else { return }
            Log.info("ui", "sheet \(oldValue.map { "open \($0.id)" } ?? "nil") → \(activeSheet.map { "open \($0.id)" } ?? "close")")
        }
    }
    @Published var syncState: SyncState = .disabled
    @Published var lastSync: Date? = nil
    /// 远端密文用本机不知道的密码加密(对端刚改过主密码/数据损坏):
    /// 云同步设置页据此展示「接管/覆盖」修复入口(与 iOS 同语义)。
    @Published var syncRemoteUnreadable = false
    /// relay 账户/绑定状态版本号:登录、登出、绑定/解绑、会话失效时自增。
    /// RelayStore 只是 defaults 读写,不经 @Published——没有这个版本号,
    /// 登录成功后设置页表单不会翻页(用户会误判"登录失败"而反复重试,
    /// 每次重试都在服务端多签发一条会话)。
    @Published private(set) var relayStateVersion = 0

    /// relay 状态版本号自增(跨文件扩展经此触发设置页重渲染,setter 保持私有)。
    func relayStateChanged() {
        relayStateVersion += 1
    }
    @Published var lastSyncFailed: Date? = nil
    @Published var failedUnlockAttempts = 0

    enum SyncState: Equatable {
        case disabled, idle, syncing, error(String)
    }

    /// 行级同步状态(游标/revision/脏集合/快照基线);解锁时按库装载。
    /// 故意不用 @Published:同步状态呈现走 syncState,这里高频读写不驱动逐条 UI。
    var rowSync = RowSyncState()
    /// 跨文件同步扩展捕获此标识,锁定/解锁/切库后旧异步任务不得提交。
    var syncSessionID = UUID()
    // 空闲追踪用,不进 UI。故意不用 @Published:活动监视器把每次键盘/鼠标
    // 事件都算作活动,若发布会在打字时逐键触发整棵视图树重渲染(输入卡顿)。
    var lastActivity: Date = Date()
    // 网站图标抓取状态(逻辑在 AppContext+Icons.swift):
    // 本会话已尝试抓取的卡片,防止反复请求失败站点;补抓串行任务句柄。
    var iconFetchAttempted = Set<UUID>()
    var iconBackfillTask: Task<Void, Never>? = nil

    /// In-memory password, present only while unlocked.
    /// 仅生命周期代码(unlock/lock/erase/changePassword)可写入。
    nonisolated(unsafe) var password: String = ""
    /// v2 信封加密的库密钥(解锁时由信封解出;保存/同步解密本体用,与主密码解耦)。
    /// nonisolated(unsafe):与 password 同一先例,全部读写都在 @MainActor 上。
    nonisolated(unsafe) var vaultKey: SymmetricKey? = nil

    let settings = AppSettings.shared
    let store = DatabaseStore.shared
    private var cancellables = Set<AnyCancellable>()
    private var autoLockTimer: Timer? = nil
    /// 云同步到期 ticker(5s 一跳,由守卫条件过滤;逻辑见 AppContext+Sync)。
    /// internal:extension 在独立文件,无法用 private(规范 3.7)。
    var autoSyncTimer: Timer? = nil
    /// 泄露库自动检查 ticker(60s 一跳;逻辑见 AppContext+Security)。
    var breachCheckTimer: Timer? = nil
    /// 泄露检查进行中标志:防止 60s ticker 在一次长检查未完成时重复发起。
    var breachCheckInFlight = false

    static let shared = AppContext()

    init() {
        // 沙盒化迁移必须最先跑:后续 settings/store 都依赖迁移后的偏好与库文件
        LegacyPreferencesMigration.run()
        bootstrapPhase()
        installActivityMonitor()
    }

    // MARK: - Bootstrap

    private func bootstrapPhase() {
        Log.info("lifecycle", "bootstrap: mainDatabaseName=\"\(store.mainDatabaseName)\" databases=\(store.list().map(\.name))")
        #if DEBUG
        // 复现「锁定→解锁」过渡:UP_SCREENSHOT_BOOT=2 时建库(如有)→启动进锁定态,
        // 3 秒后自动解锁(自动化测试用,release 不编译)。
        if ProcessInfo.processInfo.environment["UP_SCREENSHOT_BOOT"] == "2" {
            Log.info("lifecycle", "UP_SCREENSHOT_BOOT=2 (debug automation)")
            if !store.exists("TestDB") {
                _ = try? store.create(name: "TestDB", password: "screenshot")
                store.mainDatabaseName = "TestDB"
            }
            databaseName = "TestDB"
            phase = .locked
            // 存量 GCD:主线程延时,回调仍在主队列,无需回主线程
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.phase == .locked else { return }
                // 二进制重建后钥匙串 ACL 会拒绝读取,回退到建库密码
                let pw = PasswordStore.loadPassword(databaseName: self.databaseName) ?? "screenshot"
                if PasswordStore.loadPassword(databaseName: self.databaseName) == nil {
                    Log.warn("keychain", "stored password unreadable (ACL/signature change?) → fallback to build password")
                }
                try? self.unlock(name: self.databaseName, password: pw)
                // UP_SCREENSHOT_CARD=first/short:解锁后造演示卡并选中(详情页截图自动化)。
                // 幂等:各演示卡按标题判断,存在即跳过。
                if let screenshotCard = ProcessInfo.processInfo.environment["UP_SCREENSHOT_CARD"],
                   !screenshotCard.isEmpty,
                   let spec = Templates.spec(id: 102) {
                    // 演示值(非真实凭据);前两张卡共用同一密码以复现「重复使用的密码」警告
                    if !database.cards.contains(where: { $0.title == "国金" }) {
                        var a = Templates.makeCard(from: spec)
                        a.title = "国金"
                        a.fields = a.fields.map { f in
                            var f = f
                            switch f.type {
                            case .login: f.value = "8886800628"
                            case .password: f.value = "Xk7#pQ2vTr0ub4dor"
                            case .website: f.value = "example.com"
                            default: break
                            }
                            return f
                        }
                        a.notes = "第二因子使用硬件密钥。"
                        a.labelIds = []
                        upsertCard(a)
                        var b = Templates.makeCard(from: spec)
                        b.title = "国金备用"
                        b.fields = b.fields.map { f in
                            var f = f
                            if f.type == .password { f.value = "Xk7#pQ2vTr0ub4dor" }
                            return f
                        }
                        upsertCard(b)
                        Log.info("ui", "screenshot demo cards created")
                    }
                    // 短密码卡:复现 ≤6 位全打点掩码与「弱密码」警告卡
                    if !database.cards.contains(where: { $0.title == "短密码示例" }) {
                        var c = Templates.makeCard(from: spec)
                        c.title = "短密码示例"
                        c.fields = c.fields.map { f in
                            var f = f
                            if f.type == .password { f.value = "abc12" }
                            return f
                        }
                        upsertCard(c)
                        Log.info("ui", "screenshot demo short-password card created")
                    }
                    // UP_SCREENSHOT_CARD=short 选中短密码卡,其余选中「国金」
                    let selectTitle = screenshotCard == "short" ? "短密码示例" : "国金"
                    if let demo = database.cards.first(where: { $0.title == selectTitle }) {
                        selectedCardId = demo.id
                        Log.info("ui", "screenshot select demo cardId=\(demo.id)")
                        // 截图自动化:顺带触发一次复制提示,验证 HUD 样式(2s 后自动消失)
                        AppToast.shared.show(L10n.t("text_copied_message"))
                    }
                }
                // UP_SCREENSHOT_EDITOR=<templateId>:解锁后直接打开该模板的新卡编辑表单
                if let specId = ProcessInfo.processInfo.environment["UP_SCREENSHOT_EDITOR"].flatMap(Int.init),
                   let spec = Templates.spec(id: specId) {
                    // 存量 GCD:主线程延时,回调仍在主队列,无需回主线程
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        NSApp.activate(ignoringOtherApps: true)
                        // 主窗口搬到当前空间(同 BOOT=1),全屏应用占据当前空间时截图才可见
                        for w in NSApp.windows where w.frame.width > 800 {
                            w.setFrameOrigin(NSPoint(x: 120, y: 140))
                            w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
                            w.makeKeyAndOrderFront(nil)
                        }
                        var m = EditCardModel(card: Templates.makeCard(from: spec))
                        m.isNew = true
                        AppContext.shared.editDraft = m
                    }
                }
            }
            return
        }
        #endif
        #if DEBUG
        // 截图/自动化专用:UP_SCREENSHOT_BOOT=1 时跳过向导直接建库解锁。
        // 仅 DEBUG 构建生效,release 行为不变。
        if ProcessInfo.processInfo.environment["UP_SCREENSHOT_BOOT"] == "1" {
            Log.info("lifecycle", "UP_SCREENSHOT_BOOT=1 (screenshot automation)")
            UserDefaults.standard.set("zh-Hans", forKey: "app.language")
            for key in UserDefaults.standard.dictionaryRepresentation().keys
            where key.hasPrefix("setup.done.") {
                UserDefaults.standard.removeObject(forKey: key)
            }
            settings.showWhatsNewAtStartup = false
            settings.autoLockSeconds = 0
            settings.fastUnlock = false
            let name = "UPasswords"
            if !store.exists(name) {
                do {
                    // 走与向导「继续」相同的 createDatabase 路径,复现 setupPlan 弹窗
                    try createDatabase(name: name, password: "screenshot", touchID: false)
                } catch {
                    FileHandle.standardError.write(Data("[UP_SCREENSHOT_BOOT] create failed: \(error)\n".utf8))
                }
                // createDatabase 内部已 unlock + 弹出 setupPlan
                // 存量 GCD:主线程延时,回调仍在主队列,无需回主线程
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    NSApp.activate(ignoringOtherApps: true)
                    for w in NSApp.windows where w.frame.width > 800 {
                        w.setFrameOrigin(NSPoint(x: 120, y: 140))
                        w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
                        w.makeKeyAndOrderFront(nil)
                    }
                }
                // Timer 调度在主 runloop,回调必在主线程;assumeIsolated 依据规范 11.3
                Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
                    MainActor.assumeIsolated {
                        NSApp.setActivationPolicy(.regular)
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
                // UP_SCREENSHOT_EDITOR=<templateId>:解锁后直接打开该模板的新卡编辑表单
                if let specId = ProcessInfo.processInfo.environment["UP_SCREENSHOT_EDITOR"].flatMap(Int.init) {
                    // 存量 GCD:主线程延时,回调仍在主队列,无需回主线程
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                        NSApp.activate(ignoringOtherApps: true)
                        guard let spec = Templates.spec(id: specId) else { return }
                        var m = EditCardModel(card: Templates.makeCard(from: spec))
                        m.isNew = true
                        AppContext.shared.editDraft = m
                    }
                }
                return
            }
        }
        #endif
        let dbs = store.list()
        if dbs.isEmpty {
            Log.info("lifecycle", "bootstrap → phase=setup (no databases)")
            phase = .setup
        } else {
            Log.info("lifecycle", "bootstrap → phase=locked (databases present)")
            phase = .locked
            databaseName = store.exists(store.mainDatabaseName)
                ? store.mainDatabaseName
                : (dbs.first?.name ?? "Main")
        }
    }

    // MARK: - Setup / lifecycle

    func createDatabase(name: String, password: String, touchID: Bool) throws {
        Log.info("lifecycle", "createDatabase \"\(name)\" touchID=\(touchID)")
        do {
            try store.create(name: name, password: password)
        } catch {
            Log.error("lifecycle", "createDatabase \"\(name)\" failed: \(error)")
            throw error
        }
        store.mainDatabaseName = name
        if touchID && PasswordStore.biometricAvailable() {
            PasswordStore.savePasswordForBiometric(password, databaseName: name)
        }
        try unlock(name: name, password: password)
        activeSheet = .setupPlan
    }

    func unlock(name: String, password: String) throws {
        Log.info("lifecycle", "unlock \"\(name)\"")
        let loaded: (PasswordDatabase, SymmetricKey, RowSyncState)
        do {
            let (db, vek) = try store.loadUnlocked(name: name, password: password)
            let state = try store.loadSyncState(for: name)
            loaded = (db, vek, state)
        } catch {
            Log.warn("lifecycle", "unlock \"\(name)\" failed: \(error)")
            throw error
        }
        database = loaded.0
        vaultKey = loaded.1
        databaseName = name
        rowSync = loaded.2
        Log.info("sync", "restored row sync state for \"\(name)\" (cursor=\(rowSync.cursor), pending=\(rowSync.dirtyUpserts.count + rowSync.dirtyDeletes.count))")
        self.password = password
        phase = .unlocked
        lastActivity = Date() // otherwise the idle timer re-locks right after unlocking
        failedUnlockAttempts = 0
        lastFailedUnlockAt = nil
        selection = .special(.allCards)
        selectedCardId = database.activeCards.first?.id
        Log.info("lifecycle", "unlocked \"\(name)\": \(database.cards.count) cards, \(database.labels.count) labels")
        SafariSnapshotBridge.push(databaseName: name, store: store)
        scheduleIconBackfill()
        scheduleAutoBackupIfNeeded()
        startAutoSyncTickerIfNeeded()
        startBreachCheckTickerIfNeeded()
        // 云同步步骤按 relay 绑定判定(API 为默认通道;网盘入口已隐藏)
        markSetupTaskDoneIf(.cloudSync, when: relayBound)
        markSetupTaskDoneIf(.autoBackup, when: settings.autoBackupEnabled)
        markSetupTaskDoneIf(.touchID, when: settings.fastUnlock && PasswordStore.biometricAvailable())
        // 钥匙串密码副本自愈:他机改密后以新密码重新解锁时,回写新副本
        // (旧副本已在强制锁定时清除;生物识别项随快速解锁配置恢复)
        if let stored = PasswordStore.loadPassword(databaseName: name), stored != password {
            PasswordStore.savePassword(password, databaseName: name)
            if settings.fastUnlock && PasswordStore.biometricAvailable() {
                PasswordStore.savePasswordForBiometric(password, databaseName: name)
            }
            Log.info("keychain", "password copy healed after unlock for \"\(name)\"")
        }
        // 引导登录在先的库在此自动补绑;信封先行:解锁后即拉取注册表,
        // 密码被他机修改能立刻提示
        Task {
            await relayBindCurrentVaultIfNeeded()
            await relayRenameCurrentSession()
            await checkRelayPasswordVersion()
        }
        announceStartupSheets()
    }

    /// 解锁结果:只有「密码被拒」计入自毁;本地数据损坏/信封缺失/断网是
    /// 环境故障,输对密码也不该累计销毁计数。
    enum UnlockOutcome {
        case success, wrongPassword, unavailable
    }

    /// 密码被拒的判定:unwrapVaultKey 唯一以 wrong_password_error 文案抛出,
    /// 信封缺失/格式错误是其他 CipherError/IO 错误——绝不计入自毁。
    private static func isPasswordRejection(_ error: Error) -> Bool {
        (error as? DatabaseCipher.CipherError)?.message == L10n.t("wrong_password_error")
    }

    /// 解锁(带远端兜底):本地解不开时拉远端信封+本体收敛后重试。
    /// 他机轮换库密钥后，本地仍保留旧钥配套文件；以新密码验证远端信封，
    /// 重建后一次提交新库体、同步状态和新信封。
    /// 密码真错时远端信封同样解不开 → 仍是密码错误,不误导。
    @discardableResult
    func unlockWithRemoteFallback(name: String, password: String) async -> UnlockOutcome {
        do {
            try unlock(name: name, password: password)
            return .success
        } catch {
            guard let binding = relay.binding(database: name),
                  let token = relay.token(database: name) else {
                return Self.isPasswordRejection(error) ? .wrongPassword : .unavailable
            }
            let sessionID = syncSessionID
            let currentName = databaseName
            let originalKey = vaultKey
            do {
                let detail = try await relayClient.getVault(token: token, vaultId: binding.vaultId)
                guard syncSessionID == sessionID, databaseName == currentName,
                      vaultKey == originalKey, !Task.isCancelled else {
                    Log.warn("sync", "remote unlock result discarded after session changed")
                    return .unavailable
                }
                guard let envelopeBytes = detail.envelope,
                      let vek = try? DatabaseCipher.unwrapVaultKey(envelopeBytes, password: password) else {
                    Log.warn("lifecycle", "remote unlock fallback: password rejected by remote envelope")
                    return .wrongPassword
                }
                // 远端是行级密文,走全量重建收敛本地(他机改密后本体随新 VEK 重加密)
                var state: RowSyncState
                do {
                    state = try store.loadSyncState(for: name)
                } catch {
                    Log.error("sync", "remote unlock fallback state load failed: \(error)")
                    return .unavailable
                }
                let db: PasswordDatabase
                do {
                    db = try await RowSync.fullRebuild(
                        client: relayClient, token: token, vaultId: binding.vaultId,
                        key: RowSyncKey(raw: vek.withUnsafeBytes { Data($0) }), state: &state)
                } catch {
                    Log.warn("sync", "remote unlock fallback: rows not reachable yet (\(error))")
                    return .unavailable
                }
                guard syncSessionID == sessionID, databaseName == currentName,
                      vaultKey == originalKey, !Task.isCancelled else {
                    Log.warn("sync", "remote unlock rebuild discarded after session changed")
                    return .unavailable
                }
                try commitSyncSnapshot(db, name: name, vaultKey: vek, state: state, envelope: envelopeBytes)
                Log.info("lifecycle", "remote unlock fallback converged local vault \"\(name)\" (rows rebuilt)")
                do {
                    try unlock(name: name, password: password)
                    return .success
                } catch {
                    Log.error("lifecycle", "remote unlock fallback: retry after convergence failed: \(error)")
                    return Self.isPasswordRejection(error) ? .wrongPassword : .unavailable
                }
            } catch {
                Log.warn("sync", "remote unlock fallback failed: \(error)")
                return .unavailable
            }
        }
    }

    /// 启动提示:What's New + 即将到期卡片提醒。
    private func announceStartupSheets() {
        let version = "1.0"
        if settings.showWhatsNewAtStartup && settings.lastWhatsNewVersion != version {
            settings.lastWhatsNewVersion = version
            activeSheet = .whatsNew
            return
        }
        if !cards(for: .special(.expiring), search: "").isEmpty {
            activeSheet = .expiredCards
        }
    }

    /// 进入锁定相位。
    func lock() {
        guard phase == .unlocked else { return }
        Log.info("lifecycle", "lock \"\(databaseName)\"")
        password = ""
        vaultKey = nil
        phase = .locked
        syncState = .idle
        activeSheet = nil
        editDraft = nil
        // 未决冲突现场随之作废:下次解锁后的同步会重新检测
        // 关闭设置窗等独立窗口,不让它们残留在锁屏之上
        WindowChromeManager.shared.closeAuxiliaryWindows()
        // 锁定即清掉本 App 复制进剪贴板的内容(自动清除关闭/未走完时不残留)
        ClipboardModel.shared.clearIfOurs()
    }

    var touchIDAvailable: Bool {
        PasswordStore.biometricAvailable()
    }

    /// 当前数据库是否已启用 Touch ID 快速解锁(存在生物识别密码副本)。
    var hasBiometricItem: Bool {
        PasswordStore.hasBiometricItem(databaseName: databaseName)
    }

    /// 启用 Touch ID 快速解锁:把当前(已解锁状态下的)数据库密码存为副本。
    /// 偏好设置开关和初始化清单共用。
    func enableTouchIDUnlock() {
        guard phase == .unlocked, !password.isEmpty else {
            Log.warn("keychain", "enableTouchIDUnlock skipped (phase=\(phase), password empty=\(password.isEmpty))")
            return
        }
        PasswordStore.savePasswordForBiometric(password, databaseName: databaseName)
    }

    /// LockedState biometric unlock: prompts Touch ID, then unlocks.
    func unlockWithTouchID() {
        guard phase == .locked, settings.fastUnlock else {
            Log.debug("keychain", "unlockWithTouchID skipped (phase=\(phase), fastUnlock=\(settings.fastUnlock))")
            return
        }
        Log.info("keychain", "Touch ID unlock requested for \"\(databaseName)\"")
        PasswordStore.biometricPassword(databaseName: databaseName) { [weak self] pw in
            guard let pw else {
                Log.warn("keychain", "Touch ID evaluation failed or cancelled")
                return
            }
            // evaluatePolicy 完成回调在系统私有队列;经 @MainActor 任务回主线程再解锁
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try self.unlock(name: self.databaseName, password: pw)
                } catch {
                    Log.warn("keychain", "Touch ID unlock failed at load: \(error)")
                }
            }
        }
    }

    /// 自毁计数滑窗:间隔超过它的两次失败不累计(防跨天/隔周误攒)。
    private static let failedAttemptWindow: TimeInterval = 15 * 60
    private var lastFailedUnlockAt: Date?

    func registerFailedAttempt() {
        if let last = lastFailedUnlockAt, Date().timeIntervalSince(last) > Self.failedAttemptWindow {
            failedUnlockAttempts = 0
        }
        lastFailedUnlockAt = Date()
        failedUnlockAttempts += 1
        let limit = settings.selfDestructAttempts
        Log.warn("lifecycle", "failed unlock attempt #\(failedUnlockAttempts)" + (limit > 0 ? " (self-destruct at \(limit))" : ""))
        if limit > 0, failedUnlockAttempts >= limit {
            eraseAllData()
        }
    }

    /// erase_data_command — removes local data (cloud copies untouched).
    /// 自毁/手动擦除必须连 Safari 快照、泄露哈希清单与 relay 登录态一并清:
    /// 残留的密文+信封可被离线爆破,残留令牌可枚举账户。
    func eraseAllData() {
        Log.warn("lifecycle", "ERASE ALL DATA (self-destruct or manual)")
        for db in store.list() {
            try? store.delete(name: db.name)
        }
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.upasswords.shared") {
            try? FileManager.default.removeItem(at: group.appendingPathComponent("Safari", isDirectory: true))
        }
        CompromisedService.clearDynamicList()
        relay.logout(database: databaseName)
        database = PasswordDatabase()
        databaseName = ""
        password = ""
        phase = .setup
    }

    // MARK: - Persistence

    /// 提交配套本体/状态/信封;失败可能已落 journal,必须废弃旧会话防止覆盖前滚结果。
    /// - Throws: 事务持久化错误。
    func commitSyncSnapshot(_ snapshot: PasswordDatabase, name: String, vaultKey: SymmetricKey,
                            state: RowSyncState, envelope: Data? = nil) throws {
        do {
            try store.commitSyncSnapshot(snapshot, name: name, vaultKey: vaultKey,
                                         state: state, envelope: envelope)
        } catch {
            saveDebounce?.cancel()
            syncSessionID = UUID()
            lock()
            password = ""
            self.vaultKey = nil
            syncState = .error(error.localizedDescription)
            Log.error("sync", "snapshot commit failed; session invalidated: \(error)")
            AppToast.shared.show(error.localizedDescription)
            throw error
        }
    }

    func save() {
        guard phase == .unlocked else { return }
        do {
            // 解锁路径必持库密钥;缺失说明会话状态异常,绝不能退化为其他写法
            guard let vaultKey else {
                Log.error("db", "save \"\(databaseName)\" aborted: no vault key in session")
                return
            }
            try store.save(database, name: databaseName, vaultKey: vaultKey)
            SafariSnapshotBridge.push(databaseName: databaseName, store: store)
        } catch {
            Log.error("db", "save \"\(databaseName)\" failed: \(error)")
            AppToast.shared.show(error.localizedDescription)
        }
    }

    private var saveDebounce: AnyCancellable? = nil
    func saveDebounced() {
        saveDebounce?.cancel()
        saveDebounce = Just(())
            .delay(for: .milliseconds(600), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.save() }
    }

    // MARK: - Search (防抖输入,过滤逻辑在 AppContext+CardList)

    /// 防抖间隔:停顿该时长后才把搜索文本应用到列表。
    private static let searchDebounceInterval = Duration.milliseconds(200)

    /// 搜索输入防抖器:逐键 setSearchText 只记录文本,停顿后一次性发布 searchQuery。
    private lazy var searchDebouncer = SearchInputDebouncer(interval: Self.searchDebounceInterval) { [weak self] text in
        guard let self, self.searchQuery != text else { return }
        self.searchQuery = text
        Log.info("ui", "search apply chars=\(text.count)")
    }

    /// TextField 绑定入口:记录文本并重排防抖;清空立即生效(列表即时恢复)。
    func setSearchText(_ text: String) {
        searchText = text
        searchDebouncer.textChanged(text)
    }

    /// 清空搜索(搜索框 ✕ 按钮):立即生效,不等防抖。
    func clearSearch() {
        guard !searchText.isEmpty || !searchQuery.isEmpty else { return }
        searchText = ""
        searchDebouncer.clear()
        // searchText 非 @Published,手动通知一次以刷新搜索框显示
        objectWillChange.send()
        Log.info("ui", "search clear")
    }

    // MARK: - Auto-lock (LockedState + auto_lock_setting)

    private func installActivityMonitor() {
        autoLockTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.autoLockTick() }
        }
        // Any interaction with the app (typing, clicks, scrolling) counts as
        // activity for the idle timer — not just switching the selected card.
        // 本地事件监视器总在主线程触发;直接记录,避免每个按键/滚动事件都
        // 创建一次 Task(高频事件下造成不必要的调度开销)。
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] event in
            MainActor.assumeIsolated { self?.touch() }
            return event
        }
        NSApplication.shared.publisher(for: \.isHidden)
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] hidden in
                if hidden == true, self?.settings.lockInBackground == true {
                    Log.info("autolock", "app hidden → locking (lockInBackground)")
                    self?.lock()
                }
            }
            .store(in: &cancellables)
    }

    private func autoLockTick() {
        guard phase == .unlocked, settings.autoLockSeconds > 0 else { return }
        let idle = Date().timeIntervalSince(lastActivity)
        if idle >= Double(settings.autoLockSeconds) {
            Log.info("autolock", "idle \(Int(idle))s ≥ autoLockSeconds=\(settings.autoLockSeconds) → locking")
            lock()
        }
    }

    func touch() { lastActivity = Date() }
}
