import Foundation
import UPasswordsCore
import UPasswordsPersistence

/// 修改密码、备份、云同步(WebDAV / iCloud Drive)。
extension AppContext {

    // MARK: - Change password

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
        // 远端容器仍是旧密码加密:云端已配置则接力重加密(与 iOS 同语义),
        // 否则其他设备下次同步拿到无法解密的远端,走「密码已变更」流程
        if settings.cloud != .none {
            Task { await reencryptCloudAfterPasswordChange(old: current) }
        } else {
            Log.info("sync", "password changed with cloud unconfigured — other devices will see unreadable remote")
        }
    }

    /// 改主密码后的云端接力:旧密码解密远端并合并(防丢对端改动),再用新密码重传。
    /// 同时推送 Safari 快照(密文容器已换密钥,扩展侧下次解锁用新密码)。
    private func reencryptCloudAfterPasswordChange(old: String) async {
        guard let driver = makeCloudDriver() else { return }
        do {
            try await driver.testConnection()
            if let remoteData = try await driver.download(),
               let plain = try? DatabaseCipher.decryptedData(remoteData, password: old),
               let remote = try? PasswordDatabase.parse(plain) {
                var local = database
                local.merge(with: remote)
                database = local
                save()
                Log.info("sync", "cloud handoff: merged remote (\(remote.cards.count) cards) after password change")
            }
            let out = try DatabaseCipher.encryptedData(database.xmlData(), password: password)
            try await driver.upload(out)
            recordSyncBaseline(uploaded: out)
            SafariSnapshotBridge.push(databaseName: databaseName, store: store)
            Log.info("sync", "cloud handoff: remote re-encrypted with new password (\(out.count)B)")
        } catch {
            Log.warn("sync", "cloud handoff after password change failed: \(error)")
        }
    }

    // MARK: - Backup

    func backupNow() {
        save()
        do {
            try store.backup(name: databaseName, password: password)
            Log.info("backup", "manual backup of \"\(databaseName)\" ok")
            AppToast.shared.show(L10n.t("database_saved_message") + " " + L10n.t("backup_command"))
            syncAfterBackup(auto: false)
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
            syncAfterBackup(auto: true)
        } catch {
            Log.error("backup", "auto backup of \"\(databaseName)\" failed: \(error)")
        }
    }

    /// 备份完成后顺带触发一次云同步,把最新本地库推上云端(备份快照仍只存本地)。
    /// auto = true 走静默同步(自动备份场景);手动备份用 auto = false,成败均有 toast。
    /// 云未配置时跳过;已有同步在飞行中时也跳过——那一次同步同样会带走最新数据。
    private func syncAfterBackup(auto: Bool) {
        guard makeCloudDriver() != nil else {
            Log.debug("sync", "sync after backup skipped: cloud not configured")
            return
        }
        guard syncState != .syncing else {
            Log.debug("sync", "sync after backup skipped: another sync in flight")
            return
        }
        Log.info("sync", "sync after \(auto ? "auto" : "manual") backup \"\(databaseName)\"")
        Task { await sync(auto: auto) }
    }

    // MARK: - Cloud sync

    /// 自动同步间隔下限(秒):防止误设过小的间隔频繁打云端。
    private static let minAutoSyncSeconds = 30

    /// 当前云类型对应的同步驱动;none 或尚未实现驱动的网盘返回 nil。
    /// - Parameter name: 覆盖数据库名。云端恢复流程在目标库尚未打开时使用。
    func makeCloudDriver(databaseName name: String? = nil) -> CloudDriver? {
        let dbName = name ?? databaseName
        switch settings.cloud {
        case .webdav:
            return WebDavDriver(settings: settings.webdav, databaseName: dbName)
        case .icloud:
            if let scoped = ScopedICloudFolderDriver(databaseName: dbName,
                                                     bookmark: settings.icloudBookmark,
                                                     mode: settings.icloudFolderMode,
                                                     onRefreshBookmark: { [weak self] data in
                                                         self?.settings.icloudBookmark = data
                                                     }) {
                return scoped
            }
            // 未选文件夹:回落旧直读路径(未沙盒构建可用;沙盒下报 icloudUnavailable)
            return ICloudDriver(databaseName: dbName)
        default:
            return nil
        }
    }

    /// 列出云端已有的数据库(不带 .upw 后缀)——云端恢复流程的文件清单。
    func listCloudDatabases() async throws -> [String] {
        guard let driver = makeCloudDriver() else { throw SyncError.notConfigured }
        try await driver.testConnection()
        let names = try await driver.listDatabases()
        Log.info("sync", "cloud list: \(names.count) database(s) via \(settings.cloud.rawValue)")
        return names
    }

    /// 云端恢复(新设备向导):下载远端 `<name>.upw`,解密校验后落为本地库,
    /// 直接解锁进入主界面——不必"先建库再同步"绕路。
    func restoreDatabaseFromCloud(name: String, password: String) async throws {
        Log.info("lifecycle", "restore from cloud \"\(name)\" (cloud=\(settings.cloud.rawValue))")
        guard let driver = makeCloudDriver(databaseName: name) else { throw SyncError.notConfigured }
        guard !store.exists(name) else {
            Log.warn("lifecycle", "restore from cloud \"\(name)\" aborted: local database exists")
            throw SyncError.localNameConflict
        }
        guard let data = try await driver.download() else {
            Log.warn("lifecycle", "restore from cloud \"\(name)\": not found in cloud")
            throw SyncError.databaseNotFound
        }
        let plain = try DatabaseCipher.decryptedData(data, password: password)
        let db = try PasswordDatabase.parse(plain)
        try store.save(db, name: name, password: password)
        store.mainDatabaseName = name
        try unlock(name: name, password: password)
        markSetupTaskDone(.cloudSync)
        scheduleSilentBreachCheck()
        Log.info("lifecycle", "restore from cloud \"\(name)\" ok (\(db.cards.count) cards)")
    }

    /// 常驻到期 ticker:每 5s 检查一次,距上次同步超过设定间隔即静默同步。
    /// 不随设置变化重排(间隔改动下一跳自然生效);锁屏/未启用时空转,开销可忽略。
    func startAutoSyncTickerIfNeeded() {
        guard autoSyncTimer == nil else { return }
        autoSyncTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.autoSyncTick() }
        }
        Log.debug("sync", "auto-sync ticker installed")
    }

    private func autoSyncTick() {
        guard phase == .unlocked, settings.autoSyncEnabled,
              settings.cloud.functional, settings.cloud != .none,
              syncState != .syncing else { return }
        // 有未决冲突时不发起新同步:等主窗空闲(无其他弹窗)即补呈现决策弹窗
        if pendingSyncConflict != nil {
            presentSyncConflictSheetIfPossible()
            return
        }
        let interval = TimeInterval(max(settings.autoSyncSeconds, Self.minAutoSyncSeconds))
        if let last = lastSync, Date().timeIntervalSince(last) < interval { return }
        Log.info("sync", "auto sync due (interval \(Int(interval))s, cloud=\(settings.cloud.rawValue))")
        Task { await sync(auto: true) }
    }

    // MARK: - Conflict resolution (冲突裁决)

    /// 上次成功同步的基线哈希键(按数据库分开):本地明文 XML 与远端容器字节,
    /// 作为下次同步"双方是否都改过"的判定参照(见 SyncConflict)。
    private var baselineLocalXMLKey: String { "sync.baseline.local.\(databaseName)" }
    private var baselineRemoteDataKey: String { "sync.baseline.remote.\(databaseName)" }

    /// 记录本次成功同步的基线哈希,供下次同步做冲突判定。
    private func recordSyncBaseline(uploaded: Data) {
        let defaults = UserDefaults.standard
        defaults.set(SyncConflict.sha256Hex(database.xmlData()), forKey: baselineLocalXMLKey)
        defaults.set(SyncConflict.sha256Hex(uploaded), forKey: baselineRemoteDataKey)
        Log.debug("sync", "baseline recorded for \"\(databaseName)\"")
    }

    /// 呈现冲突决策弹窗;主窗已有其他弹窗时推迟(不打断正在进行的编辑),
    /// autoSyncTick 会在主窗空闲时补呈现。
    private func presentSyncConflictSheetIfPossible() {
        guard activeSheet == nil else {
            Log.info("sync", "conflict dialog deferred: another sheet \"\(activeSheet?.id ?? "nil")\" is open")
            return
        }
        activeSheet = .syncConflict
        Log.info("sync", "conflict dialog presented for \"\(databaseName)\"")
    }

    /// 用户裁决同步冲突:useLocal = true 用本地覆盖云端(丢弃云端自上次同步后
    /// 的修改),否则用云端覆盖本地(丢弃本地自上次同步后的修改)。
    /// 裁决后重设基线,后续同步恢复正常。
    func resolveSyncConflict(useLocal: Bool) async {
        guard let conflict = pendingSyncConflict else { return }
        pendingSyncConflict = nil
        guard let driver = makeCloudDriver() else {
            syncState = .idle
            Log.warn("sync", "conflict resolution \"\(databaseName)\" aborted: cloud not configured")
            return
        }
        Log.info("sync", "conflict resolution \"\(databaseName)\": overwrite \(useLocal ? "remote with local" : "local with remote")")
        syncState = .syncing
        do {
            if !useLocal {
                // 用云端覆盖本地:整库替换为远端版本并落盘
                let plain = try DatabaseCipher.decryptedData(conflict.remoteData, password: password)
                let remote = try PasswordDatabase.parse(plain)
                database = remote
                if let selected = selectedCardId, database.card(id: selected) == nil {
                    selectedCardId = database.activeCards.first?.id
                }
                save()
                Log.info("sync", "local replaced by remote (\(remote.cards.count) cards, \(remote.labels.count) labels)")
            }
            let out = try DatabaseCipher.encryptedData(database.xmlData(), password: password)
            try await driver.upload(out)
            recordSyncBaseline(uploaded: out)
            let finished = Date()
            lastSync = finished
            syncState = .idle
            Log.info("sync", "conflict resolution \"\(databaseName)\" finished (uploaded \(out.count)B)")
            AppToast.shared.show(L10n.t("last_sync_completed_prompt") + " "
                + DateFormatter.localizedString(from: finished, dateStyle: .short, timeStyle: .short))
        } catch {
            // 裁决上传失败:基线不动,下次同步会重新检测并再次询问
            lastSyncFailed = Date()
            syncState = .error(error.localizedDescription)
            Log.error("sync", "conflict resolution \"\(databaseName)\" failed: \(error)")
            AppToast.shared.show("\(L10n.t("sync_error")): \(error.localizedDescription)")
        }
    }

    /// 冲突弹窗选「稍后」:丢弃暂存现场、基线不动,下次同步重新检测并再次询问。
    func postponeSyncConflict() {
        guard pendingSyncConflict != nil else { return }
        pendingSyncConflict = nil
        syncState = .idle
        Log.info("sync", "conflict \"\(databaseName)\" postponed by user")
    }

    /// sync: — 云驱动 download/冲突判定/merge/upload(WebDAV / iCloud Drive)。
    /// auto = true 为自动同步:静默执行(成功/未配置不打 toast,失败只记日志与状态)。
    func sync(auto: Bool = false) async {
        guard settings.cloud != .none else {
            syncState = .disabled
            Log.debug("sync", "sync skipped: cloud disabled")
            if !auto { AppToast.shared.show(L10n.t("sync_disabled_state")) }
            return
        }
        guard let driver = makeCloudDriver() else {
            Log.debug("sync", "sync skipped: cloud=\(settings.cloud) not implemented")
            if !auto { AppToast.shared.show(L10n.t("not_configured_state")) }
            return
        }
        Log.info("sync", "sync \"\(databaseName)\" started (\(settings.cloud.rawValue)\(auto ? ", auto" : ""))")
        syncState = .syncing
        save()
        do {
            try await driver.testConnection()
            Log.debug("sync", "\(settings.cloud.rawValue) connection ok")
            let remoteData = try await driver.download()
            var local = database
            if let remoteData {
                let plain = try DatabaseCipher.decryptedData(remoteData, password: password)
                let remote = try PasswordDatabase.parse(plain)
                Log.info("sync", "remote: \(remote.cards.count) cards, \(remote.labels.count) labels; local: \(local.cards.count) cards")
                let verdict = SyncConflict.evaluate(
                    localXMLHash: SyncConflict.sha256Hex(local.xmlData()),
                    remoteDataHash: SyncConflict.sha256Hex(remoteData),
                    baselines: SyncConflict.Baselines(
                        localXMLHash: UserDefaults.standard.string(forKey: baselineLocalXMLKey),
                        remoteDataHash: UserDefaults.standard.string(forKey: baselineRemoteDataKey)))
                guard verdict != .conflict else {
                    // 本地与云端自上次同步后都有修改:交给用户决定覆盖方向
                    Log.warn("sync", "conflict \"\(databaseName)\": local and remote both changed since last sync — asking user")
                    pendingSyncConflict = PendingSyncConflict(
                        remoteData: remoteData,
                        localCards: local.cards.count,
                        localLabels: local.labels.count,
                        remoteCards: remote.cards.count,
                        remoteLabels: remote.labels.count)
                    syncState = .conflict
                    presentSyncConflictSheetIfPossible()
                    return
                }
                Log.info("sync", "no conflict — merging")
                local.merge(with: remote)
                database = local
                save()
            } else {
                Log.info("sync", "no remote database yet — uploading local")
            }
            let out = try DatabaseCipher.encryptedData(database.xmlData(), password: password)
            try await driver.upload(out)
            recordSyncBaseline(uploaded: out)
            let finished = Date()
            lastSync = finished
            syncState = .idle
            Log.info("sync", "sync \"\(databaseName)\" finished (uploaded \(out.count)B)")
            var completionMessage = L10n.t("last_sync_completed_prompt") + " "
                + DateFormatter.localizedString(from: finished, dateStyle: .short, timeStyle: .short)
            if database.cards.isEmpty, database.labels.isEmpty {
                // 本地空库 + 云端还有其他数据库文件:多半是数据库名与云端不一致
                // (新设备首配最易踩),明确提示而不是假装同步完成。
                let names = try? await driver.listDatabases()
                if let names, !names.isEmpty {
                    completionMessage = L10n.t("sync_empty_local_hint")
                    Log.warn("sync", "local database empty while cloud has \(names.count): \(names.joined(separator: ", ")) — possible name mismatch")
                }
            }
            if !auto { AppToast.shared.show(completionMessage) }
        } catch {
            lastSyncFailed = Date()
            syncState = .error(error.localizedDescription)
            Log.error("sync", "sync \"\(databaseName)\" failed: \(error)")
            if !auto { AppToast.shared.show("\(L10n.t("sync_error")): \(error.localizedDescription)") }
        }
    }
}
