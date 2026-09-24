import Foundation
import SwiftUI
import Combine

/// Central session controller — the SwiftUI counterpart of `DatabaseManager`
/// (Services/DatabaseManager.h) plus the card-list strategies the original
/// implements through `CardListStrategy` subclasses per sidebar label.
///
/// 职责拆分(同类型 extension,便于按域浏览):
/// - 本文件:会话状态、启动引导、锁定/解锁生命周期、持久化、自动锁
/// - AppContext+CardList:侧栏卡片列表策略、搜索、最近打开
/// - AppContext+Actions:卡片/标签 CRUD、初始化清单、历史
/// - AppContext+Sync:修改密码、备份、WebDAV 同步
@MainActor
final class AppContext: ObservableObject {
    enum Phase: Equatable {
        case setup        // SetupWindowController flow (first launch)
        case locked       // LockWindowController
        case unlocked     // MainWindowController
    }

    // MARK: - Published state
    @Published var phase: Phase = .setup {
        didSet { Log.info("lifecycle", "phase \(oldValue) → \(phase)") }
    }
    @Published var database = PasswordDatabase()
    @Published var databaseName: String = "" {
        didSet {
            guard oldValue != databaseName else { return }
            Log.info("lifecycle", "databaseName \"\(oldValue.isEmpty ? "∅" : oldValue)\" → \"\(databaseName.isEmpty ? "∅" : databaseName)\"")
        }
    }
    @Published var selection: SidebarSelection = .special(.allCards)
    @Published var selectedCardId: Int? = nil
    @Published var searchText: String = ""
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
                Log.info("ui", "editDraft \(opened ? "open" : "close") cardId=\(editDraft?.card.id ?? oldValue?.card.id ?? -1) isNew=\(editDraft?.isNew ?? false)")
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
    @Published var lastSyncFailed: Date? = nil
    @Published var failedUnlockAttempts = 0
    // 空闲追踪用,不进 UI。故意不用 @Published:活动监视器把每次键盘/鼠标
    // 事件都算作活动,若发布会在打字时逐键触发整棵视图树重渲染(输入卡顿)。
    var lastActivity: Date = Date()

    enum SyncState: Equatable {
        case disabled, idle, syncing, error(String)
    }

    /// In-memory password, present only while unlocked.
    /// 仅生命周期代码(unlock/lock/erase/changePassword)可写入。
    nonisolated(unsafe) var password: String = ""

    let settings = AppSettings.shared
    let store = DatabaseStore.shared
    private var cancellables = Set<AnyCancellable>()
    private var autoLockTimer: Timer? = nil

    static let shared = AppContext()

    init() {
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
                        var m = EditCardModel(card: Templates.makeCard(from: spec, id: AppContext.shared.newCardId()))
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
            let name = "Safe"
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
                        var m = EditCardModel(card: Templates.makeCard(from: spec, id: AppContext.shared.newCardId()))
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

    // MARK: - Setup / lifecycle (SetupWindowController → DatabaseManager)

    func createDatabase(name: String, password: String, touchID: Bool) throws {
        Log.info("lifecycle", "createDatabase \"\(name)\" touchID=\(touchID) (password length \(password.count))")
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
        Log.info("lifecycle", "unlock \"\(name)\" (password length \(password.count))")
        do {
            database = try store.load(name: name, password: password)
        } catch {
            Log.warn("lifecycle", "unlock \"\(name)\" failed: \(error)")
            throw error
        }
        databaseName = name
        self.password = password
        phase = .unlocked
        lastActivity = Date() // otherwise the idle timer re-locks right after unlocking
        failedUnlockAttempts = 0
        selection = .special(.allCards)
        selectedCardId = database.activeCards.first?.id
        Log.info("lifecycle", "unlocked \"\(name)\": \(database.cards.count) cards, \(database.labels.count) labels")
        scheduleAutoBackupIfNeeded()
        markSetupTaskDoneIf(.cloudSync, when: settings.cloud != .none)
        markSetupTaskDoneIf(.autoBackup, when: settings.autoBackupEnabled)
        markSetupTaskDoneIf(.touchID, when: settings.fastUnlock && PasswordStore.biometricAvailable())
        announceStartupSheets()
    }

    /// WhatsNewSheetController (whats_new.json) + expiring_cards_warning prompt.
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

    /// LockWindowController + LockedState.enter
    func lock() {
        guard phase == .unlocked else { return }
        Log.info("lifecycle", "lock \"\(databaseName)\"")
        password = ""
        phase = .locked
        activeSheet = nil
        editDraft = nil
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

    func registerFailedAttempt() {
        failedUnlockAttempts += 1
        let limit = settings.selfDestructAttempts
        Log.warn("lifecycle", "failed unlock attempt #\(failedUnlockAttempts)" + (limit > 0 ? " (self-destruct at \(limit))" : ""))
        if limit > 0, failedUnlockAttempts >= limit {
            eraseAllData()
        }
    }

    /// erase_data_command — removes local data (cloud copies untouched).
    func eraseAllData() {
        Log.warn("lifecycle", "ERASE ALL DATA (self-destruct or manual)")
        for db in store.list() {
            try? store.delete(name: db.name)
        }
        database = PasswordDatabase()
        databaseName = ""
        password = ""
        phase = .setup
    }

    // MARK: - Persistence

    func save() {
        guard phase == .unlocked else { return }
        do {
            try store.save(database, name: databaseName, password: password)
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
