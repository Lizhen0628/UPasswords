import Foundation

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
    }

    public var databasesDir: URL { root.appendingPathComponent("Databases", isDirectory: true) }
    public var backupsDir: URL { root.appendingPathComponent("Backups", isDirectory: true) }

    public func url(for name: String) -> URL { databasesDir.appendingPathComponent("\(name).upw") }

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
        let plain = db.xmlData()
        let enc = try DatabaseCipher.encryptedData(plain, password: password)
        do {
            try enc.write(to: url(for: name))
        } catch {
            Log.error("db", "create \"\(name).upw\" write failed: \(error)")
            throw error
        }
        PasswordStore.savePassword(password, databaseName: name)
        Log.info("db", "created \"\(name).upw\" (\(enc.count)B, \(Int(Date().timeIntervalSince(t0) * 1000))ms) at \(url(for: name).path)")
        return DatabaseFile(name: name, fileName: "\(name).upw", created: now, isMain: list().isEmpty)
    }

    public func load(name: String, password: String) throws -> PasswordDatabase {
        let t0 = Date()
        let data: Data
        do {
            data = try Data(contentsOf: url(for: name))
        } catch {
            Log.error("db", "load \"\(name).upw\" unreadable: \(error)")
            throw error
        }
        let plain = try DatabaseCipher.decryptedData(data, password: password)
        let db = try PasswordDatabase.parse(plain)
        Log.debug("db", "loaded \"\(name).upw\" (\(data.count)B, \(Int(Date().timeIntervalSince(t0) * 1000))ms)")
        return db
    }

    public func save(_ db: PasswordDatabase, name: String, password: String) throws {
        let t0 = Date()
        let enc = try DatabaseCipher.encryptedData(db.xmlData(), password: password)
        try enc.write(to: url(for: name), options: .atomic)
        Log.debug("db", "saved \"\(name).upw\" (\(enc.count)B, \(Int(Date().timeIntervalSince(t0) * 1000))ms)")
    }

    public func rename(_ old: String, to new: String) throws {
        guard exists(old) else { throw StoreError(L10n.t("database_not_fond_error")) }
        guard !exists(new) else { throw StoreError(L10n.t("database_already_exists_error")) }
        guard new.range(of: "^[A-Za-z0-9]+$", options: .regularExpression) != nil else {
            throw StoreError(L10n.t("database_name_error"))
        }
        Log.info("db", "rename \"\(old)\" → \"\(new)\"")
        try fm.moveItem(at: url(for: old), to: url(for: new))
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

    public func backup(name: String, password: String, now: Date = Date()) throws {
        let dir = backupDir(for: name)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try Data(contentsOf: url(for: name))
        let stamp = Self.backupStampFormatter.string(from: now)
        try data.write(to: dir.appendingPathComponent("\(stamp).upw"))
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
        guard DatabaseCipher.checkFileMagic(data) else {
            Log.error("backup", "restore rejected: wrong file magic in \(backup.lastPathComponent)")
            throw StoreError(L10n.t("wrong_database_format_error"))
        }
        try data.write(to: url(for: name), options: .atomic)
    }

    public struct StoreError: LocalizedError {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }
}
