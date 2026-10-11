import Foundation
import CryptoKit

import UPasswordsCore

/// Databases live in `~/Library/Application Support/UPasswords/Databases/<name>.upw`.
public struct DatabaseFile: Codable, Identifiable, Equatable {
    public init(name: String, fileName: String, created: Date, isMain: Bool) {
        self.name = name
        self.fileName = fileName
        self.created = created
        self.isMain = isMain
    }

    public var id: String { name }
    public var name: String
    public var fileName: String         // "<name>.upw"
    public var created: Date
    public var isMain: Bool
}

public final class DatabaseStore {
    public static let shared = DatabaseStore()

    public let root: URL
    private let fm = FileManager.default

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

    public var databasesDir: URL { root.appendingPathComponent("Databases", isDirectory: true) }
    public var backupsDir: URL { root.appendingPathComponent("Backups", isDirectory: true) }

    public func url(for name: String) -> URL { databasesDir.appendingPathComponent("\(name).upw") }
    /// v2 信封文件路径:库密钥由主密码包裹存放在此(<名>.upwkey)。
    public func keyURL(for name: String) -> URL { databasesDir.appendingPathComponent("\(name).upwkey") }

    public var mainDatabaseName: String {
        get { UserDefaults.standard.string(forKey: "db.main") ?? "Main" }
        set { UserDefaults.standard.set(newValue, forKey: "db.main") }
    }

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

    public func exists(_ name: String) -> Bool { fm.fileExists(atPath: url(for: name).path) }

    @discardableResult
    public func create(name: String, password: String, now: Date = Date()) throws -> DatabaseFile {
        guard !name.isEmpty else { throw StoreError(L10n.t("database_name_error")) }
        guard name.range(of: "^[A-Za-z0-9]+$", options: .regularExpression) != nil else {
            throw StoreError(L10n.t("database_name_error"))
        }
        guard !exists(name) else { throw StoreError(L10n.t("database_already_exists_error")) }
        let t0 = Date()
        let db = PasswordDatabase.createDefault(now: now)
        let vek = DatabaseCipher.generateVaultKey()
        let enc = try DatabaseCipher.encryptBody(db.xmlData(), vaultKey: vek)
        let envelope = try DatabaseCipher.wrapVaultKey(vek, password: password)
        do {
            try enc.write(to: url(for: name))
            try envelope.write(to: keyURL(for: name))
        } catch {
            Log.error("db", "create \"\(name).upw\" write failed: \(error)")
            throw error
        }
        PasswordStore.savePassword(password, databaseName: name)
        Log.info("db", "created \"\(name).upw\" v2 (\(enc.count)B + envelope, \(Int(Date().timeIntervalSince(t0) * 1000))ms)")
        return DatabaseFile(name: name, fileName: "\(name).upw", created: now, isMain: list().isEmpty)
    }

    /// 解锁加载:v2 容器用主密码解信封拿到库密钥再解本体。
    /// - Returns: 数据库与库密钥(会话期持有,保存时直接使用)
    /// - Throws: 非 v2 容器抛 wrong_database_format_error;信封缺失抛
    ///   envelope_missing_error;主密码错误由 unwrapVaultKey 抛 wrong_password_error
    public func loadUnlocked(name: String, password: String) throws -> (PasswordDatabase, SymmetricKey) {
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

    public func load(name: String, password: String) throws -> PasswordDatabase {
        try loadUnlocked(name: name, password: password).0
    }

    /// v2 保存:仅需库密钥(与主密码无关,改密后保存不受影响)。
    public func save(_ db: PasswordDatabase, name: String, vaultKey: SymmetricKey) throws {
        let t0 = Date()
        let enc = try DatabaseCipher.encryptBody(db.xmlData(), vaultKey: vaultKey)
        try enc.write(to: url(for: name), options: .atomic)
        Log.debug("db", "saved \"\(name).upw\" v2 (\(enc.count)B, \(Int(Date().timeIntervalSince(t0) * 1000))ms)")
    }

    /// 写入外来信封原始字节(云端恢复/文件导入随本体一并带回的信封)。
    /// 保留原始 changedAt,避免误触发改密时间戳判定。
    /// - Throws: 字节不是合法信封时抛 envelope_missing_error
    public func saveEnvelope(_ data: Data, for name: String) throws {
        guard DatabaseCipher.envelopeChangedAt(data) != nil else {
            Log.error("db", "saveEnvelope \"\(name)\" rejected: not a valid envelope")
            throw DatabaseCipher.CipherError(message: L10n.t("envelope_missing_error"))
        }
        try data.write(to: keyURL(for: name), options: .atomic)
    }

    /// v2 改密:只重写信封(本体不动);调用方负责更新钥匙串。
    public func rewrap(name: String, vaultKey: SymmetricKey, newPassword: String) throws {
        let envelope = try DatabaseCipher.wrapVaultKey(vaultKey, password: newPassword)
        try envelope.write(to: keyURL(for: name), options: .atomic)
        Log.info("db", "rewrapped \"\(name).upwkey\" (envelope only, body untouched)")
    }

    /// 读本地信封(同步上传信封时用)。
    public func envelopeData(for name: String) -> Data? {
        try? Data(contentsOf: keyURL(for: name))
    }

    public func rename(_ old: String, to new: String) throws {
        guard exists(old) else { throw StoreError(L10n.t("database_not_fond_error")) }
        guard !exists(new) else { throw StoreError(L10n.t("database_already_exists_error")) }
        guard new.range(of: "^[A-Za-z0-9]+$", options: .regularExpression) != nil else {
            throw StoreError(L10n.t("database_name_error"))
        }
        Log.info("db", "rename \"\(old)\" → \"\(new)\"")
        try fm.moveItem(at: url(for: old), to: url(for: new))
        if fm.fileExists(atPath: keyURL(for: old).path) {
            try? fm.moveItem(at: keyURL(for: old), to: keyURL(for: new))
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

    public func delete(name: String, alsoBackups: Bool = true) throws {
        guard exists(name) else { return }
        Log.warn("db", "delete \"\(name).upw\" (alsoBackups=\(alsoBackups))")
        try fm.removeItem(at: url(for: name))
        try? fm.removeItem(at: keyURL(for: name))
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

    public func backupDir(for name: String) -> URL { backupsDir.appendingPathComponent(name, isDirectory: true) }

    public func backup(name: String, now: Date = Date()) throws {
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

    public static let backupStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

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

    public func restore(backup: URL, to name: String) throws {
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

    public struct StoreError: LocalizedError {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }
}
