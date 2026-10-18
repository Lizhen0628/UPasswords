import Foundation
import CryptoKit

import UPasswordsCore
import UPasswordsPersistence

// MARK: - iOS 行级云同步(v7,与 macOS AppContext+Sync 同语义)
//
// 拉取(游标增量) → 上行(脏集合 CAS);冲突逐条 LWW 自动收敛,无整库弹窗。
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

    /// RowSyncKey 形态的会话 VEK(无密钥返回 nil,同步前置检查兜底)。
    private var rowSyncKey: RowSyncKey? {
        vaultKey.map { RowSyncKey(raw: $0.withUnsafeBytes { Data($0) }) }
    }

    /// 绑定新库时重置行同步状态:快照基线清空 → 下轮 sync 把全部条目当脏上行。
    func resetRowSyncForFreshBinding() {
        rowSync = RowSyncState()
        store.saveSyncState(rowSync, for: databaseName)
    }

    // MARK: 接管远端

    /// 接管远端的结果:成功 / 密码不对。
    enum AdoptResult {
        case success, wrongPassword
    }

    /// 远端用「其他设备改后的新主密码」加密时的接管流程:
    /// 输入新密码 → 解注册表信封收敛库身份 → 行级全量重建 → 本地以新密码落盘。
    @discardableResult
    func adoptRemotePassword(_ newPassword: String) async -> AdoptResult {
        guard let binding = relay.binding(database: databaseName),
              let token = relay.token(database: databaseName) else { return .wrongPassword }
        do {
            guard let registryRecord = await relayRegistryRecord(),
                  let envelope = registryRecord.envelope else {
                Log.warn("sync", "ios adopt failed: registry record or envelope unavailable")
                return .wrongPassword
            }
            guard let remoteVEK = try? DatabaseCipher.unwrapVaultKey(envelope, password: newPassword) else {
                Log.warn("sync", "ios adopt: envelope unwrap failed with given password")
                return .wrongPassword
            }
            vaultKey = remoteVEK
            password = newPassword
            try store.rewrap(name: databaseName, vaultKey: remoteVEK, newPassword: newPassword)
            PasswordStore.savePassword(newPassword, databaseName: databaseName)
            if PasswordStore.hasBiometricItem(databaseName: databaseName) {
                PasswordStore.savePasswordForBiometric(newPassword, databaseName: databaseName)
            }
            var state = rowSync
            let rebuilt = try await RowSync.fullRebuild(
                client: relayClient, token: token, vaultId: binding.vaultId,
                key: RowSyncKey(raw: remoteVEK.withUnsafeBytes { Data($0) }), state: &state)
            database = rebuilt
            try store.save(rebuilt, name: databaseName, vaultKey: remoteVEK)
            rowSync = state
            store.saveSyncState(state, for: databaseName)
            syncRemoteUnreadable = false
            Log.info("sync", "ios adopted new password via envelope (rows rebuilt: \(rebuilt.cards.count) cards)")
            return .success
        } catch {
            Log.warn("sync", "ios adopt remote password failed: \(error)")
            return .wrongPassword
        }
    }

    /// 远端不可解密(旧主密码加密/数据损坏)时的修复:以本地 VEK + 本地信封
    /// 跑一轮 rekey(原子替换服务端全部条目)。会丢弃云端现有内容,UI 层须先经用户确认。
    func overwriteUnreadableRemote() async {
        guard let binding = relay.binding(database: databaseName),
              let token = relay.token(database: databaseName),
              let key = vaultKey,
              let envelope = store.envelopeData(for: databaseName) else { return }
        syncState = .syncing
        do {
            var state = rowSync
            try await RowSync.rekey(
                client: relayClient, token: token, vaultId: binding.vaultId,
                database: database, newKey: RowSyncKey(raw: key.withUnsafeBytes { Data($0) }),
                newEnvelope: envelope, state: &state)
            rowSync = state
            store.saveSyncState(state, for: databaseName)
            syncRemoteUnreadable = false
            syncState = .idle
            Log.info("sync", "ios sync \"\(databaseName)\": overwrote unreadable remote (rows re-keyed)")
            showToast(L10n.t("last_sync_completed_prompt") + " "
                + (lastSync?.formatted(date: .abbreviated, time: .shortened) ?? ""))
        } catch {
            syncState = .failed(error.localizedDescription)
            Log.error("sync", "ios overwrite unreadable remote failed: \(error)")
            showToast("\(L10n.t("sync_error")): \(error.localizedDescription)")
        }
    }

    // MARK: 改密的云端接力

    /// rekey 全量换入(§6.5)。本端即改密端,成功后清游标全量对账,失败下轮自愈。
    func relayRekeyUpload(newKey: SymmetricKey, new newPassword: String) async {
        guard let binding = relay.binding(database: databaseName),
              let token = relay.token(database: databaseName) else { return }
        do {
            guard let envelope = try? DatabaseCipher.wrapVaultKey(newKey, password: newPassword) else {
                throw DatabaseCipher.CipherError(message: L10n.t("sync_error"))
            }
            try store.saveEnvelope(envelope, for: databaseName)
            var state = rowSync
            try await RowSync.rekey(
                client: relayClient, token: token, vaultId: binding.vaultId,
                database: database, newKey: RowSyncKey(raw: newKey.withUnsafeBytes { Data($0) }),
                newEnvelope: envelope, state: &state)
            rowSync = state
            store.saveSyncState(state, for: databaseName)
            relay.recordPasswordVersion(relay.knownPasswordVersion(database: databaseName).map { $0 + 1 } ?? 2,
                                        database: databaseName)
            Log.info("sync", "ios rekey uploaded for \"\(databaseName)\"")
        } catch {
            Log.warn("sync", "ios rekey upload deferred (will retry via next sync): \(error)")
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
        guard let key = rowSyncKey else {
            syncState = .failed(L10n.t("sync_error"))
            Log.error("sync", "ios sync aborted: no vault key in session")
            return nil
        }
        syncInFlight = true
        syncState = .syncing
        lastSyncAttempt = Date()
        defer { syncInFlight = false }
        Log.info("sync", "ios sync \"\(databaseName)\" started (rows\(auto ? ", auto" : ""))")
        persist()
        do {
            // 改密版本检查(信封唯一入口 = 建库/rekey,版本前进即他端改密)
            if let record = await relayRegistryRecord() {
                let known = relay.knownPasswordVersion(database: databaseName) ?? record.passwordVersion
                if record.passwordVersion > known, let envelope = record.envelope {
                    if (try? DatabaseCipher.unwrapVaultKey(envelope, password: password)) != nil {
                        try? store.saveEnvelope(envelope, for: databaseName)
                        Log.info("sync", "ios relay envelope adopted (password version advanced by this device)")
                    } else {
                        Log.warn("sync", "ios sync detected remote password change (version → \(record.passwordVersion))")
                        forceLockForRemotePasswordChange(envelope)
                        return nil
                    }
                }
            }
            var state = rowSync
            state.recomputeDirty(database: database)
            var db = database
            var outcome = RowSyncOutcome()
            do {
                let pulled = try await RowSync.pull(
                    client: relayClient, token: token, vaultId: binding.vaultId,
                    key: key, database: &db, state: &state)
                outcome.pulledItems = pulled.pulledItems
            } catch RelayClient.RelayError.cursorExpired {
                // 游标落后越过保留地板:全量重建(快照+差量)
                Log.warn("sync", "ios cursor expired — full rebuild")
                db = try await RowSync.fullRebuild(
                    client: relayClient, token: token, vaultId: binding.vaultId,
                    key: key, state: &state)
                outcome.pulledItems = db.cards.count + db.labels.count
            } catch let signal as RowSyncRekeySignal {
                // 对端 rekey:旧 VEK 解不开新密文,强制锁定接管
                Log.warn("sync", "ios peer rekey detected (version → \(signal.passwordVersion)) — force locking")
                if let record = await relayRegistryRecord(), let envelope = record.envelope {
                    forceLockForRemotePasswordChange(envelope)
                }
                syncState = .idle
                return nil
            }
            let pushed = try await RowSync.push(
                client: relayClient, token: token, vaultId: binding.vaultId,
                key: key, database: &db, state: &state)
            outcome.pushedItems = pushed.pushedItems
            outcome.conflictsResolved = pushed.conflictsResolved
            database = db
            rowSync = state
            store.saveSyncState(state, for: databaseName)
            persist()
            syncRemoteUnreadable = false
            let finished = Date()
            d.set(finished.timeIntervalSince1970, forKey: DefaultsKey.lastSync(database: databaseName))
            lastSync = finished
            syncState = .idle
            Log.info("sync", "ios sync \"\(databaseName)\" finished via rows (cursor=\(state.cursor) pending=\(state.dirtyUpserts.count + state.dirtyDeletes.count))")
            if !auto {
                // 手动同步反馈结果:无变化/拉取·上传条数(时间看设置页状态行)
                if outcome.pulledItems == 0 && outcome.pushedItems == 0 {
                    showToast(L10n.t("sync_result_latest"))
                } else {
                    showToast(String(format: L10n.t("sync_result_fmt"), outcome.pulledItems, outcome.pushedItems))
                }
            }
            return outcome
        } catch RelayClient.RelayError.unauthorized {
            // 令牌过期/被撤销:清绑定转登录态,详见 Vault+Relay.handleSessionExpired
            handleSessionExpired()
        } catch {
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
