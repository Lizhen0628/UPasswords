import Foundation
import AppKit

/// Databases live in `~/Library/Application Support/UPasswords/Databases/<name>.upw`.
/// Mirrors `DatabaseManager` + `DatabaseConfig` + `DatabaseService` plumbing.
struct DatabaseFile: Codable, Identifiable, Equatable {
    var id: String { name }
    var name: String
    var fileName: String         // "<name>.upw"
    var created: Date
    var isMain: Bool
}

final class DatabaseStore {
    static let shared = DatabaseStore()

    let root: URL
    private let fm = FileManager.default

    init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.root = base.appendingPathComponent("UPasswords", isDirectory: true)
        }
        try? fm.createDirectory(at: databasesDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: backupsDir, withIntermediateDirectories: true)
    }

    var databasesDir: URL { root.appendingPathComponent("Databases", isDirectory: true) }
    var backupsDir: URL { root.appendingPathComponent("Backups", isDirectory: true) }

    func url(for name: String) -> URL { databasesDir.appendingPathComponent("\(name).upw") }

    var mainDatabaseName: String {
        get { UserDefaults.standard.string(forKey: "db.main") ?? "Main" }
        set { UserDefaults.standard.set(newValue, forKey: "db.main") }
    }

    func list() -> [DatabaseFile] {
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

    func exists(_ name: String) -> Bool { fm.fileExists(atPath: url(for: name).path) }

    @discardableResult
    func create(name: String, password: String, now: Date = Date()) throws -> DatabaseFile {
        guard !name.isEmpty else { throw StoreError(L10n.t("database_name_error")) }
        guard name.range(of: "^[A-Za-z0-9]+$", options: .regularExpression) != nil else {
            throw StoreError(L10n.t("database_name_error"))
        }
        guard !exists(name) else { throw StoreError(L10n.t("database_already_exists_error")) }
        let db = PasswordDatabase.createDefault(now: now)
        let plain = db.xmlData()
        let enc = try DatabaseCipher.encryptedData(plain, password: password)
        try enc.write(to: url(for: name))
        PasswordStore.savePassword(password, databaseName: name)
        return DatabaseFile(name: name, fileName: "\(name).upw", created: now, isMain: list().isEmpty)
    }

    func load(name: String, password: String) throws -> PasswordDatabase {
        let data = try Data(contentsOf: url(for: name))
        let plain = try DatabaseCipher.decryptedData(data, password: password)
        return try PasswordDatabase.parse(plain)
    }

    func save(_ db: PasswordDatabase, name: String, password: String) throws {
        let enc = try DatabaseCipher.encryptedData(db.xmlData(), password: password)
        try enc.write(to: url(for: name), options: .atomic)
    }

    func rename(_ old: String, to new: String) throws {
        guard exists(old) else { throw StoreError(L10n.t("database_not_fond_error")) }
        guard !exists(new) else { throw StoreError(L10n.t("database_already_exists_error")) }
        guard new.range(of: "^[A-Za-z0-9]+$", options: .regularExpression) != nil else {
            throw StoreError(L10n.t("database_name_error"))
        }
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

    func delete(name: String, alsoBackups: Bool = true) throws {
        guard exists(name) else { return }
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

    // MARK: - Auto backup (BackupDatabaseTask / AutoBackupModel)

    private func renameBackups(of old: String, to new: String) {
        let from = backupsDir.appendingPathComponent(old, isDirectory: true)
        let to = backupsDir.appendingPathComponent(new, isDirectory: true)
        try? fm.moveItem(at: from, to: to)
    }

    func backupDir(for name: String) -> URL { backupsDir.appendingPathComponent(name, isDirectory: true) }

    func backup(name: String, password: String, now: Date = Date()) throws {
        let dir = backupDir(for: name)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try Data(contentsOf: url(for: name))
        let stamp = Self.backupStampFormatter.string(from: now)
        try data.write(to: dir.appendingPathComponent("\(stamp).upw"))
        pruneBackups(name: name, keep: 10)
    }

    static let backupStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    func backups(name: String) -> [URL] {
        let files = (try? fm.contentsOfDirectory(at: backupDir(for: name), includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "upw" }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return da > db
            }
    }

    private func pruneBackups(name: String, keep: Int) {
        let all = backups(name: name)
        guard all.count > keep else { return }
        for url in all.dropFirst(keep) { try? fm.removeItem(at: url) }
    }

    func restore(backup: URL, to name: String) throws {
        let data = try Data(contentsOf: backup)
        guard DatabaseCipher.checkFileMagic(data) else { throw StoreError(L10n.t("wrong_database_format_error")) }
        try data.write(to: url(for: name), options: .atomic)
    }

    struct StoreError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

/// Mirrors `ClipboardModel` (Models/ClipboardModel.h): copy + auto-clear.
@MainActor
final class ClipboardModel: ObservableObject {
    static let shared = ClipboardModel()

    /// empty_clipboard_setting seconds; 0 = off.
    var clearSeconds: Int {
        UserDefaults.standard.integer(forKey: "clipboard.clearSeconds")
    }

    private var clearTask: Task<Void, Never>? = nil
    private var changeCountAtCopy = 0

    func copy(_ text: String, alert: Bool = true) {
        let pb = NSPasteboard.general
        pb.declareTypes([.string], owner: nil)
        pb.setString(text, forType: .string)
        changeCountAtCopy = pb.changeCount
        if alert {
            AppToast.shared.show(L10n.t("text_copied_message"))
        }
        clearTask?.cancel()
        let secs = clearSeconds
        guard secs > 0 else { return }
        clearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(secs) * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            let pb = NSPasteboard.general
            if pb.changeCount == self.changeCountAtCopy {
                pb.clearContents()
            }
        }
    }

    /// Copies an OTP code with the dedicated message (otp_copied_message).
    func copyOTP(_ code: String) {
        copy(code, alert: false)
        AppToast.shared.show(L10n.t("otp_copied_message"))
    }
}

/// Lightweight toast surface shared by all windows.
@MainActor
final class AppToast: ObservableObject {
    static let shared = AppToast()
    @Published var message: String? = nil
    private var dismissTask: Task<Void, Never>? = nil

    func show(_ text: String) {
        message = text
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            self?.message = nil
        }
    }
}
