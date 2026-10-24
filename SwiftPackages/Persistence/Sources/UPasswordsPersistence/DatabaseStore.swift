import Foundation
import CryptoKit

import UPasswordsCore

/// Databases live in `~/Library/Application Support/UPasswords/Databases/<name>.upw`.
public struct DatabaseFile: Codable, Identifiable, Equatable {
    /// 创建本地库文件描述，不执行文件访问。
    ///
    /// - Parameters:
    ///   - name: 本地库名。
    ///   - fileName: 含扩展名的本体文件名。
    ///   - created: 文件创建时间。
    ///   - isMain: 是否为默认主库。
    public init(name: String, fileName: String, created: Date, isMain: Bool) {
        self.name = name
        self.fileName = fileName
        self.created = created
        self.isMain = isMain
    }

    /// 当前本地库名，重命名后此界面身份随之变化。
    public var id: String { name }
    /// 本地库名，也是文件路径派生依据。
    public var name: String
    /// 数据库本体文件名，包含 .upw 扩展名。
    public var fileName: String         // "<name>.upw"
    /// 文件系统记录的创建日期。
    public var created: Date
    /// 此库是否为当前默认选择的主库。
    public var isMain: Bool
}

/// 本地加密库、信封、同步状态与备份文件的存储入口。
///
/// 根目录可注入以支持 App Group 和隔离测试。同步事务用进程内递归锁串行化，
/// 不等同于跨进程文件锁；调用方仍须处理主应用与扩展的会话和刷新边界。
public final class DatabaseStore {
    /// 使用默认 Application Support 根目录的进程共享存储实例。
    public static let shared = DatabaseStore()

    /// 本实例的存储根目录；所有库文件和备份均由此派生。
    public let root: URL
    private let fm = FileManager.default
    // 同一进程的多个 Store 实例也必须串行访问事务组件。
    private static let syncTransactionLock = NSRecursiveLock()
    var transactionFaultInjector: ((String) throws -> Void)?

    /// 创建指向指定根目录的存储实例，并尝试准备数据和备份目录。
    ///
    /// - Parameter root: 注入目录；nil 使用系统 Application Support 并尝试旧目录迁移。
    public init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.root = base.appendingPathComponent("UPasswords", isDirectory: true)
        }
        try? fm.createDirectory(at: databasesDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: backupsDir, withIntermediateDirectories: true)
        // 仅默认根目录(真实应用数据位置)才尝试迁移;测试注入的临时目录跳过
        if root == nil { migrateFromLegacyIfNeeded() }
    }

    /// macOS 沙盒化迁移:旧(未沙盒)路径里的数据项拷入容器(逐项跳过已存在者,
    /// 可重复执行)。依赖临时例外 entitlement 读旧目录;读不到时静默跳过。
    private func migrateFromLegacyIfNeeded() {
        #if os(macOS)
        // 沙盒下 NSHomeDirectoryForUser 也返回容器路径;POSIX getpwuid 才是真家目录
        guard let pw = getpwuid(getuid()), let pwDir = pw.pointee.pw_dir else { return }
        let legacy = URL(fileURLWithPath: String(cString: pwDir))
            .appendingPathComponent("Library/Application Support/UPasswords", isDirectory: true)
        guard legacy.path != root.path, fm.fileExists(atPath: legacy.path) else { return }
        do {
            let items = try fm.contentsOfDirectory(atPath: legacy.path)
            // 只补本地缺失的项,容器里已有的(含迁移后新建的)一律不动
            let missing = items.filter { !fm.fileExists(atPath: root.appendingPathComponent($0).path) }
            guard !missing.isEmpty else { return }
            for item in missing {
                try fm.copyItem(at: legacy.appendingPathComponent(item),
                                to: root.appendingPathComponent(item))
            }
            Log.info("db", "migrated \(missing.count)/\(items.count) item(s) from legacy Application Support into sandbox container")
        } catch {
            Log.warn("db", "legacy data migration skipped: \(error)")
        }
        #endif
    }

    /// 存放加密本体、信封、同步状态和事务暂存文件的目录。
    public var databasesDir: URL { root.appendingPathComponent("Databases", isDirectory: true) }
    /// 按本地库名分目录保存的备份根目录。
    public var backupsDir: URL { root.appendingPathComponent("Backups", isDirectory: true) }

    /// 派生数据库本体文件 URL，不执行读写或库名校验。
    ///
    /// - Parameter name: 已验证的本地库名。
    /// - Returns: Databases 下对应的 .upw 文件位置。
    public func url(for name: String) -> URL { databasesDir.appendingPathComponent("\(name).upw") }
    /// v2 信封文件路径:库密钥由主密码包裹存放在此(<名>.upwkey)。
    public func keyURL(for name: String) -> URL { databasesDir.appendingPathComponent("\(name).upwkey") }

    /// 行级同步游标 sidecar 路径(<名>.upwsync;纯元数据,无敏感值)。
    public func syncStateURL(for name: String) -> URL { databasesDir.appendingPathComponent("\(name).upwsync") }

    private func syncTransactionURL(for name: String) -> URL {
        databasesDir.appendingPathComponent("\(name).upwsync-transaction.json")
    }

    private struct SyncTransaction: Codable {
        let id: UUID
        let includesEnvelope: Bool
        let bodyDigest: Data
        let stateDigest: Data
        let envelopeDigest: Data?
    }

    private func transactionStageURL(name: String, id: UUID, suffix: String) -> URL {
        databasesDir.appendingPathComponent(".\(name).\(id.uuidString).\(suffix).stage")
    }

    /// 完成上次中断的同步提交，再允许读取任一组件。
    /// - Parameter name: 本地数据库名。
    /// - Throws: 事务清单或暂存文件损坏、缺失，或恢复写入失败。
    public func recoverSyncTransaction(for name: String) throws {
        Self.syncTransactionLock.lock()
        defer { Self.syncTransactionLock.unlock() }
        let transactionURL = syncTransactionURL(for: name)
        guard fm.fileExists(atPath: transactionURL.path) else { return }
        let transaction: SyncTransaction
        do {
            transaction = try JSONDecoder().decode(SyncTransaction.self, from: Data(contentsOf: transactionURL))
        } catch {
            Log.error("sync", "transaction journal for \"\(name)\" is unreadable: \(error)")
            throw StoreError(L10n.t("sync_error"))
        }
        let bodyStage = transactionStageURL(name: name, id: transaction.id, suffix: "upw")
        let stateStage = transactionStageURL(name: name, id: transaction.id, suffix: "upwsync")
        let envelopeStage = transactionStageURL(name: name, id: transaction.id, suffix: "upwkey")
        do {
            guard fm.fileExists(atPath: bodyStage.path), fm.fileExists(atPath: stateStage.path),
                  !transaction.includesEnvelope || fm.fileExists(atPath: envelopeStage.path) else {
                throw StoreError(L10n.t("sync_error"))
            }
            let body = try Data(contentsOf: bodyStage)
            let stateData = try Data(contentsOf: stateStage)
            guard DatabaseCipher.isV2Container(body),
                  Data(SHA256.hash(data: body)) == transaction.bodyDigest,
                  Data(SHA256.hash(data: stateData)) == transaction.stateDigest,
                  (try? JSONDecoder().decode(RowSyncState.self, from: stateData)) != nil else {
                throw StoreError(L10n.t("sync_error"))
            }
            if transaction.includesEnvelope {
                let envelope = try Data(contentsOf: envelopeStage)
                guard DatabaseCipher.envelopeChangedAt(envelope) != nil,
                      Data(SHA256.hash(data: envelope)) == transaction.envelopeDigest else {
                    throw StoreError(L10n.t("sync_error"))
                }
            }
            try body.write(to: url(for: name), options: .atomic)
            try transactionFaultInjector?("body")
            try stateData.write(to: syncStateURL(for: name), options: .atomic)
            try transactionFaultInjector?("state")
            if transaction.includesEnvelope {
                let envelope = try Data(contentsOf: envelopeStage)
                try envelope.write(to: keyURL(for: name), options: .atomic)
                try transactionFaultInjector?("envelope")
            }
            try fm.removeItem(at: transactionURL)
            try? fm.removeItem(at: bodyStage)
            try? fm.removeItem(at: stateStage)
            try? fm.removeItem(at: envelopeStage)
            Log.info("sync", "recovered interrupted snapshot commit for \"\(name)\"")
        } catch {
            Log.error("sync", "transaction recovery for \"\(name)\" failed: \(error)")
            throw error
        }
    }

    /// 本体、信封和同步游标在一个恢复事务内提交。
    /// - Parameters:
    ///   - database: 与同步状态配套的数据库快照。
    ///   - name: 本地数据库名。
    ///   - vaultKey: 加密快照的库密钥。
    ///   - state: 此快照的同步游标、修订及脏集合。
    ///   - envelope: 更换库密钥或全量恢复时的配套信封。
    /// - Throws: 加密或写入失败。事务标记写入后仅向前恢复，调用者必须失效旧会话。
    public func commitSyncSnapshot(
        _ database: PasswordDatabase,
        name: String,
        vaultKey: SymmetricKey,
        state: RowSyncState,
        envelope: Data? = nil
    ) throws {
        Self.syncTransactionLock.lock()
        defer { Self.syncTransactionLock.unlock() }
        try recoverSyncTransaction(for: name)
        let body = try DatabaseCipher.encryptBody(database.xmlData(), vaultKey: vaultKey)
        let stateData = try JSONEncoder().encode(state)
        if let envelope, DatabaseCipher.envelopeChangedAt(envelope) == nil {
            throw DatabaseCipher.CipherError(message: L10n.t("envelope_missing_error"))
        }
        let transaction = SyncTransaction(
            id: UUID(),
            includesEnvelope: envelope != nil,
            bodyDigest: Data(SHA256.hash(data: body)),
            stateDigest: Data(SHA256.hash(data: stateData)),
            envelopeDigest: envelope.map { Data(SHA256.hash(data: $0)) }
        )
        let bodyStage = transactionStageURL(name: name, id: transaction.id, suffix: "upw")
        let stateStage = transactionStageURL(name: name, id: transaction.id, suffix: "upwsync")
        let envelopeStage = transactionStageURL(name: name, id: transaction.id, suffix: "upwkey")
        let transactionURL = syncTransactionURL(for: name)
        do {
            try body.write(to: bodyStage, options: .atomic)
            try transactionFaultInjector?("stageBody")
            try stateData.write(to: stateStage, options: .atomic)
            try transactionFaultInjector?("stageState")
            if let envelope {
                try envelope.write(to: envelopeStage, options: .atomic)
                try transactionFaultInjector?("stageEnvelope")
            }
            try JSONEncoder().encode(transaction).write(to: transactionURL, options: .atomic)
        } catch {
            if !fm.fileExists(atPath: transactionURL.path) {
                try? fm.removeItem(at: bodyStage)
                try? fm.removeItem(at: stateStage)
                try? fm.removeItem(at: envelopeStage)
            }
            Log.error("sync", "snapshot staging for \"\(name)\" failed: \(error)")
            throw error
        }
        try transactionFaultInjector?("journal")
        try recoverSyncTransaction(for: name)
        Log.info("sync", "snapshot and sync state committed for \"\(name)\" (cursor=\(state.cursor))")
    }

    /// 读行级同步状态;事务损坏时抛错以避免以空状态覆盖同步基线。
    public func loadSyncState(for name: String) throws -> RowSyncState {
        Self.syncTransactionLock.lock()
        defer { Self.syncTransactionLock.unlock() }
        try recoverSyncTransactionIfPresent(for: name)
        let stateURL = syncStateURL(for: name)
        guard fm.fileExists(atPath: stateURL.path) else { return RowSyncState() }
        let data = try Data(contentsOf: stateURL)
        guard let state = try? JSONDecoder().decode(RowSyncState.self, from: data) else {
            throw StoreError(L10n.t("sync_error"))
        }
        return state
    }

    /// 落盘行级同步状态(游标/revision 映射/脏集合/快照基线)。
    public func saveSyncState(_ state: RowSyncState, for name: String) throws {
        Self.syncTransactionLock.lock()
        defer { Self.syncTransactionLock.unlock() }
        try recoverSyncTransaction(for: name)
        let data = try JSONEncoder().encode(state)
        try data.write(to: syncStateURL(for: name), options: .atomic)
    }

    /// 默认密码库名，通过 UserDefaults 保存。
    public var mainDatabaseName: String {
        get { UserDefaults.standard.string(forKey: "db.main") ?? "Main" }
        set { UserDefaults.standard.set(newValue, forKey: "db.main") }
    }

    /// 枚举本体文件并按库名排序；不解密内容。
    ///
    /// - Returns: 库文件描述；目录读取失败时返回空数组。
    public func list() -> [DatabaseFile] {
        let files = (try? fm.contentsOfDirectory(at: databasesDir, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return files
            .filter { $0.pathExtension == "upw" }
            .map { url in
                let name = url.deletingPathExtension().lastPathComponent
                let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
                return DatabaseFile(name: name, fileName: url.lastPathComponent, created: created, isMain: name == mainDatabaseName)
            }
            .sorted { $0.name < $1.name }
    }

    /// 检查指定库的本体文件是否存在。
    ///
    /// - Parameter name: 本地库名。
    /// - Returns: 只表示 .upw 文件存在，不证明信封齐备或可以解锁。
    public func exists(_ name: String) -> Bool { fm.fileExists(atPath: url(for: name).path) }

    /// 库名只允许字母数字(create 与 rename 共用,防两处规则漂移)。
    private static let databaseNamePattern = "^[A-Za-z0-9]+$"

    private func validateName(_ name: String) throws {
        guard !name.isEmpty else { throw StoreError(L10n.t("database_name_error")) }
        guard name.range(of: Self.databaseNamePattern, options: .regularExpression) != nil else {
            throw StoreError(L10n.t("database_name_error"))
        }
    }

    /// 创建含默认标签与模板的新加密库，并保存密码钥匙串副本。
    ///
    /// - Parameters:
    ///   - name: 仅含字母或数字且未被占用的本地库名。
    ///   - password: 用于包裹新随机库密钥的主密码。
    ///   - now: 新建内容使用的时间，测试可注入固定值。
    /// - Returns: 新库的文件描述。
    /// - Throws: 名称非法、文件已存在、加密或写入失败；信封写入失败时回滚本体。
    @discardableResult
    public func create(name: String, password: String, now: Date = Date()) throws -> DatabaseFile {
        Self.syncTransactionLock.lock()
        defer { Self.syncTransactionLock.unlock() }
        try validateName(name)
        try recoverSyncTransaction(for: name)
        guard !exists(name) else { throw StoreError(L10n.t("database_already_exists_error")) }
        // 首库判定须在写入前取:写完后 list() 必然已含本库
        let isFirstDatabase = list().isEmpty
        let t0 = Date()
        let db = PasswordDatabase.createDefault(now: now)
        let vek = DatabaseCipher.generateVaultKey()
        let enc = try DatabaseCipher.encryptBody(db.xmlData(), vaultKey: vek)
        let envelope = try DatabaseCipher.wrapVaultKey(vek, password: password)
        do {
            // .atomic 与全文件其余写入对齐:崩溃/断电不留半写文件
            try enc.write(to: url(for: name), options: .atomic)
            try envelope.write(to: keyURL(for: name), options: .atomic)
        } catch {
            // 回滚本体:残留无信封的本体会让 exists() 恒真且库永远解不开,
            // 重试建同名库也会被"已存在"拒绝
            try? fm.removeItem(at: url(for: name))
            Log.error("db", "create \"\(name).upw\" write failed: \(error) — body rolled back")
            throw error
        }
        PasswordStore.savePassword(password, databaseName: name)
        Log.info("db", "created \"\(name).upw\" v2 (\(enc.count)B + envelope, \(Int(Date().timeIntervalSince(t0) * 1000))ms)")
        return DatabaseFile(name: name, fileName: "\(name).upw", created: now, isMain: isFirstDatabase)
    }

    private func recoverSyncTransactionIfPresent(for name: String) throws {
        guard fm.fileExists(atPath: syncTransactionURL(for: name).path) else { return }
        try recoverSyncTransaction(for: name)
    }

    /// 解锁加载:v2 容器用主密码解信封拿到库密钥再解本体。
    /// - Returns: 数据库与库密钥(会话期持有,保存时直接使用)
    /// - Throws: 非 v2 容器抛 wrong_database_format_error;信封缺失抛
    ///   envelope_missing_error;主密码错误由 unwrapVaultKey 抛 wrong_password_error
    public func loadUnlocked(name: String, password: String) throws -> (PasswordDatabase, SymmetricKey) {
        Self.syncTransactionLock.lock()
        defer { Self.syncTransactionLock.unlock() }
        try recoverSyncTransactionIfPresent(for: name)
        let t0 = Date()
        let data: Data
        do {
            data = try Data(contentsOf: url(for: name))
        } catch {
            Log.error("db", "load \"\(name).upw\" unreadable: \(error)")
            throw error
        }
        guard DatabaseCipher.isV2Container(data) else {
            Log.warn("db", "load \"\(name).upw\" rejected: not a v2 container")
            throw DatabaseCipher.CipherError(message: L10n.t("wrong_database_format_error"))
        }
        let envelope: Data
        do {
            envelope = try Data(contentsOf: keyURL(for: name))
        } catch {
            Log.error("db", "load \"\(name).upw\" failed: envelope missing (\(error))")
            throw DatabaseCipher.CipherError(message: L10n.t("envelope_missing_error"))
        }
        let vek = try DatabaseCipher.unwrapVaultKey(envelope, password: password)
        let plain = try DatabaseCipher.decryptBody(data, vaultKey: vek)
        let db = try PasswordDatabase.parse(plain)
        Log.debug("db", "loaded \"\(name).upw\" v2 (\(data.count)B, \(Int(Date().timeIntervalSince(t0) * 1000))ms)")
        return (db, vek)
    }

    /// 解锁并加载数据库，丢弃返回的会话库密钥。
    ///
    /// - Parameters:
    ///   - name: 本地库名。
    ///   - password: 主密码。
    /// - Returns: 已解密的数据库值。
    /// - Throws: 与 loadUnlocked 相同的事务恢复、格式、解密及文件错误。
    public func load(name: String, password: String) throws -> PasswordDatabase {
        try loadUnlocked(name: name, password: password).0
    }

    /// v2 保存:仅需库密钥(与主密码无关,改密后保存不受影响)。
    public func save(_ db: PasswordDatabase, name: String, vaultKey: SymmetricKey) throws {
        Self.syncTransactionLock.lock()
        defer { Self.syncTransactionLock.unlock() }
        try recoverSyncTransaction(for: name)
        let t0 = Date()
        let enc = try DatabaseCipher.encryptBody(db.xmlData(), vaultKey: vaultKey)
        try enc.write(to: url(for: name), options: .atomic)
        Log.debug("db", "saved \"\(name).upw\" v2 (\(enc.count)B, \(Int(Date().timeIntervalSince(t0) * 1000))ms)")
    }

    /// 写入外来信封原始字节(云端恢复/文件导入随本体一并带回的信封)。
    /// 保留原始 changedAt,避免误触发改密时间戳判定。
    /// - Throws: 字节不是合法信封时抛 envelope_missing_error
    public func saveEnvelope(_ data: Data, for name: String) throws {
        Self.syncTransactionLock.lock()
        defer { Self.syncTransactionLock.unlock() }
        try recoverSyncTransaction(for: name)
        guard DatabaseCipher.envelopeChangedAt(data) != nil else {
            Log.error("db", "saveEnvelope \"\(name)\" rejected: not a valid envelope")
            throw DatabaseCipher.CipherError(message: L10n.t("envelope_missing_error"))
        }
        try data.write(to: keyURL(for: name), options: .atomic)
    }

    /// v2 改密:只重写信封(本体不动);调用方负责更新钥匙串。
    public func rewrap(name: String, vaultKey: SymmetricKey, newPassword: String) throws {
        Self.syncTransactionLock.lock()
        defer { Self.syncTransactionLock.unlock() }
        try recoverSyncTransaction(for: name)
        let envelope = try DatabaseCipher.wrapVaultKey(vaultKey, password: newPassword)
        try envelope.write(to: keyURL(for: name), options: .atomic)
        Log.info("db", "rewrapped \"\(name).upwkey\" (envelope only, body untouched)")
    }

    /// 读本地信封(同步上传信封时用)。
    public func envelopeData(for name: String) -> Data? {
        Self.syncTransactionLock.lock()
        defer { Self.syncTransactionLock.unlock() }
        do {
            try recoverSyncTransaction(for: name)
            return try Data(contentsOf: keyURL(for: name))
        } catch {
            Log.error("db", "read envelope for \"\(name)\" failed: \(error)")
            return nil
        }
    }

    /// 重命名本体及关联文件，并迁移本地偏好和钥匙串项。
    ///
    /// - Parameters:
    ///   - old: 现有本地库名。
    ///   - new: 未被占用的新合法库名。
    /// - Throws: 名称校验或文件移动失败；云端名称迁移由会话层另行编排。
    public func rename(_ old: String, to new: String) throws {
        Self.syncTransactionLock.lock()
        defer { Self.syncTransactionLock.unlock() }
        try recoverSyncTransaction(for: old)
        try recoverSyncTransaction(for: new)
        guard exists(old) else { throw StoreError(L10n.t("database_not_found_error")) }
        guard !exists(new) else { throw StoreError(L10n.t("database_already_exists_error")) }
        try validateName(new)
        Log.info("db", "rename \"\(old)\" → \"\(new)\"")
        try fm.moveItem(at: url(for: old), to: url(for: new))
        if fm.fileExists(atPath: keyURL(for: old).path) {
            do {
                try fm.moveItem(at: keyURL(for: old), to: keyURL(for: new))
            } catch {
                // 本体已改名、信封遗留旧名:下次解锁会报 envelope_missing,留痕供排查
                Log.error("db", "rename envelope \"\(old).upwkey\" → \"\(new).upwkey\" failed: \(error)")
            }
        }
        if fm.fileExists(atPath: syncStateURL(for: old).path) {
            do {
                try fm.moveItem(at: syncStateURL(for: old), to: syncStateURL(for: new))
            } catch {
                Log.error("db", "rename sync state \"\(old).upwsync\" → \"\(new).upwsync\" failed: \(error)")
            }
        }
        if let pw = PasswordStore.loadPassword(databaseName: old) {
            PasswordStore.savePassword(pw, databaseName: new)
            if PasswordStore.loadPassword(databaseName: old, biometric: true) != nil {
                PasswordStore.savePasswordForBiometric(pw, databaseName: new)
            }
        }
        PasswordStore.eraseData(databaseName: old)
        if mainDatabaseName == old { mainDatabaseName = new }
        renameBackups(of: old, to: new)
    }

    /// 删除本地库文件、相关状态和钥匙串项。
    ///
    /// - Parameters:
    ///   - name: 本地库名。
    ///   - alsoBackups: 是否同时删除该库备份目录，默认为 true。
    /// - Throws: 事务恢复或文件删除失败；不会自行删除云端注册记录。
    public func delete(name: String, alsoBackups: Bool = true) throws {
        Self.syncTransactionLock.lock()
        defer { Self.syncTransactionLock.unlock() }
        try recoverSyncTransaction(for: name)
        guard exists(name) else { return }
        Log.warn("db", "delete \"\(name).upw\" (alsoBackups=\(alsoBackups))")
        try fm.removeItem(at: url(for: name))
        try? fm.removeItem(at: keyURL(for: name))
        try? fm.removeItem(at: syncStateURL(for: name))
        PasswordStore.eraseData(databaseName: name)
        if alsoBackups {
            let dir = backupsDir.appendingPathComponent(name, isDirectory: true)
            try? fm.removeItem(at: dir)
        }
        if mainDatabaseName == name {
            if let first = list().first { mainDatabaseName = first.name }
        }
    }

    // MARK: - Auto backup

    private func renameBackups(of old: String, to new: String) {
        let from = backupsDir.appendingPathComponent(old, isDirectory: true)
        let to = backupsDir.appendingPathComponent(new, isDirectory: true)
        try? fm.moveItem(at: from, to: to)
    }

    /// 返回指定库的备份目录，不保证目录已创建。
    ///
    /// - Parameter name: 本地库名。
    /// - Returns: Backups 下按库名划分的目录。
    public func backupDir(for name: String) -> URL { backupsDir.appendingPathComponent(name, isDirectory: true) }

    /// 复制当前加密本体并尝试保存配套信封，保留最近十份本体备份。
    ///
    /// - Parameters:
    ///   - name: 本地库名。
    ///   - now: 备份文件名使用的时间。
    /// - Throws: 事务恢复、本体读取或备份本体写入失败。信封缺失或写入失败不会抛错，
    ///   因此调用方不可仅凭本方法成功判断该备份一定可恢复。
    public func backup(name: String, now: Date = Date()) throws {
        Self.syncTransactionLock.lock()
        defer { Self.syncTransactionLock.unlock() }
        try recoverSyncTransaction(for: name)
        let dir = backupDir(for: name)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try Data(contentsOf: url(for: name))
        let stamp = Self.backupStampFormatter.string(from: now)
        try data.write(to: dir.appendingPathComponent("\(stamp).upw"))
        // v2 库须连同信封一起备份,否则备份本体无法用主密码解开
        if let envelope = envelopeData(for: name) {
            try? envelope.write(to: dir.appendingPathComponent("\(stamp).upwkey"))
        }
        Log.info("backup", "backup \"\(name)\" → \(stamp).upw (\(data.count)B), kept \(pruneBackups(name: name, keep: 10)) most recent")
    }

    /// 备份文件名时间戳格式；使用 POSIX locale 和当前默认时区。
    public static let backupStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// 按文件修改时间从新到旧列出 .upw 备份。
    ///
    /// - Parameter name: 本地库名。
    /// - Returns: 本体 URL 数组；不校验配套信封是否存在。
    public func backups(name: String) -> [URL] {
        let files = (try? fm.contentsOfDirectory(at: backupDir(for: name), includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "upw" }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return da > db
            }
    }

    @discardableResult
    private func pruneBackups(name: String, keep: Int) -> Int {
        let all = backups(name: name)
        guard all.count > keep else { return all.count }
        for url in all.dropFirst(keep) { try? fm.removeItem(at: url) }
        return keep
    }

    /// 删除单个备份文件(备份列表的删除入口)。
    /// - Parameter name: 数据库名,校验目标确在该库的备份目录内,防止误删他库文件。
    public func deleteBackup(_ url: URL, name: String) throws {
        guard url.deletingLastPathComponent().standardizedFileURL == backupDir(for: name).standardizedFileURL else {
            Log.error("backup", "deleteBackup rejected: \(url.lastPathComponent) is outside \"\(name)\" backup dir")
            throw StoreError(L10n.t("backup_delete_error"))
        }
        try fm.removeItem(at: url)
        Log.info("backup", "backup deleted: \"\(name)\"/\(url.lastPathComponent)")
    }

    /// 校验备份容器和配套信封后，覆盖指定本地库的两个文件。
    ///
    /// - Parameters:
    ///   - backup: .upw 备份文件；同目录必须有同名 .upwkey 信封。
    ///   - name: 被覆盖的本地库名。
    /// - Throws: 文件读取、格式或写入错误；此方法不验证主密码，两个文件分别原子写入。
    public func restore(backup: URL, to name: String) throws {
        Self.syncTransactionLock.lock()
        defer { Self.syncTransactionLock.unlock() }
        try recoverSyncTransaction(for: name)
        Log.info("backup", "restore \(backup.lastPathComponent) → \"\(name).upw\"")
        let data = try Data(contentsOf: backup)
        guard DatabaseCipher.isV2Container(data) else {
            Log.error("backup", "restore rejected: not a v2 container in \(backup.lastPathComponent)")
            throw StoreError(L10n.t("wrong_database_format_error"))
        }
        // v2 本体必须配套信封,否则永远无法解锁
        let keyBackup = backup.deletingPathExtension().appendingPathExtension("upwkey")
        guard let envelope = try? Data(contentsOf: keyBackup),
              DatabaseCipher.envelopeChangedAt(envelope) != nil else {
            Log.error("backup", "restore rejected: envelope missing for \(backup.lastPathComponent)")
            throw StoreError(L10n.t("envelope_missing_error"))
        }
        try data.write(to: url(for: name), options: .atomic)
        try envelope.write(to: keyURL(for: name), options: .atomic)
    }

    /// 本地文件对还原(新设备向导):从任意位置的一对 `<名>.upw`/`<名>.upwkey`
    /// 校验容器格式与主密码,解密解析后落为新的本地库。
    /// 密码与完整性先验通过才写盘,不会留下解不开的半成品。
    /// - Parameters:
    ///   - body: 密码库本体文件(.upw,任意可读位置)
    ///   - envelope: 配套信封文件(.upwkey)
    ///   - name: 落地为本地库的名字(字母数字,不得与现有库重名)
    ///   - password: 该库主密码
    /// - Returns: 新建的本地库文件描述
    /// - Throws: 名字非法或重名同 create;文件不可读 local_files_unreadable_error;
    ///   格式/信封/主密码错误同 loadUnlocked
    @discardableResult
    public func restore(body: URL, envelope: URL, name: String, password: String) throws -> DatabaseFile {
        Self.syncTransactionLock.lock()
        defer { Self.syncTransactionLock.unlock() }
        try validateName(name)
        try recoverSyncTransaction(for: name)
        guard !exists(name) else { throw StoreError(L10n.t("database_already_exists_error")) }
        let data: Data
        let keyData: Data
        do {
            data = try Data(contentsOf: body)
            keyData = try Data(contentsOf: envelope)
        } catch {
            Log.error("db", "restore from local files unreadable (\(body.lastPathComponent)): \(error)")
            throw StoreError(L10n.t("local_files_unreadable_error"))
        }
        guard DatabaseCipher.isV2Container(data) else {
            Log.warn("db", "restore from local files rejected: not a v2 container (\(body.lastPathComponent))")
            throw DatabaseCipher.CipherError(message: L10n.t("wrong_database_format_error"))
        }
        guard DatabaseCipher.envelopeChangedAt(keyData) != nil else {
            Log.warn("db", "restore from local files rejected: invalid envelope (\(envelope.lastPathComponent))")
            throw DatabaseCipher.CipherError(message: L10n.t("envelope_missing_error"))
        }
        let vek = try DatabaseCipher.unwrapVaultKey(keyData, password: password)
        let plain = try DatabaseCipher.decryptBody(data, vaultKey: vek)
        let db = try PasswordDatabase.parse(plain)
        try save(db, name: name, vaultKey: vek)
        try saveEnvelope(keyData, for: name)
        Log.info("db", "restored \"\(name).upw\" from local files (\(data.count)B body, \(db.cards.count) cards)")
        return DatabaseFile(name: name, fileName: "\(name).upw", created: Date(), isMain: list().count == 1)
    }

    /// 本地存储校验或文件管理失败的错误描述。
    public struct StoreError: LocalizedError {
        /// 存储失败的展示描述，不得包含敏感字段或密钥。
        public let message: String
        /// 创建存储错误描述。
        ///
        /// - Parameter message: 不含敏感值的展示消息。
        public init(_ message: String) { self.message = message }
        /// 向界面提供的存储错误描述。
        public var errorDescription: String? { message }
    }
}
