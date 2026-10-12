import Foundation
import CryptoKit

import UPasswordsCore
import UPasswordsPersistence

// MARK: - iOS 云同步:手动与自动同步/冲突裁决(与 macOS 同一套判定语义)
//
// 同步通道为账户中继(注册表信封决胜 + 服务端库体副本);冲突判定复用
// Persistence 的 SyncConflict 基线比较与 PasswordDatabase.merge 收敛合并;
// 本体经库密钥加解密(v2 信封),基线哈希存共享 defaults。

extension Vault {
    // MARK: 同步进行态

    /// 同步状态(仅驱动 UI 呈现;conflict 以 pendingSyncConflict 单独承载)。
    enum SyncPhase: Equatable {
        case idle
        case syncing
        case failed(String)
    }

    /// 最小自动同步间隔(秒),防止高频误触发。
    static let minAutoSyncSeconds = 30

    /// 信封 changedAt 的时钟偏差容差(秒):差值不超过它视为同一时刻,
    /// 不触发信封决胜(两端时钟不可能完全同步)。
    private static let envelopeClockSkewTolerance: TimeInterval = 1

    // MARK: 接管远端

    /// 接管远端的结果:成功 / 密码不对。
    enum AdoptResult {
        case success, wrongPassword
    }

    /// 双端各自独立建库会产生不同库密钥;以云端信封为准收敛库身份
    /// (本地本体换密钥重写 + 信封重裹,此后双端同身份,不再分歧)。
    private func joinRemoteVaultIdentity(_ remoteVEK: SymmetricKey) {
        let differs = vaultKey.map {
            $0.withUnsafeBytes { Data($0) } != remoteVEK.withUnsafeBytes { Data($0) }
        } ?? true
        guard differs else { return }
        do {
            vaultKey = remoteVEK
            try store.save(database, name: databaseName, vaultKey: remoteVEK)
            try store.rewrap(name: databaseName, vaultKey: remoteVEK, newPassword: password)
            Log.warn("sync", "ios vault identity converged to remote envelope (local body re-keyed)")
        } catch {
            Log.error("sync", "ios vault identity convergence failed: \(error)")
        }
    }

    /// 远端用「其他设备改后的新主密码」加密时的接管流程:
    /// 输入新密码 → 解注册表信封收敛库身份 → 合并服务端库体 → 本地以新密码
    /// 重加密落盘并更新钥匙串 → 上传合并结果。
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
            if let body = try? await relayClient.getBody(token: token, vaultId: binding.vaultId),
               DatabaseCipher.isV2Container(body),
               let plain = try? DatabaseCipher.decryptBody(body, vaultKey: remoteVEK),
               let remote = try? PasswordDatabase.parse(plain) {
                var merged = database
                merged.merge(with: remote)
                database = merged
                try store.save(merged, name: databaseName, vaultKey: remoteVEK)
                let out = try DatabaseCipher.encryptBody(merged.xmlData(), vaultKey: remoteVEK)
                try await relayClient.putBody(token: token, vaultId: binding.vaultId, cipher: out)
                await relayReportHashes(cipher: out)
                recordSyncBaseline()
            }
            syncRemoteUnreadable = false
            Log.info("sync", "ios adopted new password via envelope (identity converged, body merged)")
            return .success
        } catch {
            Log.warn("sync", "ios adopt remote password failed: \(error)")
            return .wrongPassword
        }
    }

    /// 远端不可解密(旧主密码加密/数据损坏)时的修复:以当前密码重传本地库并重设基线。
    /// 会丢弃云端现有内容,UI 层须先经用户确认。
    func overwriteUnreadableRemote() async {
        guard let binding = relay.binding(database: databaseName),
              let token = relay.token(database: databaseName), let vaultKey else { return }
        syncState = .syncing
        do {
            let out = try DatabaseCipher.encryptBody(database.xmlData(), vaultKey: vaultKey)
            try await relayClient.putBody(token: token, vaultId: binding.vaultId, cipher: out)
            await relayReportHashes(cipher: out)
            await relayPushEnvelope()
            recordSyncBaseline()
            syncRemoteUnreadable = false
            syncState = .idle
            Log.info("sync", "ios sync \"\(databaseName)\": overwrote unreadable remote (\(out.count)B)")
            showToast(L10n.t("last_sync_completed_prompt") + " "
                + (lastSync?.formatted(date: .abbreviated, time: .shortened) ?? ""))
        } catch {
            syncState = .failed(error.localizedDescription)
            Log.error("sync", "ios overwrite unreadable remote failed: \(error)")
            showToast("\(L10n.t("sync_error")): \(error.localizedDescription)")
        }
    }

    // MARK: 基线

    /// 记录本次成功同步的基线哈希与完成时间,供下次同步做冲突判定。
    /// 调用前提:此刻 `database` 即为刚上传(或确认与远端一致)的内容。
    private func recordSyncBaseline() {
        let contentHash = SyncConflict.sha256Hex(database.xmlData())
        d.set(contentHash, forKey: DefaultsKey.baselineLocalXML(database: databaseName))
        d.set(contentHash, forKey: DefaultsKey.baselineRemoteXML(database: databaseName))
        d.set(Date().timeIntervalSince1970, forKey: DefaultsKey.lastSync(database: databaseName))
        lastSync = Date()
        Log.debug("sync", "ios baseline recorded for \"\(databaseName)\"")
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

    /// 到期检查:启用自动同步、relay 已绑定、非同步中才发起;
    /// 有未决冲突时不再发起新同步(冲突弹窗由 RootView 常驻呈现,裁决后恢复)。
    func autoSyncTick() {
        guard !locked, autoSyncEnabled,
              relay.binding(database: databaseName) != nil,
              relay.token(database: databaseName) != nil,
              syncState != .syncing else { return }
        if pendingSyncConflict != nil { return }
        let interval = TimeInterval(max(autoSyncSeconds, Self.minAutoSyncSeconds))
        if let last = lastSync, Date().timeIntervalSince(last) < interval { return }
        // 失败退避:距上次尝试(无论成败)不足间隔时不重试,
        // 避免服务端不可用时每个 5s tick 都重放一遍失败
        if let attempt = lastSyncAttempt, Date().timeIntervalSince(attempt) < interval { return }
        Log.info("sync", "ios auto sync due (interval \(Int(interval))s)")
        Task { await sync(auto: true) }
    }

    // MARK: 同步主流程

    /// sync: — 注册表信封决胜/冲突判定/merge/库体提交(账户中继通道)。
    /// auto = true 为自动同步:静默执行(成功不打 toast,失败只记日志与状态)。
    func sync(auto: Bool = false) async {
        // 锁屏状态下禁止同步:库已清空、密码已抹,继续走会以空密码加密空库
        // 覆盖云端(真实事故:锁屏态同步把空库传上了服务端)
        guard !locked else {
            Log.warn("sync", "ios sync skipped: vault locked")
            return
        }
        // 通道唯一:账户中继(注册表信封 + 服务端库体副本)
        guard let apiBinding = relay.binding(database: databaseName),
              let apiToken = relay.token(database: databaseName) else {
            syncState = .idle
            Log.debug("sync", "ios sync skipped: relay not bound (account not logged in or vault not bound)")
            if !auto { showToast(L10n.t("sync_disabled_state")) }
            return
        }
        guard !syncInFlight else {
            Log.debug("sync", "ios sync skipped: already in flight")
            return
        }
        syncInFlight = true
        syncState = .syncing
        lastSyncAttempt = Date()
        defer { syncInFlight = false }
        Log.info("sync", "ios sync \"\(databaseName)\" started (relay\(auto ? ", auto" : ""))")
        persist()
        do {
            // 注册表(强一致):信封决胜 + 密码版本高水位 + 内容短路
            var sessionKey = vaultKey
            let knownVersionBeforeFetch = relay.knownPasswordVersion(database: databaseName) ?? 0
            if let record = await relayRegistryRecord() {
                let localChangedAt = store.envelopeData(for: databaseName)
                    .flatMap { DatabaseCipher.envelopeChangedAt($0) } ?? .distantPast
                let remoteChangedAt = record.envelopeChangedAt ?? .distantPast
                if let remoteEnvelope = record.envelope,
                   remoteChangedAt.timeIntervalSince(localChangedAt) > Self.envelopeClockSkewTolerance {
                    if let remoteVEK = try? DatabaseCipher.unwrapVaultKey(remoteEnvelope, password: password) {
                        joinRemoteVaultIdentity(remoteVEK)
                        sessionKey = remoteVEK
                        Log.info("sync", "ios relay envelope adopted (remote changedAt newer)")
                    } else if record.passwordVersion > knownVersionBeforeFetch {
                        // 版本前进 + 会话密码解不开新信封 = 他机改密 → 强制锁定换新密码
                        Log.warn("sync", "ios sync detected remote password change (version → \(record.passwordVersion))")
                        forceLockForRemotePasswordChange(remoteEnvelope)
                        return
                    } else {
                        syncRemoteUnreadable = true
                        syncState = .failed(L10n.t("sync_remote_unreadable_error"))
                        Log.error("sync", "ios relay envelope unwrap failed")
                        if !auto { showToast(L10n.t("sync_remote_unreadable_error")) }
                        return
                    }
                } else if localChangedAt.timeIntervalSince(remoteChangedAt) > Self.envelopeClockSkewTolerance,
                          store.envelopeData(for: databaseName) != nil {
                    // 本地信封更新(含注册表尚无信封的首次接入):自愈推送
                    Task { await relayPushEnvelope() }
                }
                // 内容短路:本地明文 XML == 注册表内容 → 本轮零库体往返
                if let remoteXml = record.xmlSha256,
                   remoteXml == SyncConflict.sha256Hex(database.xmlData()) {
                    lastSync = Date()
                    syncState = .idle
                    Log.info("sync", "ios relay short-circuit: content unchanged — skipping body round-trip")
                    if !auto { showToast(L10n.t("last_sync_completed_prompt")) }
                    return
                }
            }
            // 库体拉取(服务端副本);无副本 = 该库首次接入,本轮直接上传本地
            var remoteData: Data?
            do {
                remoteData = try await relayClient.getBody(token: apiToken, vaultId: apiBinding.vaultId)
            } catch RelayClient.RelayError.notFound {
                remoteData = nil
                Log.info("sync", "ios relay body absent — uploading local as first copy")
            }
            var local = database
            if let remoteData {
                let plain: Data
                do {
                    // 无库密钥说明信封环节已失败
                    guard let sessionKey else { throw SyncError.wrongPassword }
                    plain = try DatabaseCipher.decryptBody(remoteData, vaultKey: sessionKey)
                } catch {
                    // 远端仍是旧主密码加密(或已损坏):不进入合并,挂起修复入口由用户裁决
                    syncRemoteUnreadable = true
                    syncState = .failed(L10n.t("sync_remote_unreadable_error"))
                    Log.error("sync", "ios sync \"\(databaseName)\": remote undecryptable — overwrite option offered")
                    if !auto { showToast(L10n.t("sync_remote_unreadable_error")) }
                    return
                }
                let remote = try PasswordDatabase.parse(plain)
                Log.info("sync", "ios remote: \(remote.cards.count) cards, \(remote.labels.count) labels; local: \(local.cards.count) cards")
                let localHash = SyncConflict.sha256Hex(local.xmlData())
                // 远端比较用「明文内容哈希」而非密文字节:密文每次上传都换随机
                // nonce,同样内容重传后哈希必变,会被误判为远端有修改(双端乒乓)
                let remoteHash = SyncConflict.sha256Hex(remote.xmlData())
                let verdict = SyncConflict.evaluate(
                    localXMLHash: localHash,
                    remoteXMLHash: remoteHash,
                    baselines: SyncConflict.Baselines(
                        localXMLHash: d.string(forKey: DefaultsKey.baselineLocalXML(database: databaseName)),
                        remoteXMLHash: d.string(forKey: DefaultsKey.baselineRemoteXML(database: databaseName))))
                guard verdict != .conflict else {
                    // 本地与云端自上次同步后都有修改:交给用户决定覆盖方向
                    Log.warn("sync", "ios conflict \"\(databaseName)\": local and remote both changed — asking user")
                    pendingSyncConflict = PendingSyncConflict(
                        remoteData: remoteData,
                        localCards: local.cards.count,
                        localLabels: local.labels.count,
                        remoteCards: remote.cards.count,
                        remoteLabels: remote.labels.count)
                    syncState = .idle
                    return
                }
                // 双方自基线起均无变化:纯轮询命中,跳过上传(防无意义重传乒乓)
                if localHash == d.string(forKey: DefaultsKey.baselineLocalXML(database: databaseName)),
                   remoteHash == d.string(forKey: DefaultsKey.baselineRemoteXML(database: databaseName)) {
                    lastSync = Date()
                    syncState = .idle
                    Log.info("sync", "ios no changes since baseline — skipping upload")
                    return
                }
                Log.info("sync", "ios no conflict — merging")
                local.merge(with: remote)
                database = local
                persist()
                // 合并后内容与远端一致(本地原本落后,纯拉取场景):本地无可贡献,
                // 不回传——回传只会刷新密文 nonce,徒增对端"远端变更"误判
                if SyncConflict.sha256Hex(database.xmlData()) == remoteHash {
                    recordSyncBaseline()
                    syncState = .idle
                    Log.info("sync", "ios merged content equals remote — skipping upload")
                    if !auto { showToast(L10n.t("last_sync_completed_prompt")) }
                    return
                }
            } else {
                Log.info("sync", "ios no remote database yet — uploading local")
            }
            guard let vaultKey else {
                Log.error("sync", "ios sync aborted: no vault key in session")
                syncState = .failed(L10n.t("sync_error"))
                return
            }
            let out = try DatabaseCipher.encryptBody(database.xmlData(), vaultKey: vaultKey)
            // 读-改-写护栏:提交前再取一次,窗口内有他机提交先并入
            if let seen = remoteData,
               let fresh = try? await relayClient.getBody(token: apiToken, vaultId: apiBinding.vaultId),
               fresh != seen,
               let freshPlain = try? DatabaseCipher.decryptBody(fresh, vaultKey: vaultKey),
               let freshRemote = try? PasswordDatabase.parse(freshPlain) {
                var merged = database
                merged.merge(with: freshRemote)
                database = merged
                persist()
                Log.warn("sync", "ios relay body changed mid-sync — merged fresh remote (\(freshRemote.cards.count) cards) before commit")
            }
            try await relayClient.putBody(token: apiToken, vaultId: apiBinding.vaultId, cipher: out)
            await relayReportHashes(cipher: out)
            recordSyncBaseline()
            syncRemoteUnreadable = false
            syncState = .idle
            Log.info("sync", "ios sync \"\(databaseName)\" finished via relay (uploaded \(out.count)B)")
            if !auto {
                showToast(L10n.t("last_sync_completed_prompt") + " "
                    + (lastSync?.formatted(date: .abbreviated, time: .shortened) ?? ""))
            }
        } catch {
            syncState = .failed(error.localizedDescription)
            Log.error("sync", "ios sync \"\(databaseName)\" failed: \(error)")
            if !auto {
                showToast("\(L10n.t("sync_error")): \(error.localizedDescription)")
            }
        }
    }

    // MARK: 冲突裁决

    /// 用户裁决同步冲突:useLocal = true 用本地覆盖云端(丢弃云端自上次同步后
    /// 的修改),否则用云端覆盖本地(丢弃本地自上次同步后的修改)。
    /// 裁决后重设基线,后续同步恢复正常。
    func resolveSyncConflict(useLocal: Bool) async {
        guard let conflict = pendingSyncConflict else { return }
        pendingSyncConflict = nil
        Log.info("sync", "ios conflict resolution \"\(databaseName)\": overwrite \(useLocal ? "remote with local" : "local with remote")")
        syncState = .syncing
        do {
            if !useLocal {
                // 用云端覆盖本地:整库替换为远端版本并落盘
                guard let vaultKey else {
                    syncState = .idle
                    Log.error("sync", "ios conflict resolution aborted: no vault key in session")
                    return
                }
                let plain = try DatabaseCipher.decryptBody(conflict.remoteData, vaultKey: vaultKey)
                let remote = try PasswordDatabase.parse(plain)
                database = remote
                persist()
                Log.info("sync", "ios local replaced by remote (\(remote.cards.count) cards, \(remote.labels.count) labels)")
            }
            guard let vaultKey else {
                syncState = .idle
                Log.error("sync", "ios conflict resolution aborted: no vault key in session")
                return
            }
            guard let binding = relay.binding(database: databaseName),
                  let token = relay.token(database: databaseName) else {
                syncState = .idle
                Log.warn("sync", "ios conflict resolution \"\(databaseName)\" aborted: relay not bound")
                return
            }
            let out = try DatabaseCipher.encryptBody(database.xmlData(), vaultKey: vaultKey)
            try await relayClient.putBody(token: token, vaultId: binding.vaultId, cipher: out)
            await relayReportHashes(cipher: out)
            recordSyncBaseline()
            syncState = .idle
            Log.info("sync", "ios conflict resolution \"\(databaseName)\" finished (uploaded \(out.count)B)")
            showToast(L10n.t("last_sync_completed_prompt") + " "
                + (lastSync?.formatted(date: .abbreviated, time: .shortened) ?? ""))
        } catch {
            // 裁决上传失败:基线不动,下次同步会重新检测并再次询问
            syncState = .failed(error.localizedDescription)
            Log.error("sync", "ios conflict resolution \"\(databaseName)\" failed: \(error)")
            showToast("\(L10n.t("sync_error")): \(error.localizedDescription)")
        }
    }

    /// 冲突弹窗选「稍后」:丢弃暂存现场、基线不动,下次同步重新检测并再次询问。
    func postponeSyncConflict() {
        guard pendingSyncConflict != nil else { return }
        pendingSyncConflict = nil
        syncState = .idle
        Log.info("sync", "ios conflict \"\(databaseName)\" postponed by user")
    }
}
