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

    // MARK: 立即备份

    /// 手动备份:落盘当前库后复制一份带时间戳的快照(保留最近 10 份)。
    func backupNow() {
        persist()
        do {
            try store.backup(name: databaseName, password: password)
            Log.info("backup", "ios manual backup of \"\(databaseName)\" ok")
            showToast(L10n.t("database_saved_message") + " " + L10n.t("backup_command"))
        } catch {
            Log.error("backup", "ios manual backup of \"\(databaseName)\" failed: \(error)")
            showToast(error.localizedDescription)
        }
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
        do {
            try store.backup(name: databaseName, password: password)
            d.set(Date().timeIntervalSince1970, forKey: Self.backupLastKeyPrefix + databaseName)
            Log.info("backup", "ios auto backup of \"\(databaseName)\" ok (interval \(days)d)")
        } catch {
            Log.error("backup", "ios auto backup of \"\(databaseName)\" failed: \(error)")
        }
    }

    // MARK: 恢复 / 删除

    /// 恢复备份:备份内容覆盖当前库文件,随后立即锁定(备份的主密码可能与当前不同)。
    func restoreBackup(_ url: URL) {
        do {
            try store.restore(backup: url, to: databaseName)
            lock()
            reloadPerDatabaseState()
            Log.info("backup", "ios restored \"\(url.lastPathComponent)\" → \"\(databaseName)\" (locked for unlock)")
            showToast(L10n.t("ios_backup_restored_message"))
        } catch {
            Log.error("backup", "ios restore \"\(url.lastPathComponent)\" failed: \(error)")
            showToast(error.localizedDescription)
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
