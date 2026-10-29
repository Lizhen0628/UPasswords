import Foundation
import UIKit

import UPasswordsCore
import UPasswordsPersistence

// MARK: - 备份:立即备份/自动周期/备份列表与恢复(文件存 App Group 容器 Backups/)

extension Vault {

    static let backupLastKeyPrefix = "backup.last."

    // MARK: 列表

    /// 当前库的备份清单(新→旧)。
    func backups() -> [URL] {
        store.backups(name: databaseName)
    }

    /// Exports a self-contained backup package as a temporary single-file archive for sharing.
    /// - Parameter package: Valid package directory produced by `BackupPackage.capture`.
    /// - Returns: Temporary archive URL, or `nil` after showing a localized error.
    func makePortableBackupArchive(from package: URL) async -> URL? {
        let archiveDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UPasswordsBackupExports", isDirectory: true)
        let archive = archiveDirectory.appendingPathComponent(
            "\(package.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).upwbackup")
        Log.info("backup", "ios portable archive export started for \(package.lastPathComponent)")

        do {
            let exportedArchive = try await Task.detached(priority: .userInitiated) {
                try FileManager.default.createDirectory(
                    at: archiveDirectory,
                    withIntermediateDirectories: true)
                try BackupPackage.exportPortableArchive(from: package, to: archive)
                return archive
            }.value
            Log.info("backup", "ios portable archive export completed for \(package.lastPathComponent)")
            return exportedArchive
        } catch {
            Log.error("backup", "ios portable archive export failed for \(package.lastPathComponent): \(error)")
            showToast(error.localizedDescription)
            return nil
        }
    }

    // MARK: 立即备份

    /// 手动备份:落盘当前库后复制一份带时间戳的快照(保留最近 10 份)。
    func backupNow() {
        persist()
        startBackupCapture(auto: false)
    }

    // MARK: 自动备份

    /// 解锁后调用:开启自动备份且距上次备份超过设定天数时静默备份一份。
    func maybeRunAutoBackup() {
        guard autoBackupEnabled else { return }
        let days = max(autoBackupIntervalDays, 1)
        let last = d.double(forKey: Self.backupLastKeyPrefix + databaseName)
        let elapsed = Date().timeIntervalSince1970 - last
        guard elapsed > TimeInterval(days) * 86_400 else {
            Log.debug("backup", "ios auto-backup not due (elapsed \(Int(elapsed))s < \(days)d)")
            return
        }
        startBackupCapture(auto: true)
    }

    func cancelBackupCapture() {
        backupCaptureTask?.cancel()
        backupCaptureTask = nil
    }

    private func startBackupCapture(auto: Bool) {
        guard !locked, let vaultKey else {
            Log.warn("backup", "ios package capture skipped: vault is locked")
            return
        }
        cancelBackupCapture()
        let name = databaseName
        let sessionID = syncSessionID
        let snapshot = database
        let state = rowSync
        let binding = relay.binding(database: name)
        let token = relay.token(database: name)
        let cloud = binding.flatMap { binding in
            token.map { BackupPackage.CloudSource(client: relayClient, token: $0, vaultID: binding.vaultId) }
        }
        let store = store
        Log.info("backup", "ios \(auto ? "auto" : "manual") package capture started for \"\(name)\"")
        backupCaptureTask = Task { [weak self] in
            do {
                let result = try await BackupPackage.capture(
                    store: store,
                    name: name,
                    database: snapshot,
                    vaultKey: vaultKey,
                    syncState: state,
                    cloud: cloud,
                    cloudRequired: binding != nil)
                guard let self else { return }
                self.backupCaptureTask = nil
                guard !self.locked,
                      self.databaseName == name,
                      self.syncSessionID == sessionID else { return }
                if auto {
                    self.d.set(
                        Date().timeIntervalSince1970,
                        forKey: Self.backupLastKeyPrefix + name)
                }
                let resultText = result.assessment.isComplete
                    ? L10n.t("backup_package_saved_complete")
                    : String(
                        format: L10n.t("backup_package_saved_incomplete_fmt"),
                        result.assessment.issues.count)
                if !auto { self.showToast(resultText) }
                Log.info(
                    "backup",
                    "ios package capture saved \"\(name)\" complete=\(result.assessment.isComplete) issues=\(result.assessment.issues.count)")
            } catch is CancellationError {
                Log.info("backup", "ios package capture cancelled for \"\(name)\"")
            } catch {
                guard let self else { return }
                self.backupCaptureTask = nil
                Log.error("backup", "ios package capture failed for \"\(name)\": \(error)")
                if !auto, !self.locked, self.databaseName == name {
                    self.showToast(error.localizedDescription)
                }
            }
        }
    }

    // MARK: 恢复 / 删除

    /// Restores a local backup as a separately encrypted database without changing the active vault.
    func restoreBackupAsCopy(
        _ url: URL,
        name: String,
        sourcePassword: String,
        newPassword: String,
        expectedPackageVerificationToken: String? = nil,
        allowIncompletePackage: Bool = false
    ) -> String? {
        guard relay.binding(database: name) == nil else {
            return L10n.t("backup_restore_bound_name_error")
        }
        do {
            _ = try store.restoreBackupAsCopy(
                backup: url,
                name: name,
                sourcePassword: sourcePassword,
                newPassword: newPassword,
                expectedPackageVerificationToken: expectedPackageVerificationToken,
                allowIncompletePackage: allowIncompletePackage)
            _ = try nativeStore?.importLegacyIfNeeded(
                name: name, password: newPassword, legacyStore: store)
            refreshDatabases()
            Log.info("backup", "ios restored \"\(url.lastPathComponent)\" as copy \"\(name)\"")
            showToast(String(format: L10n.t("backup_copy_created_fmt"), name))
            return nil
        } catch {
            Log.error("backup", "ios restore \"\(url.lastPathComponent)\" as \"\(name)\" failed: \(error)")
            return error.localizedDescription
        }
    }

    func deleteBackup(_ url: URL) {
        do {
            try store.deleteBackup(url, name: databaseName)
        } catch {
            Log.error("backup", "ios delete backup \"\(url.lastPathComponent)\" failed: \(error)")
        }
    }
}
