import Foundation
import CryptoKit
import UPasswordsCore
import UPasswordsPersistence

/// 修改密码、备份、行级云同步(api.upasswords.com /v1,见 Cloud/DESIGN.md §6):
/// 拉取(游标增量) → 上行(脏集合 CAS);仅有可靠共同基线的非重叠修改自动合并。
extension AppContext {

    // MARK: - 行级同步状态(存储在 AppContext.rowSync)

    /// 绑定新库时重置行同步状态:快照基线清空 → 下轮 sync 把全部条目当脏上行。
    func resetRowSyncForFreshBinding() {
        guard let vaultKey else { return }
        do {
            var state = RowSyncState()
            // Import receipts belong to this local database, independently of its cloud binding.
            state.importedSourceKeys = rowSync.importedSourceKeys
            state.quarantinedItems = rowSync.quarantinedItems
            try commitSyncSnapshot(database, name: databaseName, vaultKey: vaultKey, state: state)
            rowSync = state
            Log.info("sync", "fresh binding snapshot committed")
        } catch {
            Log.error("sync", "reset row sync state failed: \(error)")
        }
    }

    /// Retries retained cloud records using the currently unlocked vault key.
    func retryQuarantinedSyncItems() async {
        guard phase == .unlocked, syncState != .syncing,
              !rowSync.quarantinedItems.isEmpty,
              let snapshotKey = vaultKey,
              let binding = relay.binding(database: databaseName),
              let token = relay.token(database: databaseName) else { return }
        let name = databaseName
        let sessionID = syncSessionID
        let snapshot = database
        var recovered = snapshot
        var state = rowSync
        let key = RowSyncKey(raw: snapshotKey.withUnsafeBytes { Data($0) })
        syncState = .syncing
        Log.info("sync", "quarantined record retry started count=\(state.quarantinedItems.count)")
        do {
            let count = try await RowSync.retryQuarantinedItems(
                client: relayClient, token: token, vaultId: binding.vaultId,
                key: key, database: &recovered, state: &state)
            try validateSyncSession(name: name, key: snapshotKey, sessionID: sessionID)
            guard database.xmlData() == snapshot.xmlData() else {
                throw RowSyncSafetyError.localDataNeedsRecovery
            }
            try commitSyncSnapshot(recovered, name: name, vaultKey: snapshotKey, state: state)
            database = recovered
            rowSync = state
            syncState = .idle
            AppToast.shared.show(String(format: L10n.t("sync_quarantine_retry_success_fmt"), count))
            Log.info("sync", "quarantined record retry committed recovered=\(count)")
            Task { [weak self] in await self?.sync(auto: true) }
        } catch {
            guard syncSessionID == sessionID, databaseName == name else { return }
            syncState = .error(error.localizedDescription)
            Log.error("sync", "quarantined record retry failed: \(error)")
            AppToast.shared.show(error.localizedDescription)
        }
    }

    func loadRowSyncState() throws {
        let state = try store.loadSyncState(for: databaseName)
        rowSync = state
        Log.info("sync", "restored row sync state for \"\(databaseName)\" (cursor=\(rowSync.cursor), pending=\(rowSync.dirtyUpserts.count + rowSync.dirtyDeletes.count))")
    }

    /// await 后验证库名、密钥与会话代次;旧任务不得写入新会话。
    /// - Throws: 会话已改变或任务取消。
    func validateSyncSession(name: String, key: SymmetricKey?, sessionID: UUID) throws {
        try Task.checkCancellation()
        guard syncSessionID == sessionID, databaseName == name, vaultKey == key else {
            Log.warn("sync", "discarding stale sync result after session changed")
            throw CancellationError()
        }
    }

    // MARK: - Change password

    /// 修改主密码:始终轮换库密钥(全新 VEK + 本体重加密)。
    /// 旧密文与旧信封的已有副本无法追溯撤销;这里只保护换代后的数据。
    /// 云端顺序:rekey 分块换入(全部条目新 VEK 密文 + revision+1 + 信封原子切换)。
    func changePassword(current: String, new: String) throws {
        guard current == password else {
            Log.warn("db", "changePassword \"\(databaseName)\" failed: wrong current password")
            throw DatabaseCipher.CipherError(message: L10n.t("wrong_password_error"))
        }
        guard let oldVaultKey = vaultKey else {
            Log.error("db", "changePassword \"\(databaseName)\" failed: no vault key in session")
            throw DatabaseCipher.CipherError(message: L10n.t("sync_error"))
        }
        let effectiveKey = DatabaseCipher.generateVaultKey()
        // 轮换的崩溃窗口防线:本体(新钥)与信封(新钥)两次写之间崩溃会让
        // 新旧密码都解不开库;先落一份改前备份,备份失败即中止改密
        do {
            try store.backup(name: databaseName)
        } catch {
            Log.error("backup", "pre-rotation backup of \"\(databaseName)\" failed — aborting password change: \(error)")
            throw error
        }
        let envelope = try DatabaseCipher.wrapVaultKey(effectiveKey, password: new)
        try commitSyncSnapshot(database, name: databaseName, vaultKey: effectiveKey,
                               state: rowSync, envelope: envelope,
                               rekeyBackupHistoryFrom: oldVaultKey)
        PasswordStore.savePassword(new, databaseName: databaseName)
        if settings.fastUnlock && PasswordStore.biometricAvailable() {
            PasswordStore.savePasswordForBiometric(new, databaseName: databaseName)
        }
        password = new
        // guard vaultKey 判空用完即弃;轮换后的会话密钥写回属性
        self.vaultKey = effectiveKey
        Log.info("db", "changePassword \"\(databaseName)\" ok (vault key rotated, body re-encrypted)")
        // 快照连信封+本体一起重推(两者都已换代)
        SafariSnapshotBridge.push(databaseName: databaseName, store: store)
        // 云端接力(rekey):全部条目新 VEK 密文分块换入;失败不回滚本地
        // (他端旧密文推送会撞 revision+1 的 409,走强制锁定收敛)。
        if relayBound {
            let name = databaseName
            let sessionID = syncSessionID
            Task { [weak self] in
                guard let self, self.databaseName == name,
                      self.syncSessionID == sessionID, self.vaultKey == effectiveKey else { return }
                await self.relayRekeyUpload(
                    oldKey: oldVaultKey, newKey: effectiveKey, new: new)
            }
        } else {
            Log.info("sync", "password changed with relay unbound — other devices adopt via next sync")
        }
    }

    /// 改密的云端接力:rekey 全量换入(§6.5)。本端即改密端,成功后直接
    /// 以新密钥全量对账(清游标重拉),失败下轮同步自愈。
    private func relayRekeyUpload(oldKey: SymmetricKey, newKey: SymmetricKey,
                                  new newPassword: String) async {
        guard phase == .unlocked, vaultKey == newKey,
              let binding = relay.binding(database: databaseName),
              let token = relay.token(database: databaseName) else { return }
        let name = databaseName
        let sessionID = syncSessionID
        let snapshot = database
        let knownVersion = relay.knownPasswordVersion(database: name) ?? 1
        Log.info("sync", "rekey upload started")
        do {
            let envelope = try DatabaseCipher.wrapVaultKey(newKey, password: newPassword)
            var state = rowSync
            try await RowSync.rekey(
                client: relayClient, token: token, vaultId: binding.vaultId,
                database: snapshot, oldKey: RowSyncKey(raw: oldKey.withUnsafeBytes { Data($0) }),
                newKey: RowSyncKey(raw: newKey.withUnsafeBytes { Data($0) }),
                newEnvelope: envelope, state: &state)
            try validateSyncSession(name: name, key: newKey, sessionID: sessionID)
            // 上传期间新增的本地编辑保留在本体中,由下轮 dirty 重算带走。
            try state.recomputeDirty(
                database: database,
                key: RowSyncKey(raw: newKey.withUnsafeBytes { Data($0) }))
            try commitSyncSnapshot(database, name: name, vaultKey: newKey,
                                   state: state, envelope: envelope)
            rowSync = state
            relay.recordPasswordVersion(knownVersion + 1, database: name)
            Log.info("sync", "rekey upload and local snapshot committed")
        } catch {
            Log.error("sync", "rekey upload or snapshot commit failed: \(error)")
            guard syncSessionID == sessionID else { return }
            syncState = .error(error.localizedDescription)
            AppToast.shared.show(error.localizedDescription)
        }
    }

    // MARK: - Backup

    func backupNow() {
        guard phase == .unlocked else { return }
        save()
        startBackupCapture(auto: false)
    }

    /// Restores a backup as an independent local database without replacing the active vault.
    func restoreBackupAsCopy(
        backup: URL,
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
                backup: backup,
                name: name,
                sourcePassword: sourcePassword,
                newPassword: newPassword,
                expectedPackageVerificationToken: expectedPackageVerificationToken,
                allowIncompletePackage: allowIncompletePackage)
            _ = try nativeStore?.importLegacyIfNeeded(
                name: name, password: newPassword, legacyStore: store)
            Log.info("backup", "restored \"\(backup.lastPathComponent)\" as copy \"\(name)\"")
            AppToast.shared.show(String(format: L10n.t("backup_copy_created_fmt"), name))
            return nil
        } catch {
            Log.error("backup", "restore \"\(backup.lastPathComponent)\" as \"\(name)\" failed: \(error)")
            AppToast.shared.show(error.localizedDescription)
            return error.localizedDescription
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
        startBackupCapture(auto: true)
    }

    func cancelBackupCapture() {
        backupCaptureTask?.cancel()
        backupCaptureTask = nil
    }

    /// Protects the current local vault first, then adopts a fresh cloud snapshot after cursor expiry.
    func recoverExpiredSyncCursor() async {
        guard phase == .unlocked, syncCursorRecoveryRequired, syncState != .syncing,
              backupCaptureTask == nil,
              let binding = relay.binding(database: databaseName),
              let token = relay.token(database: databaseName),
              let vaultKey else { return }
        let name = databaseName
        let sessionID = syncSessionID
        let snapshot = database
        let previousState = rowSync
        syncState = .syncing
        Log.info("sync", "cursor recovery started for \"\(name)\" pending=\(previousState.dirtyUpserts.count + previousState.dirtyDeletes.count)")
        do {
            let protected = try await BackupPackage.capture(
                store: store,
                name: name,
                database: snapshot,
                vaultKey: vaultKey,
                syncState: previousState,
                cloud: BackupPackage.CloudSource(
                    client: relayClient, token: token, vaultID: binding.vaultId),
                cloudRequired: true)
            try validateSyncSession(name: name, key: vaultKey, sessionID: sessionID)
            var state = RowSyncState()
            state.importedSourceKeys = previousState.importedSourceKeys
            state.dirtyDeletes = previousState.dirtyDeletes
            let rebuilt = try await RowSync.fullRebuild(
                client: relayClient,
                token: token,
                vaultId: binding.vaultId,
                key: RowSyncKey(raw: vaultKey.withUnsafeBytes { Data($0) }),
                localDatabase: PasswordDatabase(),
                state: &state)
            state.quarantinedCandidates = previousState.quarantinedCandidates
            try validateSyncSession(name: name, key: vaultKey, sessionID: sessionID)
            try commitSyncSnapshot(rebuilt, name: name, vaultKey: vaultKey, state: state)
            database = rebuilt
            rowSync = state
            syncCursorRecoveryRequired = false
            syncState = .idle
            AppToast.shared.show(String(
                format: L10n.t("sync_cursor_recovery_success_fmt"),
                protected.url.lastPathComponent))
            Log.info(
                "sync",
                "cursor recovery committed backup=\(protected.url.lastPathComponent) complete=\(protected.assessment.isComplete)")
            Task { [weak self] in await self?.sync(auto: true) }
        } catch {
            guard syncSessionID == sessionID, databaseName == name else { return }
            syncState = .error(error.localizedDescription)
            Log.error("sync", "cursor recovery failed for \"\(name)\": \(error)")
            AppToast.shared.show(error.localizedDescription)
        }
    }

    private func startBackupCapture(auto: Bool) {
        guard phase == .unlocked, let vaultKey else {
            Log.warn("backup", "capture skipped: database is locked")
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
        Log.info("backup", "\(auto ? "auto" : "manual") package capture started for \"\(name)\"")
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
                guard self.phase == .unlocked,
                      self.databaseName == name,
                      self.syncSessionID == sessionID else { return }
                self.backupListDidChange()
                if auto {
                    UserDefaults.standard.set(
                        Date().timeIntervalSince1970,
                        forKey: "backup.last.\(name)")
                }
                let resultText = result.assessment.isComplete
                    ? L10n.t("backup_package_saved_complete")
                    : String(
                        format: L10n.t("backup_package_saved_incomplete_fmt"),
                        result.assessment.issues.count)
                if !auto { AppToast.shared.show(resultText) }
                Log.info(
                    "backup",
                    "\(auto ? "auto" : "manual") package capture saved \"\(name)\" complete=\(result.assessment.isComplete) issues=\(result.assessment.issues.count)")
                self.syncAfterBackup(auto: auto)
            } catch is CancellationError {
                Log.info("backup", "package capture cancelled for \"\(name)\"")
            } catch {
                guard let self else { return }
                self.backupCaptureTask = nil
                Log.error("backup", "package capture failed for \"\(name)\": \(error)")
                if !auto, self.phase == .unlocked, self.databaseName == name {
                    AppToast.shared.show(error.localizedDescription)
                }
            }
        }
    }

    /// 备份完成后顺带触发一次云同步。库未绑定中继时跳过;已有同步在飞行中
    /// 时也跳过——那一次同步同样会带走最新数据。
    private func syncAfterBackup(auto: Bool) {
        guard relay.token(database: databaseName) != nil else {
            Log.debug("sync", "sync after backup skipped: relay not bound")
            return
        }
        guard syncState != .syncing else {
            Log.debug("sync", "sync after backup skipped: another sync in flight")
            return
        }
        Log.info("sync", "sync after \(auto ? "auto" : "manual") backup \"\(databaseName)\"")
        Task { await sync(auto: auto) }
    }

    // MARK: - 接管/覆盖(他端改密后的恢复路径)

    /// 接管的结果:成功 / 密码不对。
    enum AdoptResult {
        case success, wrongPassword, wrongPreviousPassword, previousPasswordRequired, protectedData
    }

    /// 远端不可解密修复 A:输入「其他设备改后的新主密码」接管远端——
    /// 解信封换 VEK → 行级全量重建 → 本地落盘 + 快照推送。
    @discardableResult
    func adoptRemotePassword(_ newPassword: String, previousPassword: String? = nil) async -> AdoptResult {
        guard let binding = relay.binding(database: databaseName),
              let token = relay.token(database: databaseName) else { return .protectedData }
        let name = databaseName
        let originalKey = vaultKey
        let originalDatabase = database
        let startedUnlocked = originalKey != nil
        let sessionID = syncSessionID
        Log.info("sync", "adopt remote password started")
        do {
            let record = try await relayClient.getVault(token: token, vaultId: binding.vaultId)
            try validateSyncSession(name: name, key: originalKey, sessionID: sessionID)
            guard let envelope = record.envelope else {
                Log.warn("sync", "adopt failed: registry record or envelope unavailable")
                return .wrongPassword
            }
            guard let remoteVEK = try? DatabaseCipher.unwrapVaultKey(envelope, password: newPassword) else {
                Log.warn("sync", "adopt: envelope unwrap failed with given password")
                return .wrongPassword
            }
            let localDatabase: PasswordDatabase?
            let localVaultKey: SymmetricKey?
            var state: RowSyncState
            if startedUnlocked {
                localDatabase = originalDatabase
                localVaultKey = originalKey
                state = rowSync
            } else if store.exists(name) {
                guard let previousPassword, !previousPassword.isEmpty else {
                    return .previousPasswordRequired
                }
                do {
                    let (database, key) = try store.loadUnlocked(
                        name: name, password: previousPassword)
                    localDatabase = database
                    localVaultKey = key
                } catch {
                    guard Self.isPasswordRejection(error) else { throw error }
                    Log.warn("sync", "local copy password verification failed")
                    return .wrongPreviousPassword
                }
                state = try store.loadSyncState(for: name)
            } else {
                localDatabase = nil
                localVaultKey = nil
                state = try store.loadSyncState(for: name)
            }
            let rowKey = RowSyncKey(raw: remoteVEK.withUnsafeBytes { Data($0) })
            let rebuilt: PasswordDatabase
            if let localDatabase, let localVaultKey {
                let adoption = try await RowSync.adoptRemoteRekey(
                    client: relayClient, token: token, vaultId: binding.vaultId,
                    oldKey: RowSyncKey(raw: localVaultKey.withUnsafeBytes { Data($0) }),
                    newKey: rowKey, localDatabase: localDatabase, state: state)
                rebuilt = adoption.database
                state = adoption.state
            } else {
                guard state.pendingConflicts.isEmpty, state.dirtyUpserts.isEmpty,
                      state.dirtyDeletes.isEmpty, state.quarantinedItems.isEmpty else {
                    throw RowSyncSafetyError.localDataNeedsRecovery
                }
                let importedSourceKeys = state.importedSourceKeys
                state = RowSyncState()
                state.importedSourceKeys = importedSourceKeys
                rebuilt = try await RowSync.fullRebuild(
                    client: relayClient, token: token, vaultId: binding.vaultId,
                    key: rowKey, state: &state)
            }
            try validateSyncSession(name: name, key: originalKey, sessionID: sessionID)
            if startedUnlocked, database.xmlData() != originalDatabase.xmlData() {
                throw RowSyncSafetyError.localDataNeedsRecovery
            }
            try commitSyncSnapshot(
                rebuilt, name: name, vaultKey: remoteVEK, state: state, envelope: envelope)
            if startedUnlocked {
                database = rebuilt
                rowSync = state
                vaultKey = remoteVEK
                password = newPassword
                syncSessionID = UUID()
                PasswordStore.savePassword(newPassword, databaseName: name)
                if settings.fastUnlock && PasswordStore.biometricAvailable() {
                    PasswordStore.savePasswordForBiometric(newPassword, databaseName: name)
                }
            } else {
                try unlock(name: name, password: newPassword)
            }
            relay.recordPasswordVersion(record.passwordVersion, database: name)
            if let selected = selectedCardId, database.card(id: selected) == nil {
                selectedCardId = database.activeCards.first?.id
            }
            syncRemoteUnreadable = false
            SafariSnapshotBridge.push(databaseName: databaseName, store: store)
            Log.info("sync", "adopted new password via envelope (rows rebuilt: \(rebuilt.cards.count) cards)")
            return .success
        } catch let error as RowSyncSafetyError {
            Log.error("sync", "adopt remote password paused; local data retained: \(error)")
            if syncSessionID == sessionID {
                syncState = .error(error.localizedDescription)
                AppToast.shared.show(error.localizedDescription)
            }
            return .protectedData
        } catch {
            Log.error("sync", "adopt remote password failed: \(error)")
            if syncSessionID == sessionID {
                syncState = .error(error.localizedDescription)
                AppToast.shared.show(error.localizedDescription)
            }
            return .protectedData
        }
    }

    /// 远端不可解密修复 B:以本地数据覆盖云端(确认后调用),丢弃云端现有内容。
    /// 当前实现通过本地 VEK + 本地信封执行一轮 rekey(原子替换服务端全部条目)。
    func overwriteUnreadableRemote() async {
        guard let binding = relay.binding(database: databaseName),
              let token = relay.token(database: databaseName),
              let key = vaultKey,
              let envelope = store.envelopeData(for: databaseName) else { return }
        let name = databaseName
        let sessionID = syncSessionID
        let snapshot = database
        syncState = .syncing
        Log.info("sync", "overwrite unreadable remote started")
        do {
            var state = rowSync
            try await RowSync.rekey(
                client: relayClient, token: token, vaultId: binding.vaultId,
                database: snapshot, oldKey: RowSyncKey(raw: key.withUnsafeBytes { Data($0) }),
                newKey: RowSyncKey(raw: key.withUnsafeBytes { Data($0) }),
                newEnvelope: envelope, state: &state)
            try validateSyncSession(name: name, key: key, sessionID: sessionID)
            let rowKey = RowSyncKey(raw: key.withUnsafeBytes { Data($0) })
            try state.recomputeDirty(database: database, key: rowKey)
            try commitSyncSnapshot(database, name: name, vaultKey: key, state: state, envelope: envelope)
            rowSync = state
            syncRemoteUnreadable = false
            lastSync = Date()
            syncState = .idle
            Log.info("sync", "overwrite unreadable remote ok (rows re-keyed to local VEK)")
            AppToast.shared.show(L10n.t("last_sync_completed_prompt"))
        } catch {
            Log.error("sync", "overwrite unreadable remote failed: \(error)")
            guard syncSessionID == sessionID else { return }
            syncState = .error(error.localizedDescription)
            AppToast.shared.show(error.localizedDescription)
        }
    }

    // MARK: - 新设备恢复

    /// 服务端通道恢复(新设备向导):注册表信封 + 行级全量重建 →
    /// 落为本地库并直接解锁进入主界面。绑定与版本基准由解锁后的
    /// relayBindCurrentVaultIfNeeded 自动补齐(按库名认领现有注册,不产生重复 vaultId)。
    func restoreDatabaseFromRelay(record: RelayClient.VaultRecord,
                                  password pw: String) async throws {
        guard let email = relay.lastAccountEmail,
              let token = relay.token(email: email) else { throw SyncError.notConfigured }
        let name = record.name
        let sessionID = syncSessionID
        let currentName = databaseName
        let originalKey = vaultKey
        Log.info("lifecycle", "restore from relay \"\(name)\" (vault=\(record.vaultId.prefix(8))…)")
        guard !store.exists(name) else {
            Log.warn("lifecycle", "restore from relay \"\(name)\" aborted: local database exists")
            throw SyncError.localNameConflict
        }
        let detail = try await relayClient.getVault(token: token, vaultId: record.vaultId)
        try validateSyncSession(name: currentName, key: originalKey, sessionID: sessionID)
        guard let envelope = detail.envelope else {
            Log.warn("lifecycle", "restore from relay \"\(name)\": registry has no envelope")
            throw DatabaseCipher.CipherError(message: L10n.t("envelope_missing_error"))
        }
        let vek = try DatabaseCipher.unwrapVaultKey(envelope, password: pw)
        var state = RowSyncState()
        let db = try await RowSync.fullRebuild(
            client: relayClient, token: token, vaultId: record.vaultId,
            key: RowSyncKey(raw: vek.withUnsafeBytes { Data($0) }), state: &state)
        try validateSyncSession(name: currentName, key: originalKey, sessionID: sessionID)
        guard !store.exists(name) else { throw SyncError.localNameConflict }
        try commitSyncSnapshot(db, name: name, vaultKey: vek, state: state, envelope: envelope)
        store.mainDatabaseName = name
        try unlock(name: name, password: pw)
        markSetupTaskDone(.cloudSync)
        scheduleSilentBreachCheck()
        Log.info("lifecycle", "restore from relay \"\(name)\" ok (\(db.cards.count) cards)")
    }

    /// 本地文件恢复(新设备向导):从任意位置的一对 `<名>.upw`/`<名>.upwkey`
    /// 校验解密后落为本地库,直接解锁进入主界面——离线迁移路径。
    func restoreDatabaseFromLocalFiles(body: URL, envelope: URL, name: String, password: String) async throws {
        Log.info("lifecycle", "restore from local files \"\(name)\" (body=\(body.lastPathComponent))")
        _ = try store.restore(body: body, envelope: envelope, name: name, password: password)
        store.mainDatabaseName = name
        try unlock(name: name, password: password)
        scheduleSilentBreachCheck()
        Log.info("lifecycle", "restore from local files \"\(name)\" ok (\(database.cards.count) cards)")
    }

    // MARK: - 自动同步 ticker

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
              relay.binding(database: databaseName) != nil,
              relay.token(database: databaseName) != nil,
              syncState != .syncing else { return }
        let interval = TimeInterval(max(settings.autoSyncSeconds, Self.minAutoSyncSeconds))
        if let last = lastSync, Date().timeIntervalSince(last) < interval { return }
        Log.info("sync", "auto sync due (interval \(Int(interval))s)")
        Task { await sync(auto: true) }
    }

    /// 自动同步间隔下限(秒):防止误设过小的间隔频繁打服务端。
    private static let minAutoSyncSeconds = 30

    // MARK: - 行级同步主流程

    /// sync: — 拉取(游标增量) → 上行(脏集合 CAS),§6.2/§6.3。
    /// auto = true 为自动同步:静默执行(成功不打 toast,失败只记日志与状态)。
    /// - Returns: 本次结果;未执行(锁屏/未绑定/已在同步中)返回 nil。
    /// 手动同步反馈结果:已是最新 / 拉取·上传条数 / 失败原因。
    @discardableResult
    func sync(auto: Bool = false) async -> RowSyncOutcome? {
        // 锁屏状态下禁止同步:密码已抹(空串),继续走会以空密码加密并
        // 覆盖云端/误报远端解不开(与 iOS 同款事故防护)
        guard phase == .unlocked else {
            Log.warn("sync", "sync skipped: vault locked")
            return nil
        }
        guard syncState != .syncing else {
            Log.debug("sync", "sync skipped: another sync already in flight")
            if !auto { AppToast.shared.show(L10n.t("sync_in_progress_toast")) }
            return nil
        }
        guard let binding = relay.binding(database: databaseName),
              let token = relay.token(database: databaseName) else {
            syncState = .disabled
            Log.debug("sync", "sync skipped: relay not bound")
            if !auto { AppToast.shared.show(L10n.t("not_configured_state")) }
            return nil
        }
        guard let snapshotKey = vaultKey else {
            syncState = .error(L10n.t("sync_error"))
            Log.error("sync", "sync aborted: no vault key in session")
            return nil
        }
        let name = databaseName
        let sessionID = syncSessionID
        let snapshot = database
        let key = RowSyncKey(raw: snapshotKey.withUnsafeBytes { Data($0) })
        var state = rowSync
        Log.info("sync", "sync \"\(name)\" started (rows\(auto ? ", auto" : ""))")
        syncState = .syncing
        do {
            let record = try await relayClient.getVault(token: token, vaultId: binding.vaultId)
            try validateSyncSession(name: name, key: snapshotKey, sessionID: sessionID)
            let known = relay.knownPasswordVersion(database: name) ?? record.passwordVersion
            var adoptedEnvelope: Data?
            if record.passwordVersion > known, let envelope = record.envelope {
                if (try? DatabaseCipher.unwrapVaultKey(envelope, password: password)) == snapshotKey {
                    adoptedEnvelope = envelope
                } else {
                    forceLockForRemotePasswordChange(envelope)
                    return nil
                }
            }
            try state.recomputeDirty(database: snapshot, key: key)
            var db = snapshot
            var outcome = RowSyncOutcome()
            do {
                if state.needsContentBaselineMigration {
                    Log.info("sync", "legacy content baseline migration started")
                    db = try await RowSync.fullRebuild(
                        client: relayClient, token: token, vaultId: binding.vaultId,
                        key: key, localDatabase: db, state: &state)
                    outcome.pulledItems = db.cards.count + db.labels.count + db.userProfiles.count
                }
                let pulled = try await RowSync.pull(
                    client: relayClient, token: token, vaultId: binding.vaultId,
                    key: key, database: &db, state: &state)
                outcome.pulledItems += pulled.pulledItems
                outcome.quarantinedItems += pulled.quarantinedItems
            } catch RelayClient.RelayError.cursorExpired {
                try validateSyncSession(name: name, key: snapshotKey, sessionID: sessionID)
                // 游标落后越过保留地板:全量重建(快照+差量)
                Log.warn("sync", "cursor expired — full rebuild")
                do {
                    db = try await RowSync.fullRebuild(
                        client: relayClient, token: token, vaultId: binding.vaultId,
                        key: key, localDatabase: snapshot, state: &state)
                } catch RowSyncSafetyError.localDataNeedsRecovery {
                    syncCursorRecoveryRequired = true
                    throw RowSyncSafetyError.localDataNeedsRecovery
                }
                outcome.pulledItems = db.cards.count + db.labels.count + db.userProfiles.count
            } catch let signal as RowSyncRekeySignal {
                // 对端 rekey:旧 VEK 解不开新密文,强制锁定接管
                Log.warn("sync", "peer rekey detected (version → \(signal.passwordVersion)) — force locking")
                try validateSyncSession(name: name, key: snapshotKey, sessionID: sessionID)
                let record = try await relayClient.getVault(token: token, vaultId: binding.vaultId)
                try validateSyncSession(name: name, key: snapshotKey, sessionID: sessionID)
                guard let envelope = record.envelope else { throw SyncError.notConfigured }
                forceLockForRemotePasswordChange(envelope)
                return nil
            }
            try validateSyncSession(name: name, key: snapshotKey, sessionID: sessionID)
            if db.migrateLegacyPersonalInfo() > 0 {
                try state.recomputeDirty(database: db, key: key)
            }
            if state.needsSyncContinuation {
                Log.info("sync", "sync checkpoint committed before continuing after quarantine")
            } else {
                let pushed = try await RowSync.push(
                    client: relayClient, token: token, vaultId: binding.vaultId,
                    key: key, database: &db, state: &state)
                outcome.pushedItems = pushed.pushedItems
                outcome.conflictsResolved = pushed.conflictsResolved
            }
            try validateSyncSession(name: name, key: snapshotKey, sessionID: sessionID)
            guard database.xmlData() == snapshot.xmlData() else {
                Log.warn("sync", "sync snapshot discarded: local edits arrived during await")
                throw DatabaseCipher.CipherError(message: L10n.t("sync_error"))
            }
            try commitSyncSnapshot(db, name: name, vaultKey: snapshotKey,
                                   state: state, envelope: adoptedEnvelope)
            database = db
            rowSync = state
            scheduleMissingAttachmentDownloads()
            relay.recordPasswordVersion(record.passwordVersion, database: name)
            SafariSnapshotBridge.push(databaseName: name, store: store)
            if let selected = selectedCardId, database.card(id: selected) == nil {
                selectedCardId = database.activeCards.first?.id
            }
            syncRemoteUnreadable = false
            let finished = Date()
            lastSync = finished
            syncCursorRecoveryRequired = false
            syncState = .idle
            Log.info("sync", "sync \"\(databaseName)\" finished via rows (cursor=\(state.cursor) pending=\(state.dirtyUpserts.count + state.dirtyDeletes.count))")
            if !auto {
                if state.quarantinedItems.count > 0 && outcome.quarantinedItems > 0 {
                    AppToast.shared.show(String(format: L10n.t("sync_quarantine_summary_fmt"),
                                                state.quarantinedItems.count))
                } else if outcome.pulledItems == 0 && outcome.pushedItems == 0 {
                    AppToast.shared.show(L10n.t("sync_result_latest"))
                } else {
                    AppToast.shared.show(String(format: L10n.t("sync_result_fmt"), outcome.pulledItems, outcome.pushedItems))
                }
            }
            if state.needsSyncContinuation {
                Task { [weak self] in await self?.sync(auto: true) }
            }
            return outcome
        } catch RelayClient.RelayError.unauthorized {
            guard syncSessionID == sessionID, databaseName == name else { return nil }
            handleSessionExpired()
        } catch {
            Log.error("sync", "row sync did not commit: \(error)")
            guard syncSessionID == sessionID, databaseName == name else { return nil }
            let markerUpdates = state.pendingConflicts.filter {
                rowSync.pendingConflicts[$0.key] != $0.value
            }
            if !markerUpdates.isEmpty {
                var protectedState = rowSync
                protectedState.pendingConflicts.merge(markerUpdates) { _, updated in updated }
                do {
                    try commitSyncSnapshot(
                        database, name: name, vaultKey: snapshotKey, state: protectedState)
                    rowSync = protectedState
                } catch {
                    Log.error("sync", "conflict marker persistence failed: \(error)")
                }
            }
            // 调用任务被取消:静默收场,不作为失败上报
            if Task.isCancelled {
                syncState = .idle
                Log.debug("sync", "sync task cancelled (ignored)")
                return nil
            }
            lastSyncFailed = Date()
            syncState = .error(error.localizedDescription)
            Log.error("sync", "sync \"\(databaseName)\" failed: \(error)")
            if !auto { AppToast.shared.show("\(L10n.t("sync_error")): \(error.localizedDescription)") }
        }
        return nil
    }
}
