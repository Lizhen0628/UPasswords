import Foundation

/// 修改密码(SetPasswordSheetController)、备份、WebDAV 云同步(sync:)。
extension AppContext {

    // MARK: - Change password (SetPasswordSheetController / changePassword:)

    func changePassword(current: String, new: String) throws {
        guard current == password else {
            Log.warn("db", "changePassword \"\(databaseName)\" failed: wrong current password")
            throw DatabaseCipher.CipherError(message: L10n.t("wrong_password_error"))
        }
        // re-encrypt under the new password
        try store.save(database, name: databaseName, password: new)
        PasswordStore.savePassword(new, databaseName: databaseName)
        if settings.fastUnlock && PasswordStore.biometricAvailable() {
            PasswordStore.savePasswordForBiometric(new, databaseName: databaseName)
        }
        password = new
        Log.info("db", "changePassword \"\(databaseName)\" ok (re-encrypted)")
    }

    // MARK: - Backup

    func backupNow() {
        save()
        do {
            try store.backup(name: databaseName, password: password)
            Log.info("backup", "manual backup of \"\(databaseName)\" ok")
            AppToast.shared.show(L10n.t("database_saved_message") + " " + L10n.t("backup_command"))
        } catch {
            Log.error("backup", "manual backup of \"\(databaseName)\" failed: \(error)")
            AppToast.shared.show(error.localizedDescription)
        }
    }

    func scheduleAutoBackupIfNeeded() {
        guard settings.autoBackupEnabled, settings.backupIntervalDays > 0 else { return }
        let last = UserDefaults.standard.double(forKey: "backup.last.\(databaseName)")
        let interval = Double(settings.backupIntervalDays) * 86400
        let elapsed = Date().timeIntervalSince1970 - last
        guard elapsed >= interval else {
            Log.debug("backup", "auto-backup not due (elapsed \(Int(elapsed))s < interval \(Int(interval))s)")
            return
        }
        do {
            try store.backup(name: databaseName, password: password)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "backup.last.\(databaseName)")
            Log.info("backup", "auto backup of \"\(databaseName)\" ok")
        } catch {
            Log.error("backup", "auto backup of \"\(databaseName)\" failed: \(error)")
        }
    }

    // MARK: - Cloud sync

    /// sync: — WebDavDriver download/merge/upload.
    func sync() async {
        guard settings.cloud == .webdav else {
            if settings.cloud == .none {
                syncState = .disabled
                Log.debug("sync", "sync skipped: cloud disabled")
                AppToast.shared.show(L10n.t("sync_disabled_state"))
            } else {
                Log.debug("sync", "sync skipped: cloud=\(settings.cloud) not configured")
                AppToast.shared.show(L10n.t("not_configured_state"))
            }
            return
        }
        Log.info("sync", "sync \"\(databaseName)\" started (webdav)")
        syncState = .syncing
        save()
        let driver = WebDavDriver(settings: settings.webdav, databaseName: databaseName)
        do {
            try await driver.testConnection()
            Log.debug("sync", "webdav connection ok")
            let remoteData = try await driver.download()
            var local = database
            if let remoteData {
                let plain = try DatabaseCipher.decryptedData(remoteData, password: password)
                let remote = try PasswordDatabase.parse(plain)
                Log.info("sync", "remote: \(remote.cards.count) cards, \(remote.labels.count) labels; local: \(local.cards.count) cards — merging")
                local.merge(with: remote)
                database = local
                save()
            } else {
                Log.info("sync", "no remote database yet — uploading local")
            }
            let out = try DatabaseCipher.encryptedData(database.xmlData(), password: password)
            try await driver.upload(out)
            let finished = Date()
            lastSync = finished
            syncState = .idle
            Log.info("sync", "sync \"\(databaseName)\" finished (uploaded \(out.count)B)")
            AppToast.shared.show(L10n.t("last_sync_completed_prompt") + " " + DateFormatter.localizedString(from: finished, dateStyle: .short, timeStyle: .short))
        } catch {
            lastSyncFailed = Date()
            syncState = .error(error.localizedDescription)
            Log.error("sync", "sync \"\(databaseName)\" failed: \(error)")
            AppToast.shared.show("\(L10n.t("sync_error")): \(error.localizedDescription)")
        }
    }
}
