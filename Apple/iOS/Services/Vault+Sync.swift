import Foundation
import CryptoKit

import UPasswordsCore
import UPasswordsPersistence

// MARK: - iOS 行级云同步(与 macOS AppContext+Sync 同语义)
//
// 拉取(游标增量) → 上行(脏集合 CAS);仅有可靠共同基线的非重叠修改自动合并。
// 本体仍经库密钥整库加密落盘(.upw),行级密文只在同步链路上存在。

extension Vault {
    // MARK: 同步进行态

    /// 同步状态(仅驱动 UI 呈现)。
    enum SyncPhase: Equatable {
        case idle
        case syncing
        case failed(String)
    }

    /// 最小自动同步间隔(秒),防止高频误触发。
    static let minAutoSyncSeconds = 30

    // MARK: 行级同步状态

    /// await 后验证库名、密钥与会话代次;旧任务不得写入新会话。
    /// - Throws: 会话已改变或任务取消。
    func validateSyncSession(name: String, key: SymmetricKey?, sessionID: UUID) throws {
        try Task.checkCancellation()
        guard syncSessionID == sessionID, databaseName == name, vaultKey == key else {
            Log.warn("sync", "ios discarding stale sync result after session changed")
            throw CancellationError()
        }
    }

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
            Log.info("sync", "ios fresh binding snapshot committed")
        } catch {
            Log.error("sync", "ios reset row sync state failed: \(error)")
        }
    }

    /// Retries retained cloud records using the currently unlocked vault key.
    func retryQuarantinedSyncItems() async {
        guard !locked, !syncInFlight, !rowSync.quarantinedItems.isEmpty,
              let snapshotKey = vaultKey,
              let binding = relay.binding(database: databaseName),
              let token = relay.token(database: databaseName) else { return }
        let name = databaseName
        let sessionID = syncSessionID
        let snapshot = database
        var recovered = snapshot
        var state = rowSync
        let key = RowSyncKey(raw: snapshotKey.withUnsafeBytes { Data($0) })
        syncInFlight = true
        syncState = .syncing
        Log.info("sync", "ios quarantined record retry started count=\(state.quarantinedItems.count)")
        defer { syncInFlight = false }
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
            showToast(String(format: L10n.t("sync_quarantine_retry_success_fmt"), count))
            Log.info("sync", "ios quarantined record retry committed recovered=\(count)")
            Task { [weak self] in await self?.sync(auto: true) }
        } catch {
            guard syncSessionID == sessionID, databaseName == name else { return }
            syncState = .failed(error.localizedDescription)
            Log.error("sync", "ios quarantined record retry failed: \(error)")
            showToast(error.localizedDescription)
        }
    }

    // MARK: 接管远端

    /// 接管结果区分密码错误和需要保护本地数据的失败。
    enum AdoptResult {
        case success, wrongPassword, wrongPreviousPassword, previousPasswordRequired, protectedData
    }

    /// 远端用「其他设备改后的新主密码」加密时的接管流程:
    /// 输入新密码 → 解注册表信封收敛库身份 → 行级全量重建 → 本地以新密码落盘。
    @discardableResult
    func adoptRemotePassword(_ newPassword: String, previousPassword: String? = nil) async -> AdoptResult {
        guard let binding = relay.binding(database: databaseName),
              let token = relay.token(database: databaseName) else { return .protectedData }
        let name = databaseName
        let originalKey = vaultKey
        let originalDatabase = database
        let startedUnlocked = originalKey != nil
        let sessionID = syncSessionID
        Log.info("sync", "ios adopt remote password started")
        do {
            let registryRecord = try await relayClient.getVault(token: token, vaultId: binding.vaultId)
            try validateSyncSession(name: name, key: originalKey, sessionID: sessionID)
            guard let envelope = registryRecord.envelope else {
                Log.warn("sync", "ios adopt failed: registry record or envelope unavailable")
                return .wrongPassword
            }
            guard let remoteVEK = try? DatabaseCipher.unwrapVaultKey(envelope, password: newPassword) else {
                Log.warn("sync", "ios adopt: envelope unwrap failed with given password")
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
                    Log.warn("sync", "ios local copy password verification failed")
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
                if PasswordStore.hasBiometricItem(databaseName: name) {
                    PasswordStore.savePasswordForBiometric(newPassword, databaseName: name)
                }
            } else {
                guard unlock(with: newPassword) else { throw RowSyncSafetyError.localDataNeedsRecovery }
            }
            relay.recordPasswordVersion(registryRecord.passwordVersion, database: name)
            syncRemoteUnreadable = false
            Log.info("sync", "ios adopted new password via envelope (rows rebuilt: \(rebuilt.cards.count) cards)")
            return .success
        } catch let error as RowSyncSafetyError {
            Log.error("sync", "adopt remote password paused; local data retained: \(error)")
            if syncSessionID == sessionID {
                syncState = .failed(error.localizedDescription)
                showToast(error.localizedDescription)
            }
            return .protectedData
        } catch {
            Log.error("sync", "ios adopt remote password failed: \(error)")
            if syncSessionID == sessionID {
                syncState = .failed(error.localizedDescription)
                showToast(error.localizedDescription)
            }
            return .protectedData
        }
    }

    /// 远端不可解密(旧主密码加密/数据损坏)时的修复:以本地 VEK + 本地信封
    /// 跑一轮 rekey(原子替换服务端全部条目)。会丢弃云端现有内容,UI 层须先经用户确认。
    func overwriteUnreadableRemote() async {
        guard let binding = relay.binding(database: databaseName),
              let token = relay.token(database: databaseName),
              let key = vaultKey,
              let envelope = store.envelopeData(for: databaseName) else { return }
        let name = databaseName
        let sessionID = syncSessionID
        let snapshot = database
        syncState = .syncing
        Log.info("sync", "ios overwrite unreadable remote started")
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
            let finished = Date()
            d.set(finished.timeIntervalSince1970, forKey: DefaultsKey.lastSync(database: name))
            lastSync = finished
            syncState = .idle
            Log.info("sync", "ios sync \"\(name)\": overwrote unreadable remote (rows re-keyed)")
            showToast(L10n.t("last_sync_completed_prompt") + " "
                + (lastSync?.formatted(date: .abbreviated, time: .shortened) ?? ""))
        } catch {
            Log.error("sync", "ios overwrite unreadable remote failed: \(error)")
            guard syncSessionID == sessionID else { return }
            syncState = .failed(error.localizedDescription)
            showToast("\(L10n.t("sync_error")): \(error.localizedDescription)")
        }
    }

    // MARK: 改密的云端接力

    /// rekey 全量换入(§6.5)。本端即改密端,成功后清游标全量对账,失败下轮自愈。
    func relayRekeyUpload(oldKey: SymmetricKey, newKey: SymmetricKey,
                          new newPassword: String) async {
        guard !locked, vaultKey == newKey,
              let binding = relay.binding(database: databaseName),
              let token = relay.token(database: databaseName) else { return }
        let name = databaseName
        let sessionID = syncSessionID
        let snapshot = database
        let knownVersion = relay.knownPasswordVersion(database: name) ?? 1
        Log.info("sync", "ios rekey upload started")
        do {
            let envelope = try DatabaseCipher.wrapVaultKey(newKey, password: newPassword)
            var state = rowSync
            try await RowSync.rekey(
                client: relayClient, token: token, vaultId: binding.vaultId,
                database: snapshot, oldKey: RowSyncKey(raw: oldKey.withUnsafeBytes { Data($0) }),
                newKey: RowSyncKey(raw: newKey.withUnsafeBytes { Data($0) }),
                newEnvelope: envelope, state: &state)
            try validateSyncSession(name: name, key: newKey, sessionID: sessionID)
            let rowKey = RowSyncKey(raw: newKey.withUnsafeBytes { Data($0) })
            try state.recomputeDirty(database: database, key: rowKey)
            try commitSyncSnapshot(database, name: name, vaultKey: newKey,
                                   state: state, envelope: envelope)
            rowSync = state
            relay.recordPasswordVersion(knownVersion + 1, database: name)
            Log.info("sync", "ios rekey upload and local snapshot committed")
        } catch {
            Log.error("sync", "ios rekey upload or snapshot commit failed: \(error)")
            guard syncSessionID == sessionID else { return }
            syncState = .failed(error.localizedDescription)
            showToast(error.localizedDescription)
        }
    }

    // MARK: 自动同步 ticker

    /// 常驻到期 ticker:每 5s 检查一次,距上次同步超过设定间隔即静默同步。
    /// 锁屏/未启用时空转,开销可忽略;iOS 退后台后系统暂停 ticker,
    /// 回前台由 didBecomeActive 补一次检查。
    func startAutoSyncTickerIfNeeded() {
        guard autoSyncTimer == nil else { return }
        autoSyncTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.autoSyncTick() }
        }
        Log.debug("sync", "ios auto-sync ticker installed")
    }

    /// 到期检查:启用自动同步、relay 已绑定、非同步中才发起。
    func autoSyncTick() {
        guard !locked, autoSyncEnabled,
              relay.binding(database: databaseName) != nil,
              relay.token(database: databaseName) != nil,
              syncState != .syncing else { return }
        let interval = TimeInterval(max(autoSyncSeconds, Self.minAutoSyncSeconds))
        if let last = lastSync, Date().timeIntervalSince(last) < interval { return }
        // 失败退避:距上次尝试(无论成败)不足间隔时不重试,
        // 避免服务端不可用时每个 5s tick 都重放一遍失败
        if let attempt = lastSyncAttempt, Date().timeIntervalSince(attempt) < interval { return }
        Log.info("sync", "ios auto sync due (interval \(Int(interval))s)")
        Task { await sync(auto: true) }
    }

    // MARK: 同步主流程

    /// Protects the current local vault first, then adopts a fresh cloud snapshot after cursor expiry.
    func recoverExpiredSyncCursor() async {
        guard !locked, syncCursorRecoveryRequired, !syncInFlight,
              backupCaptureTask == nil,
              let binding = relay.binding(database: databaseName),
              let token = relay.token(database: databaseName),
              let snapshotKey = vaultKey else { return }
        let name = databaseName
        let sessionID = syncSessionID
        let snapshot = database
        let previousState = rowSync
        syncInFlight = true
        syncState = .syncing
        Log.info("sync", "ios cursor recovery started for \"\(name)\" pending=\(previousState.dirtyUpserts.count + previousState.dirtyDeletes.count)")
        defer { syncInFlight = false }
        do {
            let protected = try await BackupPackage.capture(
                store: store,
                name: name,
                database: snapshot,
                vaultKey: snapshotKey,
                syncState: previousState,
                cloud: BackupPackage.CloudSource(
                    client: relayClient, token: token, vaultID: binding.vaultId),
                cloudRequired: true)
            try validateSyncSession(name: name, key: snapshotKey, sessionID: sessionID)
            var state = RowSyncState()
            state.importedSourceKeys = previousState.importedSourceKeys
            state.dirtyDeletes = previousState.dirtyDeletes
            let rebuilt = try await RowSync.fullRebuild(
                client: relayClient,
                token: token,
                vaultId: binding.vaultId,
                key: RowSyncKey(raw: snapshotKey.withUnsafeBytes { Data($0) }),
                localDatabase: PasswordDatabase(),
                state: &state)
            state.quarantinedCandidates = previousState.quarantinedCandidates
            try validateSyncSession(name: name, key: snapshotKey, sessionID: sessionID)
            try commitSyncSnapshot(rebuilt, name: name, vaultKey: snapshotKey, state: state)
            database = rebuilt
            rowSync = state
            syncCursorRecoveryRequired = false
            syncState = .idle
            showToast(String(format: L10n.t("sync_cursor_recovery_success_fmt"),
                             protected.url.lastPathComponent))
            Log.info(
                "sync",
                "ios cursor recovery committed backup=\(protected.url.lastPathComponent) complete=\(protected.assessment.isComplete)")
            Task { [weak self] in await self?.sync(auto: true) }
        } catch {
            guard syncSessionID == sessionID, databaseName == name else { return }
            syncState = .failed(error.localizedDescription)
            Log.error("sync", "ios cursor recovery failed for \"\(name)\": \(error)")
            showToast(error.localizedDescription)
        }
    }

    /// sync: — 拉取(游标增量) → 上行(脏集合 CAS),§6.2/§6.3。
    /// auto = true 为自动同步:静默执行;手动同步(下拉刷新/立即同步)反馈
    /// 结果:已是最新 / 拉取·上传条数 / 失败原因。
    /// - Returns: 本次结果;未执行(锁屏/未绑定/已在同步中)返回 nil
    @discardableResult
    func sync(auto: Bool = false) async -> RowSyncOutcome? {
        // 锁屏状态下禁止同步:库已清空、密码已抹,继续走会以空密码加密空库
        // 覆盖云端(真实事故:锁屏态同步把空库传上了服务端)
        guard !locked else {
            Log.warn("sync", "ios sync skipped: vault locked")
            return nil
        }
        guard let binding = relay.binding(database: databaseName),
              let token = relay.token(database: databaseName) else {
            syncState = .idle
            Log.debug("sync", "ios sync skipped: relay not bound")
            if !auto { showToast(L10n.t("sync_disabled_state")) }
            return nil
        }
        guard !syncInFlight else {
            Log.debug("sync", "ios sync skipped: already in flight")
            if !auto { showToast(L10n.t("sync_in_progress_toast")) }
            return nil
        }
        guard let snapshotKey = vaultKey else {
            syncState = .failed(L10n.t("sync_error"))
            Log.error("sync", "ios sync aborted: no vault key in session")
            return nil
        }
        syncInFlight = true
        syncState = .syncing
        lastSyncAttempt = Date()
        defer { syncInFlight = false }
        let name = databaseName
        let sessionID = syncSessionID
        let snapshot = database
        let key = RowSyncKey(raw: snapshotKey.withUnsafeBytes { Data($0) })
        var state = rowSync
        Log.info("sync", "ios sync \"\(name)\" started (rows\(auto ? ", auto" : ""))")
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
                    Log.info("sync", "ios legacy content baseline migration started")
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
                Log.warn("sync", "ios cursor expired — full rebuild")
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
                Log.warn("sync", "ios peer rekey detected (version → \(signal.passwordVersion)) — force locking")
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
                Log.info("sync", "ios sync checkpoint committed before continuing after quarantine")
            } else {
                let pushed = try await RowSync.push(
                    client: relayClient, token: token, vaultId: binding.vaultId,
                    key: key, database: &db, state: &state)
                outcome.pushedItems = pushed.pushedItems
                outcome.conflictsResolved = pushed.conflictsResolved
            }
            try validateSyncSession(name: name, key: snapshotKey, sessionID: sessionID)
            guard database.xmlData() == snapshot.xmlData() else {
                Log.warn("sync", "ios sync snapshot discarded: local edits arrived during await")
                throw DatabaseCipher.CipherError(message: L10n.t("sync_error"))
            }
            try commitSyncSnapshot(db, name: name, vaultKey: snapshotKey,
                                   state: state, envelope: adoptedEnvelope)
            database = db
            rowSync = state
            scheduleMissingAttachmentDownloads()
            relay.recordPasswordVersion(record.passwordVersion, database: name)
            syncRemoteUnreadable = false
            let finished = Date()
            d.set(finished.timeIntervalSince1970, forKey: DefaultsKey.lastSync(database: databaseName))
            lastSync = finished
            syncCursorRecoveryRequired = false
            syncState = .idle
            Log.info("sync", "ios sync \"\(databaseName)\" finished via rows (cursor=\(state.cursor) pending=\(state.dirtyUpserts.count + state.dirtyDeletes.count))")
            if !auto {
                if state.quarantinedItems.count > 0 && outcome.quarantinedItems > 0 {
                    showToast(String(format: L10n.t("sync_quarantine_summary_fmt"),
                                     state.quarantinedItems.count))
                } else if outcome.pulledItems == 0 && outcome.pushedItems == 0 {
                    showToast(L10n.t("sync_result_latest"))
                } else {
                    showToast(String(format: L10n.t("sync_result_fmt"), outcome.pulledItems, outcome.pushedItems))
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
            Log.error("sync", "ios row sync did not commit: \(error)")
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
                    Log.error("sync", "ios conflict marker persistence failed: \(error)")
                }
            }
            // 调用任务被取消(下拉刷新中断/切页):静默收场,不作为失败上报
            if Task.isCancelled {
                syncState = .idle
                Log.debug("sync", "ios sync task cancelled (ignored)")
                return nil
            }
            syncState = .failed(error.localizedDescription)
            Log.error("sync", "ios sync \"\(databaseName)\" failed: \(error)")
            if !auto {
                showToast("\(L10n.t("sync_error")): \(error.localizedDescription)")
            }
        }
        return nil
    }
}
