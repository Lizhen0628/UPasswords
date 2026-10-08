import SwiftUI
import UIKit
import LocalAuthentication
import UniformTypeIdentifiers
import CryptoKit

import UPasswordsCore
import UPasswordsPersistence
import UPasswordsNetworking

// MARK: - iOS 会话层:真实加密库(.upw)上的数据、锁定、设置与泄露检查
//
// 数据落在 SharedVaultStore(App Group 容器)里的加密容器;
// 主密码经钥匙串存取(PasswordStore),解锁期间仅在内存持有。

@MainActor
final class Vault: ObservableObject {
    static let shared = Vault()

    /// internal setter 供 Vault+Sync 合并/冲突裁决整库替换(见规范 3.7);
    /// 视图仍只经 Vault 方法改数据(规范 14.4)。
    @Published var database = PasswordDatabase()
    @Published private(set) var locked = true
    @Published var toast: String? = nil

    // 设置(共享 defaults,AutoFill 扩展可读面容 ID 开关)
    @Published var faceIDEnabled: Bool { didSet { d.set(faceIDEnabled, forKey: "set.faceID") } }
    @Published var autoLockSeconds: Int { didSet { d.set(autoLockSeconds, forKey: "set.autoLock") } } // 0=立即
    @Published var clipboardClearSeconds: Int { didSet { d.set(clipboardClearSeconds, forKey: "set.clipboard") } } // 0=不清除
    @Published var maskPasswords: Bool { didSet { d.set(maskPasswords, forKey: "set.mask") } }
    @Published var themeIndex: Int { didSet { d.set(themeIndex, forKey: "set.theme") } }
    @Published var sortOrder: SortOrder { didSet { d.set(sortOrder.rawValue, forKey: "set.sort") } }
    @Published var pinFavorites: Bool { didSet { d.set(pinFavorites, forKey: "set.pinFav") } }

    /// 应用内语言覆盖(空 = 跟随系统)。写入 UserDefaults 的 app.language,
    /// 由 Core 的 L10n.activeBundle 每次取词时解析——切换后立即生效。
    @Published var language: String {
        didSet {
            UserDefaults.standard.set(language, forKey: "app.language")
            Log.info("app", "ios language override → \(language.isEmpty ? "system" : language)")
        }
    }

    // 泄露检查状态
    @Published var breachChecking = false
    @Published private(set) var breachResultOffline = false
    /// 上次泄露检查时间(持久化,跨启动保留;internal setter 供 Vault+Security 扩展写入,见规范 3.7)。
    @Published var lastBreachCheck: Date? = nil

    // 自动泄露检查(共享 defaults,与 macOS 同名键)
    @Published var autoBreachCheckEnabled: Bool { didSet { d.set(autoBreachCheckEnabled, forKey: "sec.autoBreachCheck") } }
    @Published var autoBreachCheckDays: Int { didSet { d.set(autoBreachCheckDays, forKey: "sec.autoBreachCheckDays") } }

    // 自动备份(共享 defaults;备份文件存 App Group 容器 Backups/)
    @Published var autoBackupEnabled: Bool { didSet { d.set(autoBackupEnabled, forKey: "set.autoBackup") } }
    @Published var autoBackupIntervalDays: Int { didSet { d.set(autoBackupIntervalDays, forKey: "set.autoBackupDays") } }

    // 云同步设置(共享 defaults;键名与 macOS 一致,便于对照排查)
    @Published var cloudTypeRaw: String { didSet { d.set(cloudTypeRaw, forKey: "sync.cloud") } }
    @Published var webdav: WebDavSettings { didSet { saveWebDav() } }
    @Published var autoSyncEnabled: Bool { didSet { d.set(autoSyncEnabled, forKey: "sync.autoEnabled") } }
    @Published var autoSyncSeconds: Int { didSet { d.set(autoSyncSeconds, forKey: "sync.autoSeconds") } }
    /// 同步进行态与上次成功同步时间(持久化;Vault+Sync 扩展写入)。
    @Published var syncState: SyncPhase = .idle
    @Published var lastSync: Date? = nil
    /// 远端容器用当前密码解不开(常见于改主密码后):设置页据此展示覆盖云端的修复入口。
    @Published var syncRemoteUnreadable = false
    /// 未决同步冲突(密文现场);由 RootView 呈现裁决弹窗。
    @Published var pendingSyncConflict: PendingSyncConflict? = nil
    /// 已选 iCloud 云盘文件夹名(书签本体在共享 defaults,不进 @Published)。
    @Published var icloudFolderName: String = ""
    /// 本地数据库列表(设置页多库管理展示)。
    @Published private(set) var databases: [DatabaseFile] = []
    /// 最近一次同步尝试时间(成功或失败都算;自动同步失败退避用,仅内存)。
    internal var lastSyncAttempt: Date? = nil

    // store/d/databaseName/password/persist() 放宽为 internal:跨文件扩展
    // Vault+Sync/+Security/+Backup 需要访问(驱动、备份、加解密与落盘),见规范 3.7。
    let store = SharedVaultStore.store
    let d = SharedVaultStore.defaults
    internal var databaseName = SharedVaultStore.defaultDatabaseName
    /// 解锁期间内存持有,绝不写入日志/持久化(隐私红线)。
    internal var password = ""
    /// v2 信封加密的库密钥(解锁时由信封解出;保存/同步解密本体用,与主密码解耦)。
    internal var vaultKey: SymmetricKey? = nil
    private var backgroundAt: Date? = nil
    private var toastTask: Task<Void, Never>? = nil
    internal var autoSyncTimer: Timer? = nil
    internal var syncInFlight = false
    internal var breachCheckInFlight = false

    /// 锁屏质感(6 色渐变)。
    static let themes: [(name: String, colors: [Color])] = [
        (L10n.t("ios_theme_charcoal"), [Color(hex: 0x2A2A28), Color(hex: 0x1D1D1C)]),
        (L10n.t("ios_theme_deepsea"), [Color(hex: 0x1E2A38), Color(hex: 0x141B24)]),
        (L10n.t("ios_theme_forest"), [Color(hex: 0x20302A), Color(hex: 0x15211C)]),
        (L10n.t("ios_theme_walnut"), [Color(hex: 0x2E2822), Color(hex: 0x211C18)]),
        (L10n.t("ios_theme_violet"), [Color(hex: 0x272430), Color(hex: 0x1B1922)]),
        (L10n.t("ios_theme_pureblack"), [Color(hex: 0x151515), Color(hex: 0x000000)]),
    ]

    private init() {
        faceIDEnabled = d.object(forKey: "set.faceID") as? Bool ?? false
        autoLockSeconds = d.object(forKey: "set.autoLock") as? Int ?? 60
        clipboardClearSeconds = d.object(forKey: "set.clipboard") as? Int ?? 90
        maskPasswords = d.object(forKey: "set.mask") as? Bool ?? true
        themeIndex = d.object(forKey: "set.theme") as? Int ?? 0
        sortOrder = SortOrder(rawValue: d.object(forKey: "set.sort") as? Int ?? 0) ?? .titleAsc
        pinFavorites = d.object(forKey: "set.pinFav") as? Bool ?? true
        language = UserDefaults.standard.string(forKey: "app.language") ?? ""
        autoBreachCheckEnabled = d.object(forKey: "sec.autoBreachCheck") as? Bool ?? false
        autoBreachCheckDays = d.object(forKey: "sec.autoBreachCheckDays") as? Int ?? 7
        autoBackupEnabled = d.object(forKey: "set.autoBackup") as? Bool ?? false
        autoBackupIntervalDays = d.object(forKey: "set.autoBackupDays") as? Int ?? 7
        cloudTypeRaw = d.string(forKey: "sync.cloud") ?? CloudType.none.rawValue
        if let data = d.data(forKey: "sync.webdav") {
            webdav = (try? JSONDecoder().decode(WebDavSettings.self, from: data)) ?? WebDavSettings()
        } else {
            webdav = WebDavSettings()
        }
        autoSyncEnabled = d.object(forKey: "sync.autoEnabled") as? Bool ?? false
        autoSyncSeconds = d.object(forKey: "sync.autoSeconds") as? Int ?? 60
        if let main = SharedVaultStore.mainDatabase() {
            databaseName = main.name
            if SharedVaultStore.currentDatabaseName == nil {
                SharedVaultStore.currentDatabaseName = main.name
            }
        }
        lastSync = Self.storedDate("sync.last.\(databaseName)")
        lastBreachCheck = Self.storedDate("breach.last.\(databaseName)")
        icloudFolderName = d.string(forKey: "sync.icloud.name") ?? ""
        refreshDatabases()
        Log.info("app", "ios vault init, db=\(databaseName), exists=\(store.exists(databaseName)), cloud=\(cloudTypeRaw)")
    }

    /// 从共享 defaults 读取持久化时间戳(0/缺失 = nil)。
    private static func storedDate(_ key: String) -> Date? {
        let t = SharedVaultStore.defaults.double(forKey: key)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    /// WebDAV 设置经 JSON 编码落共享 defaults。
    private func saveWebDav() {
        if let data = try? JSONEncoder().encode(webdav) {
            d.set(data, forKey: "sync.webdav")
        }
    }

    // MARK: 建库 / 解锁 / 锁定

    /// 尚未创建任何库(首次运行走初始化流程)。
    var hasVault: Bool { store.exists(databaseName) }

    /// 首次创建:建库 + 钥匙串存密码,直接进入解锁态。
    func createVault(password pw: String, biometric: Bool) {
        do {
            _ = try store.create(name: databaseName, password: pw)
            password = pw
            if biometric {
                PasswordStore.savePasswordForBiometric(pw, databaseName: databaseName)
            }
            SharedVaultStore.currentDatabaseName = databaseName
            locked = false
            refreshDatabases()
            Log.info("app", "ios vault created db=\(databaseName) biometric=\(biometric)")
        } catch {
            Log.error("app", "ios vault create failed: \(error)")
            showToast(L10n.t("ios_vault_create_error"))
        }
    }

    @discardableResult
    func unlock(with pw: String) -> Bool {
        guard let (db, vek) = try? store.loadUnlocked(name: databaseName, password: pw) else { return false }
        password = pw
        vaultKey = vek
        database = db
        locked = false
        Log.info("app", "ios vault unlocked db=\(databaseName) cards=\(db.cards.count)")
        healBiometricEntry(with: pw)
        startAutoSyncTickerIfNeeded()
        maybeRunAutoBreachCheck()
        maybeRunAutoBackup()
        return true
    }

    /// 面容 ID 条目自愈:切换/新导入的库还没有 biometric 钥匙串条目,
    /// 用主密码解锁成功后即补录,此后该库也能面容 ID 快速解锁。
    private func healBiometricEntry(with pw: String) {
        guard faceIDEnabled, biometricAvailable,
              !PasswordStore.hasBiometricItem(databaseName: databaseName) else { return }
        PasswordStore.savePasswordForBiometric(pw, databaseName: databaseName)
        Log.info("keychain", "ios biometric entry healed for \(PasswordStore.service(forDatabaseName: databaseName))")
    }

    func verifyMaster(_ pw: String) -> Bool {
        (try? store.load(name: databaseName, password: pw)) != nil
    }

    var biometricAvailable: Bool {
        PasswordStore.biometricAvailable()
    }

    /// 当前库是否已具备面容 ID 快速解锁条件(条目存在才展示/自动触发,
    /// 避免先弹一次验证却发现库里没存密码的尴尬)。
    var canUnlockWithBiometrics: Bool {
        faceIDEnabled && biometricAvailable && PasswordStore.hasBiometricItem(databaseName: databaseName)
    }

    /// 面容 ID 快速解锁结果。
    enum BiometricUnlockOutcome {
        case success
        /// 当前库还没有面容 ID 条目(先主密码解锁一次即自动启用)。
        case notSetUp
        /// 验证未通过/被取消,或存取的密码被拒。
        case failed
    }

    /// 面容 ID 快速解锁:先经系统生物识别门禁(LAContext),通过后才取
    /// 该库的面容 ID 密码条目并解锁。
    func unlockWithBiometrics() async -> BiometricUnlockOutcome {
        guard faceIDEnabled, biometricAvailable else { return .failed }
        let name = databaseName
        let stored: String? = await withCheckedContinuation { continuation in
            PasswordStore.biometricPassword(databaseName: name) { continuation.resume(returning: $0) }
        }
        guard let stored else {
            let enrolled = PasswordStore.hasBiometricItem(databaseName: name)
            Log.warn("keychain", "ios biometric unlock aborted db=\(name) enrolled=\(enrolled)")
            return enrolled ? .failed : .notSetUp
        }
        guard unlock(with: stored) else {
            Log.warn("keychain", "ios biometric unlock: stored password rejected db=\(name)")
            return .failed
        }
        return .success
    }

    /// 修改主密码:校验旧密码后只重写本地信封(v2),并更新钥匙串。
    func changeMasterPassword(old: String, new: String) -> Bool {
        guard verifyMaster(old), new.count >= 4 else { return false }
        guard let vaultKey else {
            Log.error("app", "ios master password change failed: no vault key in session")
            return false
        }
        do {
            try store.rewrap(name: databaseName, vaultKey: vaultKey, newPassword: new)
            password = new
            PasswordStore.savePassword(new, databaseName: databaseName)
            if PasswordStore.hasBiometricItem(databaseName: databaseName) {
                PasswordStore.savePasswordForBiometric(new, databaseName: databaseName)
            }
            Log.info("app", "ios master password changed db=\(databaseName) (envelope rewrapped, body untouched)")
            // 云端接力:只传信封——本体对端用同一库密钥照解,无重传竞态
            if cloudConfigured {
                Task { await uploadCloudEnvelope() }
            } else {
                Log.info("sync", "ios password changed with cloud unconfigured — other devices adopt via next sync")
            }
            return true
        } catch {
            Log.error("app", "ios master password change failed: \(error)")
            return false
        }
    }

    func lock() {
        database = PasswordDatabase()
        password = ""
        vaultKey = nil
        locked = true
        Log.info("app", "ios vault locked")
    }

    func didEnterBackground() {
        if autoLockSeconds == 0 { lockIfNeeded() }
        backgroundAt = Date()
    }

    func didBecomeActive() {
        if autoLockSeconds > 0, let t = backgroundAt,
           Date().timeIntervalSince(t) > TimeInterval(autoLockSeconds) {
            lockIfNeeded()
        }
        backgroundAt = nil
        // 回前台即检查一次自动同步到期(与常驻 ticker 双保险,覆盖后台期间错过的跳数)
        autoSyncTick()
    }

    private func lockIfNeeded() {
        if hasVault && !locked { lock() }
    }

    /// 擦除全部数据(含钥匙串与备份),回到首次设置。
    func eraseAll() {
        do {
            try store.delete(name: databaseName)
            PasswordStore.eraseData(databaseName: databaseName)
            CompromisedService.clearDynamicList()
            PasswordGenerator.instance.clearHistory()
            database = PasswordDatabase()
            password = ""
            locked = true
            SharedVaultStore.currentDatabaseName = nil
            refreshDatabases()
            Log.warn("app", "ios vault erased db=\(databaseName)")
        } catch {
            Log.error("app", "ios vault erase failed: \(error)")
            showToast(L10n.t("ios_vault_erase_error"))
        }
    }

    // MARK: 多数据库管理

    /// 刷新本地数据库列表(设置页展示)。
    func refreshDatabases() {
        databases = store.list()
    }

    /// 切库/改名/导入后重载随库变化的状态(上次同步/上次泄露检查/冲突现场)。
    func reloadPerDatabaseState() {
        lastSync = Self.storedDate("sync.last.\(databaseName)")
        lastBreachCheck = Self.storedDate("breach.last.\(databaseName)")
        pendingSyncConflict = nil
        syncState = .idle
        lastSyncAttempt = nil
    }

    // MARK: 锁屏自定图片(存 App Group 容器,存在即生效)

    private static let lockImageURL = SharedVaultStore.storeRoot.appendingPathComponent("lock-background.jpg")

    /// 当前是否设置了自定锁屏图片。
    var hasLockImage: Bool {
        FileManager.default.fileExists(atPath: Self.lockImageURL.path)
    }

    /// 保存自定锁屏图片:长边压到 ≤2048px 的 JPEG,避免占满容器配额。
    func saveLockImage(_ image: UIImage) {
        let maxSide: CGFloat = 2048
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let target = CGSize(width: (image.size.width * scale).rounded(),
                            height: (image.size.height * scale).rounded())
        let renderer = UIGraphicsImageRenderer(size: target)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
        guard let data = resized.jpegData(compressionQuality: 0.85) else {
            Log.warn("app", "ios lock image encode failed")
            return
        }
        do {
            try data.write(to: Self.lockImageURL, options: .atomic)
            objectWillChange.send()
            Log.info("app", "ios lock image saved (\(data.count)B)")
        } catch {
            Log.error("app", "ios lock image save failed: \(error)")
        }
    }

    /// 移除自定锁屏图片(回到质感渐变背景)。
    func clearLockImage() {
        try? FileManager.default.removeItem(at: Self.lockImageURL)
        objectWillChange.send()
        Log.info("app", "ios lock image cleared")
    }

    func loadLockImage() -> UIImage? {
        guard hasLockImage, let data = try? Data(contentsOf: Self.lockImageURL) else { return nil }
        return UIImage(data: data)
    }

    /// 清除某库的同步基线与时间戳(改名/删除时调用,防串库)。
    private func clearSyncState(for name: String) {
        d.removeObject(forKey: "sync.baseline.local.\(name)")
        d.removeObject(forKey: "sync.baseline.remote.\(name)")
        d.removeObject(forKey: "sync.last.\(name)")
    }

    /// 切换数据库:先验证目标库主密码,成功才切换并直接解锁(与 macOS 一致)。
    /// 失败(密码错)留在当前库,返回 false 由 UI 原地重试。
    @discardableResult
    func switchDatabase(to name: String, password pw: String) -> Bool {
        guard store.exists(name), name != databaseName else { return false }
        guard let (db, vek) = try? store.loadUnlocked(name: name, password: pw) else {
            Log.warn("app", "ios switch database → \"\(name)\" failed: wrong password")
            return false
        }
        persist()
        SharedVaultStore.currentDatabaseName = name
        databaseName = name
        database = db
        password = pw
        vaultKey = vek
        locked = false
        reloadPerDatabaseState()
        healBiometricEntry(with: pw)
        startAutoSyncTickerIfNeeded()
        maybeRunAutoBreachCheck()
        maybeRunAutoBackup()
        Log.info("app", "ios switched database → \"\(name)\" (password verified)")
        return true
    }

    /// 新建数据库并切换为当前库(手上有新主密码,直接解锁进入空库)。
    /// - Returns: 创建是否成功(失败经 toast 展示原因)
    @discardableResult
    func createDatabase(name: String, password pw: String, biometric: Bool) -> Bool {
        do {
            _ = try store.create(name: name, password: pw) // store.create 已写入钥匙串主密码
            if biometric, biometricAvailable {
                PasswordStore.savePasswordForBiometric(pw, databaseName: name)
            }
            SharedVaultStore.currentDatabaseName = name
            databaseName = name
            database = PasswordDatabase()
            password = pw
            locked = false
            reloadPerDatabaseState()
            refreshDatabases()
            Log.info("app", "ios database created name=\(name) biometric=\(biometric)")
            showToast(L10n.t("new_database_created_message"))
            return true
        } catch {
            Log.warn("app", "ios database create \"\(name)\" failed: \(error)")
            showToast(error.localizedDescription)
            return false
        }
    }

    /// 重命名当前数据库(文件/钥匙串/备份由 DatabaseStore.rename 迁移),
    /// 保持解锁状态;同步基线按键随库名更换,下次同步重新建立。
    @discardableResult
    func renameCurrentDatabase(to newName: String) -> Bool {
        guard !locked, newName != databaseName else { return false }
        do {
            let old = databaseName
            try store.rename(old, to: newName)
            clearSyncState(for: old)
            databaseName = newName
            SharedVaultStore.currentDatabaseName = newName
            reloadPerDatabaseState()
            refreshDatabases()
            Log.info("app", "ios database renamed \"\(old)\" → \"\(newName)\"")
            showToast(L10n.t("ios_db_renamed_message"))
            return true
        } catch {
            Log.warn("app", "ios database rename \"\(databaseName)\" failed: \(error)")
            showToast(error.localizedDescription)
            return false
        }
    }

    /// 删除数据库(文件/钥匙串/备份由 DatabaseStore.delete 清理)。
    /// 删除当前库时自动切到剩余第一个库;一个不剩则回到初始化流程。
    func deleteDatabase(_ name: String) {
        do {
            try store.delete(name: name)
            clearSyncState(for: name)
            Log.warn("app", "ios database deleted name=\(name)")
            showToast(L10n.t("ios_db_deleted_message"))
            if name == databaseName {
                if let next = store.list().first {
                    // 删除当前库后的内部转移:无密码可验,切指针并锁定,
                    // 锁屏预填新库名由用户解锁(不同于用户主动切换的验证流程)
                    persist()
                    SharedVaultStore.currentDatabaseName = next.name
                    databaseName = next.name
                    lock()
                    Log.info("app", "ios current database deleted → moved to \"\(next.name)\" (locked)")
                } else {
                    SharedVaultStore.currentDatabaseName = nil
                    databaseName = SharedVaultStore.defaultDatabaseName
                    lock()
                    Log.warn("app", "ios no databases left — returning to setup")
                }
            }
            reloadPerDatabaseState()
            refreshDatabases()
        } catch {
            Log.error("app", "ios database delete \"\(name)\" failed: \(error)")
            showToast(error.localizedDescription)
        }
    }

    // MARK: iCloud 恢复(首次初始化探测云端已有库)

    @Published private(set) var cloudDatabases: [String] = []
    @Published private(set) var cloudChecking = false
    @Published private(set) var importingCloud = false

    /// 首次初始化前探测 iCloud 云端的加密库;iOS 依赖已保存的云盘文件夹
    /// 书签(未选文件夹时保持为空,引导用户到设置里选择)。
    func checkCloudDatabases() async {
        guard cloudDatabases.isEmpty, !cloudChecking else { return }
        guard let mounted = makeCloudDriver() else {
            Log.info("sync", "ios setup probe: no icloud folder bookmark yet")
            return
        }
        cloudChecking = true
        defer { cloudChecking = false }
        defer { mounted.releaseAccess?() }
        do {
            try await mounted.driver.testConnection()
            let names = try await mounted.driver.listDatabases()
            cloudDatabases = names
            Log.info("sync", "ios setup probe: \(names.count) cloud db(s) [\(names.joined(separator: ","))]")
        } catch {
            // 未登录 iCloud/未开云盘属正常路径,不惊扰用户
            Log.info("sync", "ios setup probe: icloud unavailable")
        }
    }

    /// 密码库文件类型(文档选择器导入用;.upw 为自定义扩展)。
    static var vaultFileTypes: [UTType] {
        [UTType(filenameExtension: "upw") ?? .data]
    }

    /// 从文件导入加密库(文档选择器;来源可为 iCloud 云盘/本地/AirDrop)。
    /// 校验容器 magic 后落盘为本地库并切换为当前库,随后锁定等待解锁。
    /// - Returns: 成功返回导入的库名;失败返回 nil(已 toast + 记日志)
    @discardableResult
    func importDatabaseFile(from url: URL) -> String? {
        let name = url.deletingPathExtension().lastPathComponent
        guard !name.isEmpty else {
            showToast(L10n.t("ios_db_import_invalid_message"))
            return nil
        }
        guard !store.exists(name) else {
            Log.warn("db", "ios import file \"\(name)\": local database already exists")
            showToast(L10n.t("local_database_exists_error"))
            return nil
        }
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard DatabaseCipher.checkFileMagic(data) else {
                Log.warn("db", "ios import file \"\(name)\": bad container magic")
                showToast(L10n.t("ios_db_import_invalid_message"))
                return nil
            }
            try data.write(to: store.url(for: name), options: .atomic)
            SharedVaultStore.currentDatabaseName = name
            databaseName = name
            lock()
            reloadPerDatabaseState()
            refreshDatabases()
            // 来源在 iCloud 云盘时顺带配好同步书签,登录后同步开箱即用
            adoptICloudFolderIfUbiquitous(fileURL: url)
            Log.info("db", "ios imported \"\(name).upw\" (\(data.count)B) from file — locked for unlock")
            return name
        } catch {
            Log.error("db", "ios import file \"\(name)\" failed: \(error)")
            showToast(error.localizedDescription)
            return nil
        }
    }

    /// 初始化页「从 iCloud 云盘恢复」:用户选定云端 UPasswords 文件夹后存好书签
    /// (文件夹选择器授予目录级安全作用域,书签才有效)并列出其中的库展示恢复卡片。
    func probeICloudFolder(_ picked: URL) async {
        guard await setICloudFolder(picked) else { return }
        cloudTypeRaw = CloudType.icloud.rawValue
        guard let mounted = makeCloudDriver() else { return }
        defer { mounted.releaseAccess?() }
        do {
            try await mounted.driver.testConnection()
            let names = try await mounted.driver.listDatabases()
            cloudDatabases = names
            Log.info("sync", "ios setup icloud folder probe: \(names.count) db(s) [\(names.joined(separator: ","))]")
            if names.isEmpty { showToast(L10n.t("cloud_database_not_found")) }
        } catch {
            Log.warn("sync", "ios setup icloud folder probe failed: \(error)")
            showToast(error.localizedDescription)
        }
    }

    /// 从 iCloud 下载指定库到本地容器(校验 magic 后落盘)并切换为当前库。
    /// 导入后立即锁定:内存中的主密码属于原库,绝不能带到新库上(防止误写)。
    func importCloudDatabase(name: String) async -> Bool {
        guard !importingCloud else { return false }
        guard !store.exists(name) else {
            Log.warn("sync", "ios import \"\(name)\": local database already exists")
            showToast(L10n.t("local_database_exists_error"))
            return false
        }
        guard let mounted = makeCloudDriver(databaseName: name) else {
            Log.warn("sync", "ios import \"\(name)\": no icloud folder bookmark")
            showToast(L10n.t("not_configured_state"))
            return false
        }
        importingCloud = true
        defer { importingCloud = false }
        defer { mounted.releaseAccess?() }
        do {
            guard let data = try await mounted.driver.download(), DatabaseCipher.checkFileMagic(data) else {
                Log.warn("sync", "ios import \"\(name)\": cloud container missing or bad magic")
                return false
            }
            try data.write(to: store.url(for: name), options: .atomic)
            SharedVaultStore.currentDatabaseName = name
            databaseName = name
            lock()
            reloadPerDatabaseState()
            refreshDatabases()
            Log.info("sync", "ios imported \"\(name).upw\" (\(data.count)B) from iCloud — locked for unlock")
            return true
        } catch {
            Log.warn("sync", "ios import \"\(name)\" failed: \(error)")
            return false
        }
    }

    /// 钥匙串里已存的主密码(同机重装时用于解锁框自动填入;可能为 nil)。
    func storedMasterPassword() -> String? {
        PasswordStore.loadPassword(databaseName: databaseName)
    }

    // MARK: 持久化

    /// 解锁态下整库落盘;internal 供 Vault+Sync 合并后复用。
    func persist() {
        guard !locked else { return }
        do {
            if let vaultKey {
                try store.save(database, name: databaseName, vaultKey: vaultKey)
            } else {
                // 兼容:解锁路径必持库密钥,此处理论不可达;信封兼容写兜底
                try store.save(database, name: databaseName, password: password)
            }
        } catch {
            Log.error("db", "ios save db=\(databaseName) failed: \(error)")
            showToast(L10n.t("ios_vault_save_error"))
        }
    }

    // MARK: Toast 与剪贴板

    func showToast(_ text: String) {
        toastTask?.cancel()
        toast = text
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    func copyToClipboard(_ text: String, label: String = L10n.t("ios_copied_message")) {
        UIPasteboard.general.string = text
        showToast(label)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        let delay = clipboardClearSeconds
        guard delay > 0 else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            if UIPasteboard.general.string == text {
                UIPasteboard.general.string = ""
                self?.showToast(L10n.t("ios_clipboard_cleared_message"))
            }
        }
    }

    // MARK: 条目操作

    var nextId: Int { database.nextItemId() }

    /// 视图层读取的条目集合(非模板)。
    var cards: [Card] { database.cards.filter { !$0.template } }
    var labels: [CardLabel] { database.labels }
    /// 用户自建模板(模板卡中非内置 id 的部分)。
    var customTemplates: [Card] {
        database.cards.filter { $0.template && !TemplateGroups.builtInTemplateIds.contains($0.id) }
    }

    func addCard(_ card: Card) {
        var c = card
        c.created = Date().millis
        c.modified = Date().millis
        database.cards.append(c)
        persist()
        Log.info("app", "ios addCard id=\(c.id) fields=\(c.fields.count)")
    }

    /// 更新条目;密码类字段变更时自动留存历史(Core putHistoryValue 去重保序)。
    func updateCard(_ updated: Card) {
        guard let idx = database.cards.firstIndex(where: { $0.id == updated.id }) else { return }
        let old = database.cards[idx]
        var new = updated
        for i in new.fields.indices {
            if let of = old.fields.first(where: { $0.id == new.fields[i].id }),
               of.value != new.fields[i].value {
                new.fields[i].putHistoryValue(of.value, time: old.modified)
            }
        }
        new.modified = Date().millis
        database.cards[idx] = new
        persist()
        Log.info("app", "ios updateCard id=\(new.id)")
    }

    func toggleFavorite(_ card: Card) {
        guard let idx = database.cards.firstIndex(where: { $0.id == card.id }) else { return }
        database.cards[idx].favorite.toggle()
        persist()
    }

    func setArchived(_ card: Card, _ archived: Bool) {
        guard let idx = database.cards.firstIndex(where: { $0.id == card.id }) else { return }
        database.cards[idx].archived = archived
        persist()
        showToast(archived ? L10n.t("ios_archived_message") : L10n.t("ios_unarchived_message"))
    }

    func trash(_ card: Card) {
        guard let idx = database.cards.firstIndex(where: { $0.id == card.id }) else { return }
        database.cards[idx].trashed = true
        database.cards[idx].favorite = false
        persist()
        showToast(L10n.t("ios_trashed_message"))
    }

    func restore(_ card: Card) {
        guard let idx = database.cards.firstIndex(where: { $0.id == card.id }) else { return }
        database.cards[idx].trashed = false
        persist()
        showToast(L10n.t("ios_restored_message"))
    }

    func deletePermanently(_ card: Card) {
        database.deleteCardPermanently(id: card.id)
        persist()
        Log.warn("app", "ios purgeCard id=\(card.id)")
    }

    func emptyTrash() {
        database.cards.removeAll { $0.trashed && !$0.template }
        persist()
        showToast(L10n.t("ios_trash_emptied_message"))
    }

    func duplicate(_ card: Card) {
        var c = card
        c.id = nextId
        c.title = String(format: L10n.t("ios_duplicate_title_fmt"), card.title)
        c.favorite = false
        c.trashed = false
        c.created = Date().millis
        c.modified = Date().millis
        database.cards.append(c)
        persist()
        showToast(L10n.t("ios_duplicated_message"))
    }

    func saveAsTemplate(_ card: Card) {
        var t = card
        t.template = true
        t.favorite = false
        t.trashed = false
        for i in t.fields.indices { t.fields[i].value = "" }
        database.cards.append(t)
        persist()
        showToast(L10n.t("ios_saved_as_template_message"))
    }

    // MARK: 导入(18 种格式,复用 Persistence 的 ImportFormat)

    /// 按指定导入格式解析文本并合并进当前库。
    /// - Returns: 导入的条目数
    /// - Throws: 格式不识别/解析失败(文案走 ImportError)
    @discardableResult
    func importEntries(text: String, formatId: String) throws -> Int {
        guard let format = ImportFormatFactory.format(id: formatId) else {
            throw ImportError.cannotParse
        }
        Log.info("app", "ios import start format=\(formatId)")
        var db = database
        let n = try format.parse(text, into: &db, now: Date())
        database = db
        persist()
        Log.info("app", "ios import done format=\(formatId) added=\(n)")
        return n
    }

    // MARK: 标签

    func addLabel(name: String, color: String) -> CardLabel {
        let label = CardLabel(id: database.nextItemId(), name: name, color: color, timeStamp: Date().millis)
        database.labels.append(label)
        persist()
        Log.info("app", "ios addLabel id=\(label.id)")
        return label
    }

    func labelsOf(_ card: Card) -> [CardLabel] {
        labels.filter { card.labelIds.contains($0.id) }
    }

    // MARK: 查询

    var activeCards: [Card] { cards.filter { !$0.trashed } }
    var visibleCards: [Card] { activeCards.filter { !$0.archived } }
    var trashedCards: [Card] { cards.filter { $0.trashed } }
    var favoriteCards: [Card] { activeCards.filter { $0.favorite } }
    var archivedCards: [Card] { activeCards.filter { $0.archived } }
    var passkeyCards: [Card] { visibleCards.filter { $0.hasPasskey } }
    var otpCards: [Card] { visibleCards.filter { $0.otpField?.hasValue == true } }
    var wifiCards: [Card] { visibleCards.filter { $0.symbol == "wifi" } }
    var financeCards: [Card] { visibleCards.filter { ["creditcard", "building.columns"].contains($0.symbol ?? "") } }
    var noteCards: [Card] {
        visibleCards.filter { $0.hasNotes && $0.fields.allSatisfy { !$0.hasValue } || $0.symbol == "doc.plaintext" }
    }
    var expiringCards: [Card] { activeCards.filter { $0.isExpiring || $0.isExpired } }
    var recentCards: [Card] { Array(visibleCards.sorted { $0.modified > $1.modified }.prefix(3)) }

    var weakCards: [Card] { activeCards.filter { $0.hasWeakPasswords } }
    var compromisedCards: [Card] { activeCards.filter { $0.compromised } }
    var reusedGroups: [String: [Int]] { SamePasswordsService.groups(cards: activeCards) }
    var reusedCards: [Card] {
        let ids = Set(reusedGroups.values.flatMap { $0 })
        return activeCards.filter { ids.contains($0.id) }
    }

    func search(_ query: String) -> [Card] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return visibleCards.filter { c in
            if c.title.lowercased().contains(q) { return true }
            if c.notes.lowercased().contains(q) { return true }
            return c.fields.contains { $0.type.isSearchable && $0.value.lowercased().contains(q) }
        }
    }

    // MARK: 泄露检查(k-匿名,结果计入本地动态清单)

    func runBreachCheck() async {
        guard !breachChecking else { return }
        breachChecking = true
        defer { breachChecking = false }
        let t0 = Date()
        let passwords = Set(activeCards.flatMap { c in
            c.fields.filter { $0.type.needsScoring && !$0.value.isEmpty }.map(\.value)
        })
        let result = await CompromisedService.check(passwords: passwords)
        CompromisedService.recordBreached(result.compromisedPasswords)
        breachResultOffline = result.offline
        persistBreachCheckTime()
        // 触发 UI 刷新(compromised 依赖本地清单)
        objectWillChange.send()
        Log.info("security", "ios breach check done in \(Int(Date().timeIntervalSince(t0) * 1000))ms, found=\(result.compromisedPasswords.count) offline=\(result.offline)")
        if result.compromisedPasswords.isEmpty {
            showToast(L10n.t("ios_breach_clean_message"))
        } else {
            showToast(String(format: L10n.t("ios_breach_found_fmt"), result.compromisedPasswords.count))
        }
    }

    /// 上次泄露检查时间写共享 defaults(跨启动保留,自动检查按此判到期)。
    func persistBreachCheckTime() {
        d.set(Date().timeIntervalSince1970, forKey: "breach.last.\(databaseName)")
    }

    // MARK: 标签

    /// 更新标签(重命名/改色);同名去重由调用方保证。
    func updateLabel(_ label: CardLabel) {
        guard let idx = database.labels.firstIndex(where: { $0.id == label.id }) else { return }
        database.labels[idx] = label
        persist()
        Log.info("app", "ios updateLabel id=\(label.id)")
    }

    /// 删除标签:标签表移除,并从所有条目的 labelIds 中摘除。
    func deleteLabel(_ label: CardLabel) {
        guard let idx = database.labels.firstIndex(where: { $0.id == label.id }) else { return }
        database.labels.remove(at: idx)
        for i in database.cards.indices {
            database.cards[i].labelIds.removeAll { $0 == label.id }
        }
        persist()
        Log.info("app", "ios deleteLabel id=\(label.id)")
    }
}
