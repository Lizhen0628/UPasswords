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

    /// UserDefaults 键集中定义:裸字符串散落多文件,任一侧改键即静默失配
    /// (书签/冲突判定/时间戳全面失效)。键名与 macOS 一致,便于对照排查。
    enum DefaultsKey {
        static let autoSyncEnabled = "sync.autoEnabled"
        static let autoSyncSeconds = "sync.autoSeconds"
        /// 基线哈希按库分开:本地与远端均存明文 XML **内容**哈希
        /// (远端不比密文字节——密文每次上传换随机 nonce,同内容重传会被
        /// 误判为远端有修改)。
        static func baselineLocalXML(database: String) -> String { "sync.baseline.local.\(database)" }
        static func baselineRemoteXML(database: String) -> String { "sync.baseline.remote.\(database)" }
        static func lastSync(database: String) -> String { "sync.last.\(database)" }
    }

    // 云同步设置(共享 defaults;键名与 macOS 一致,便于对照排查)
    @Published var autoSyncEnabled: Bool { didSet { d.set(autoSyncEnabled, forKey: DefaultsKey.autoSyncEnabled) } }
    @Published var autoSyncSeconds: Int { didSet { d.set(autoSyncSeconds, forKey: DefaultsKey.autoSyncSeconds) } }
    /// 同步进行态与上次成功同步时间(持久化;Vault+Sync 扩展写入)。
    @Published var syncState: SyncPhase = .idle
    @Published var lastSync: Date? = nil
    /// 远端容器用当前密码解不开(常见于改主密码后):设置页据此展示覆盖云端的修复入口。
    @Published var syncRemoteUnreadable = false
    /// 未决同步冲突(密文现场);由 RootView 呈现裁决弹窗。
    @Published var pendingSyncConflict: PendingSyncConflict? = nil
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
        autoSyncEnabled = d.object(forKey: DefaultsKey.autoSyncEnabled) as? Bool ?? false
        autoSyncSeconds = d.object(forKey: DefaultsKey.autoSyncSeconds) as? Int ?? 60
        if let main = SharedVaultStore.mainDatabase() {
            databaseName = main.name
            if SharedVaultStore.currentDatabaseName == nil {
                SharedVaultStore.currentDatabaseName = main.name
            }
        }
        lastSync = Self.storedDate(DefaultsKey.lastSync(database: databaseName))
        lastBreachCheck = Self.storedDate("breach.last.\(databaseName)")
        refreshDatabases()
        Log.info("app", "ios vault init, db=\(databaseName), exists=\(store.exists(databaseName))")
    }

    /// 从共享 defaults 读取持久化时间戳(0/缺失 = nil)。
    private static func storedDate(_ key: String) -> Date? {
        let t = SharedVaultStore.defaults.double(forKey: key)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
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
        healKeychainEntries(with: pw)
        startAutoSyncTickerIfNeeded()
        maybeRunAutoBreachCheck()
        maybeRunAutoBackup()
        // 引导登录在先的库在此自动补绑;信封先行:解锁后即拉取注册表,
        // 密码被他机修改能立刻提示
        Task {
            await relayBindCurrentVaultIfNeeded()
            await relayRenameCurrentSession()
            await checkRelayPasswordVersion()
        }
        return true
    }

    /// 解锁(带远端兜底):本地解不开时拉远端信封+本体收敛后重试。
    /// 场景:他机改密(始终轮换库密钥)后本机被强制锁定——本地信封已换新,
    /// 但本体还是旧钥密文,新/旧密码都解不开本地副本;远端才是新全套。
    /// 密码真错时远端信封同样解不开 → 仍是密码错误,不误导。
    @discardableResult
    func unlockWithRemoteFallback(with pw: String) async -> Bool {
        if unlock(with: pw) { return true }
        guard let binding = relay.binding(database: databaseName),
              let token = relay.token(database: databaseName) else { return false }
        do {
            let detail = try await relayClient.getVault(token: token, vaultId: binding.vaultId)
            guard let envelopeBytes = detail.envelope,
                  let vek = try? DatabaseCipher.unwrapVaultKey(envelopeBytes, password: pw) else {
                Log.warn("app", "ios remote unlock fallback: password rejected by remote envelope")
                return false
            }
            let body: Data
            do {
                body = try await relayClient.getBody(token: token, vaultId: binding.vaultId)
            } catch {
                Log.warn("sync", "ios remote unlock fallback: rotated body not on relay yet")
                showToast(L10n.t("unlock_remote_body_missing"))
                return false
            }
            let plain = try DatabaseCipher.decryptBody(body, vaultKey: vek)
            let db = try PasswordDatabase.parse(plain)
            try store.save(db, name: databaseName, vaultKey: vek)
            try store.saveEnvelope(envelopeBytes, for: databaseName)
            Log.info("app", "ios remote unlock fallback converged local vault db=\(databaseName)")
            return unlock(with: pw)
        } catch {
            Log.warn("sync", "ios remote unlock fallback failed: \(error)")
            return false
        }
    }

    /// 钥匙串条目自愈:主密码解锁成功后回写密码副本——
    /// ① 主密码条目与输入不符时更新(他机改密后以新密码重新解锁的场景,
    ///    旧副本已在强制锁定时清除或已过期);
    /// ② 开启面容 ID 且尚无 biometric 条目时补录(切换/新导入的库)。
    private func healKeychainEntries(with pw: String) {
        if let stored = PasswordStore.loadPassword(databaseName: databaseName), stored != pw {
            PasswordStore.savePassword(pw, databaseName: databaseName)
            if faceIDEnabled, biometricAvailable {
                PasswordStore.savePasswordForBiometric(pw, databaseName: databaseName)
            }
            Log.info("keychain", "ios password copy healed for \(PasswordStore.service(forDatabaseName: databaseName))")
            return
        }
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

    /// 修改主密码:始终轮换库密钥(全新 VEK + 本体重加密)——旧密文对旧密码
    /// 永久作废,用户无需判断是否轮换。云端顺序:信封先行(他机强制锁定),
    /// 库体随后原子换代。
    func changeMasterPassword(old: String, new: String) -> Bool {
        guard verifyMaster(old), new.count >= PasswordPolicy.minimumMasterPasswordLength else { return false }
        // 只需确认会话持有库密钥;改密轮换用的是下方新生成的 effectiveKey
        guard vaultKey != nil else {
            Log.error("app", "ios master password change failed: no vault key in session")
            return false
        }
        do {
            let effectiveKey = DatabaseCipher.generateVaultKey()
            try store.save(database, name: databaseName, vaultKey: effectiveKey)
            try store.rewrap(name: databaseName, vaultKey: effectiveKey, newPassword: new)
            password = new
            // guard let vaultKey 判空后不再使用;轮换密钥写回会话属性
            self.vaultKey = effectiveKey
            PasswordStore.savePassword(new, databaseName: databaseName)
            if PasswordStore.hasBiometricItem(databaseName: databaseName) {
                PasswordStore.savePasswordForBiometric(new, databaseName: databaseName)
            }
            Log.info("app", "ios master password changed db=\(databaseName) (vault key rotated, body re-encrypted)")
            // 云端接力(账户中继):信封先行(他机强锁定/直接认新密码),库体随后换代
            if relayBound {
                Task {
                    await relayPushEnvelope()
                    let rotated = try? DatabaseCipher.encryptBody(database.xmlData(), vaultKey: effectiveKey)
                    if let rotated {
                        await relayPushBody(cipher: rotated)
                        await relayReportHashes(cipher: rotated)
                    }
                }
            } else {
                Log.info("sync", "ios password changed with relay unbound — other devices adopt via next sync")
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
        // 回前台瞬间再做一次注册表版本检查(轻量单请求,已绑定时):
        // 他机改密即刻感知并强制锁定,不受自动同步间隔约束
        Task { await checkRelayPasswordVersion() }
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
        lastSync = Self.storedDate(DefaultsKey.lastSync(database: databaseName))
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
        d.removeObject(forKey: DefaultsKey.baselineLocalXML(database: name))
        d.removeObject(forKey: DefaultsKey.baselineRemoteXML(database: name))
        d.removeObject(forKey: DefaultsKey.lastSync(database: name))
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
        healKeychainEntries(with: pw)
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
            // 云端身份随改名迁移:网盘三件套改名 + 注册表 PATCH + 绑定换键
            Task { await relayMigrateAfterRename(from: old, to: newName) }
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

    // MARK: 服务端恢复(首次初始化:从账户注册表取回库)

    @Published private(set) var restoringFromRelay = false

    /// 首次初始化时从服务端注册表列出账户名下的库(引导登录在先);
    /// 未登录或拉取失败返回 nil,界面只保留新建/文件导入两条路。
    func relayVaultsForRestore() async -> [RelayClient.VaultRecord]? {
        guard let email = relay.lastAccountEmail,
              let token = relay.token(email: email) else { return nil }
        do {
            let records = try await relayClient.listVaults(token: token)
            Log.info("sync", "ios relay restore list: \(records.count) vault(s) fetched")
            return records
        } catch {
            Log.warn("sync", "ios relay restore list failed: \(error)")
            return nil
        }
    }

    /// 服务端通道恢复(首次初始化):注册表信封 + 服务端库体镜像 →
    /// 解密校验后落为本地库并直接解锁进入应用。前提:该库在服务端有
    /// 库体镜像;绑定与版本基准由解锁后的 relayBindCurrentVaultIfNeeded
    /// 自动补齐(按库名认领现有注册,不产生重复 vaultId)。
    /// - Returns: 成功返回 true(失败已 toast + 记日志)
    @discardableResult
    func restoreFromRelay(record: RelayClient.VaultRecord, password pw: String) async -> Bool {
        guard !restoringFromRelay else { return false }
        guard let email = relay.lastAccountEmail,
              let token = relay.token(email: email) else {
            showToast(L10n.t("not_configured_state"))
            return false
        }
        let name = record.name
        guard !store.exists(name) else {
            Log.warn("lifecycle", "ios restore from relay \"\(name)\" aborted: local database exists")
            showToast(L10n.t("local_database_exists_error"))
            return false
        }
        restoringFromRelay = true
        defer { restoringFromRelay = false }
        Log.info("lifecycle", "ios restore from relay \"\(name)\" (vault=\(record.vaultId.prefix(8))…)")
        do {
            let detail = try await relayClient.getVault(token: token, vaultId: record.vaultId)
            guard let envelope = detail.envelope else {
                Log.warn("lifecycle", "ios restore from relay \"\(name)\": registry has no envelope")
                showToast(L10n.t("envelope_missing_error"))
                return false
            }
            let data: Data
            do {
                data = try await relayClient.getBody(token: token, vaultId: record.vaultId)
            } catch RelayClient.RelayError.notFound {
                Log.warn("lifecycle", "ios restore from relay \"\(name)\": server body mirror missing")
                showToast(L10n.t("cloud_database_not_found"))
                return false
            }
            guard DatabaseCipher.isV2Container(data) else {
                Log.warn("lifecycle", "ios restore from relay \"\(name)\": not a v2 container")
                showToast(L10n.t("ios_db_import_invalid_message"))
                return false
            }
            let vek = try DatabaseCipher.unwrapVaultKey(envelope, password: pw)
            let plain = try DatabaseCipher.decryptBody(data, vaultKey: vek)
            let db = try PasswordDatabase.parse(plain)
            try store.save(db, name: name, vaultKey: vek)
            try store.saveEnvelope(envelope, for: name)
            SharedVaultStore.currentDatabaseName = name
            databaseName = name
            lock()
            reloadPerDatabaseState()
            refreshDatabases()
            guard unlock(with: pw) else {
                Log.error("lifecycle", "ios restore from relay \"\(name)\": unlock after save failed")
                showToast(L10n.t("sync_error"))
                return false
            }
            Log.info("lifecycle", "ios restore from relay \"\(name)\" ok (\(db.cards.count) cards)")
            return true
        } catch {
            Log.warn("lifecycle", "ios restore from relay \"\(name)\" failed: \(error)")
            showToast(error.localizedDescription)
            return false
        }
    }

    /// 密码库文件类型(文档选择器导入用;.upw 为自定义扩展)。
    static var vaultFileTypes: [UTType] {
        [UTType(filenameExtension: "upw") ?? .data]
    }

    /// 从文件导入加密库(文档选择器;来源可为本地/AirDrop/任意云盘的
    /// 手动下载目录)。校验容器 magic 后落盘为本地库并切换为当前库,
    /// 随后锁定等待解锁。
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
            guard DatabaseCipher.isV2Container(data) else {
                Log.warn("db", "ios import file \"\(name)\": not a v2 container")
                showToast(L10n.t("ios_db_import_invalid_message"))
                return nil
            }
            // v2 本体必须连同配套信封(.upwkey)一起导入,否则永远无法解锁。
            // 文档选择器的作用域只覆盖被选文件,同目录信封读取失败即拒绝导入
            let envelopeURL = url.deletingPathExtension().appendingPathExtension("upwkey")
            guard let envelope = try? Data(contentsOf: envelopeURL),
                  DatabaseCipher.envelopeChangedAt(envelope) != nil else {
                Log.warn("db", "ios import file \"\(name)\": sibling envelope missing/unreadable")
                showToast(L10n.t("envelope_missing_error"))
                return nil
            }
            try data.write(to: store.url(for: name), options: .atomic)
            try store.saveEnvelope(envelope, for: name)
            SharedVaultStore.currentDatabaseName = name
            databaseName = name
            lock()
            reloadPerDatabaseState()
            refreshDatabases()
            Log.info("db", "ios imported \"\(name).upw\" (\(data.count)B) from file — locked for unlock")
            return name
        } catch {
            Log.error("db", "ios import file \"\(name)\" failed: \(error)")
            showToast(error.localizedDescription)
            return nil
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
            // 解锁路径必持库密钥;缺失说明会话状态异常,绝不能退化为其他写法
            guard let vaultKey else {
                Log.error("db", "ios save db=\(databaseName) aborted: no vault key in session")
                return
            }
            try store.save(database, name: databaseName, vaultKey: vaultKey)
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
            try? await Task.sleep(for: .seconds(1.6))
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
            try? await Task.sleep(for: .seconds(delay))
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
    /// 刷新时间戳驱动 merge LWW:否则改名永远无法同步到对端(与 macOS 一致)。
    func updateLabel(_ label: CardLabel) {
        guard let idx = database.labels.firstIndex(where: { $0.id == label.id }) else { return }
        var updated = label
        updated.timeStamp = Date().millis
        database.labels[idx] = updated
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
