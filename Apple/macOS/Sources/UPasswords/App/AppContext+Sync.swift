import Foundation
import CryptoKit
import UPasswordsCore
import UPasswordsPersistence

/// 修改密码、备份、云同步(账户中继 api.upasswords.com:注册表信封决胜
/// + 服务端库体副本,见 Cloud/DESIGN.md)。
extension AppContext {

    // MARK: - Change password

    /// 修改主密码:始终轮换库密钥(全新 VEK + 本体重加密)——旧密文
    /// (历史残留副本/备份/已泄露副本)对旧密码永久作废,省去用户判断是否轮换的心智。
    /// 云端顺序:信封先行(版本推进 → 他机强制锁定),库体随后原子换代。
    func changePassword(current: String, new: String) throws {
        guard current == password else {
            Log.warn("db", "changePassword \"\(databaseName)\" failed: wrong current password")
            throw DatabaseCipher.CipherError(message: L10n.t("wrong_password_error"))
        }
        guard vaultKey != nil else {
            Log.error("db", "changePassword \"\(databaseName)\" failed: no vault key in session")
            throw DatabaseCipher.CipherError(message: L10n.t("sync_error"))
        }
        let effectiveKey = DatabaseCipher.generateVaultKey()
        try store.save(database, name: databaseName, vaultKey: effectiveKey)
        try store.rewrap(name: databaseName, vaultKey: effectiveKey, newPassword: new)
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
        // 云端接力(账户中继):信封先行(他机强锁定/直接认新密码),库体随后换代。
        if relayBound {
            Task {
                await relayPushEnvelope()
                let rotated = try? DatabaseCipher.encryptBody(database.xmlData(), vaultKey: effectiveKey)
                if let rotated {
                    await relayPushBody(cipher: rotated)
                    await relayReportHashes(cipher: rotated)
                }
            }
        } else {
            Log.info("sync", "password changed with relay unbound — other devices adopt via next sync")
        }
    }

    // MARK: - Backup

    func backupNow() {
        save()
        do {
            try store.backup(name: databaseName)
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
            try store.backup(name: databaseName)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "backup.last.\(databaseName)")
            Log.info("backup", "auto backup of \"\(databaseName)\" ok")
            syncAfterBackup(auto: true)
        } catch {
            Log.error("backup", "auto backup of \"\(databaseName)\" failed: \(error)")
        }
    }

    /// 备份完成后顺带触发一次云同步,把最新本地库推上云端(备份快照仍只存本地)。
    /// auto = true 走静默同步(自动备份场景);手动备份用 auto = false,成败均有 toast。
    /// 库未绑定中继时跳过;已有同步在飞行中时也跳过——那一次同步同样会带走最新数据。
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

    // MARK: - Cloud sync

    /// 自动同步间隔下限(秒):防止误设过小的间隔频繁打服务端。
    private static let minAutoSyncSeconds = 30

    /// 信封 changedAt 的时钟偏差容差(秒):差值不超过它视为同一时刻,
    /// 不触发信封决胜(两端时钟不可能完全同步)。
    private static let envelopeClockSkewTolerance: TimeInterval = 1

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
            Log.warn("sync", "vault identity converged to remote envelope (local body re-keyed)")
        } catch {
            Log.error("sync", "vault identity convergence failed: \(error)")
        }
    }

    /// 远端不可解密修复 A:输入「其他设备改后的新主密码」接管远端——
    /// 解码远端并合并进本地 → 本地以新密码重加密落盘并更新钥匙串 → 上传合并结果。
    /// 通道:注册表信封(强一致源)+ 服务端库体副本。
    @discardableResult
    func adoptRemotePassword(_ newPassword: String) async -> AdoptResult {
        guard let binding = relay.binding(database: databaseName),
              let token = relay.token(database: databaseName) else { return .wrongPassword }
        do {
            guard let registryRecord = await relayRegistryRecord(),
                  let envelope = registryRecord.envelope else {
                Log.warn("sync", "adopt failed: registry record or envelope unavailable")
                return .wrongPassword
            }
            guard let remoteVEK = try? DatabaseCipher.unwrapVaultKey(envelope, password: newPassword) else {
                Log.warn("sync", "adopt: envelope unwrap failed with given password")
                return .wrongPassword
            }
            vaultKey = remoteVEK
            password = newPassword
            try store.rewrap(name: databaseName, vaultKey: remoteVEK, newPassword: newPassword)
            PasswordStore.savePassword(newPassword, databaseName: databaseName)
            if settings.fastUnlock && PasswordStore.biometricAvailable() {
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
            SafariSnapshotBridge.push(databaseName: databaseName, store: store)
            Log.info("sync", "adopted new password via envelope (identity converged, body merged)")
            return .success
        } catch {
            Log.warn("sync", "adopt remote password failed: \(error)")
            return .wrongPassword
        }
    }

    /// 远端不可解密修复 B:以本地数据覆盖云端(确认后调用),会丢弃云端现有内容。
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
            lastSync = Date()
            syncState = .idle
            Log.info("sync", "overwrite unreadable remote ok (\(out.count)B)")
            AppToast.shared.show(L10n.t("last_sync_completed_prompt"))
        } catch {
            syncState = .error(error.localizedDescription)
            Log.error("sync", "overwrite unreadable remote failed: \(error)")
            AppToast.shared.show(error.localizedDescription)
        }
    }

    /// 服务端通道恢复(新设备向导):注册表信封 + 服务端库体镜像 →
    /// 解密校验后落为本地库,直接解锁进入主界面。前提:该库在服务端有
    /// 库体镜像(记录 bodyUpdatedAt 非空);绑定与版本基准由解锁后的
    /// relayBindCurrentVaultIfNeeded 自动补齐(按库名认领现有注册,不产生重复 vaultId)。
    func restoreDatabaseFromRelay(record: RelayClient.VaultRecord,
                                  password: String) async throws {
        guard let email = relay.lastAccountEmail,
              let token = relay.token(email: email) else { throw SyncError.notConfigured }
        let name = record.name
        Log.info("lifecycle", "restore from relay \"\(name)\" (vault=\(record.vaultId.prefix(8))…)")
        guard !store.exists(name) else {
            Log.warn("lifecycle", "restore from relay \"\(name)\" aborted: local database exists")
            throw SyncError.localNameConflict
        }
        let detail = try await relayClient.getVault(token: token, vaultId: record.vaultId)
        guard let envelope = detail.envelope else {
            Log.warn("lifecycle", "restore from relay \"\(name)\": registry has no envelope")
            throw DatabaseCipher.CipherError(message: L10n.t("envelope_missing_error"))
        }
        let data: Data
        do {
            data = try await relayClient.getBody(token: token, vaultId: record.vaultId)
        } catch RelayClient.RelayError.notFound {
            Log.warn("lifecycle", "restore from relay \"\(name)\": server body mirror missing")
            throw SyncError.databaseNotFound
        }
        guard DatabaseCipher.isV2Container(data) else {
            Log.warn("lifecycle", "restore from relay \"\(name)\": not a v2 container")
            throw DatabaseCipher.CipherError(message: L10n.t("wrong_database_format_error"))
        }
        let vek = try DatabaseCipher.unwrapVaultKey(envelope, password: password)
        let plain = try DatabaseCipher.decryptBody(data, vaultKey: vek)
        let db = try PasswordDatabase.parse(plain)
        try store.save(db, name: name, vaultKey: vek)
        try store.saveEnvelope(envelope, for: name)
        store.mainDatabaseName = name
        try unlock(name: name, password: password)
        markSetupTaskDone(.cloudSync)
        scheduleSilentBreachCheck()
        Log.info("lifecycle", "restore from relay \"\(name)\" ok (\(db.cards.count) cards)")
    }

    /// 本地文件恢复(新设备向导):从任意位置的一对 `<名>.upw`/`<名>.upwkey`
    /// 校验解密后落为本地库,直接解锁进入主界面——离线迁移路径
    /// (把备份文件从其他设备/硬盘拷来即可,不依赖任何云端通道)。
    /// PBKDF2 解信封与服务端恢复同样在主执行,耗时同量级(数百毫秒)。
    func restoreDatabaseFromLocalFiles(body: URL, envelope: URL, name: String, password: String) async throws {
        Log.info("lifecycle", "restore from local files \"\(name)\" (body=\(body.lastPathComponent))")
        _ = try store.restore(body: body, envelope: envelope, name: name, password: password)
        store.mainDatabaseName = name
        try unlock(name: name, password: password)
        scheduleSilentBreachCheck()
        Log.info("lifecycle", "restore from local files \"\(name)\" ok (\(database.cards.count) cards)")
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
              relay.binding(database: databaseName) != nil,
              relay.token(database: databaseName) != nil,
              syncState != .syncing else { return }
        // 有未决冲突时不发起新同步:等主窗空闲(无其他弹窗)即补呈现决策弹窗
        if pendingSyncConflict != nil {
            presentSyncConflictSheetIfPossible()
            return
        }
        let interval = TimeInterval(max(settings.autoSyncSeconds, Self.minAutoSyncSeconds))
        if let last = lastSync, Date().timeIntervalSince(last) < interval { return }
        Log.info("sync", "auto sync due (interval \(Int(interval))s)")
        Task { await sync(auto: true) }
    }

    // MARK: - Conflict resolution (冲突裁决)

    /// 上次成功同步的基线哈希键(按数据库分开):本地键与远端键均存
    /// 明文 XML **内容**哈希,作为下次同步"双方是否都改过"的判定参照
    /// (见 SyncConflict;两键此时语义相同,保留双键仅为兼容既有存量)。
    private var baselineLocalXMLKey: String { "sync.baseline.local.\(databaseName)" }
    private var baselineRemoteDataKey: String { "sync.baseline.remote.\(databaseName)" }

    /// 记录本次成功同步的基线哈希,供下次同步做冲突判定。
    /// 调用前提:此刻 `database` 即为刚上传(或确认与远端一致)的内容。
    private func recordSyncBaseline() {
        let defaults = UserDefaults.standard
        let contentHash = SyncConflict.sha256Hex(database.xmlData())
        defaults.set(contentHash, forKey: baselineLocalXMLKey)
        defaults.set(contentHash, forKey: baselineRemoteDataKey)
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
        Log.info("sync", "conflict resolution \"\(databaseName)\": overwrite \(useLocal ? "remote with local" : "local with remote")")
        syncState = .syncing
        do {
            if !useLocal {
                // 用云端覆盖本地:整库替换为远端版本并落盘
                guard let vaultKey else {
                    syncState = .idle
                    Log.error("sync", "conflict resolution aborted: no vault key in session")
                    return
                }
                let plain = try DatabaseCipher.decryptBody(conflict.remoteData, vaultKey: vaultKey)
                let remote = try PasswordDatabase.parse(plain)
                database = remote
                if let selected = selectedCardId, database.card(id: selected) == nil {
                    selectedCardId = database.activeCards.first?.id
                }
                save()
                Log.info("sync", "local replaced by remote (\(remote.cards.count) cards, \(remote.labels.count) labels)")
            }
            guard let vaultKey else {
                syncState = .idle
                Log.error("sync", "conflict resolution aborted: no vault key in session")
                return
            }
            guard let binding = relay.binding(database: databaseName),
                  let token = relay.token(database: databaseName) else {
                syncState = .idle
                Log.warn("sync", "conflict resolution \"\(databaseName)\" aborted: relay not bound")
                return
            }
            let out = try DatabaseCipher.encryptBody(database.xmlData(), vaultKey: vaultKey)
            try await relayClient.putBody(token: token, vaultId: binding.vaultId, cipher: out)
            await relayReportHashes(cipher: out)
            recordSyncBaseline()
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

    /// sync: — 注册表信封决胜/冲突判定/merge/库体提交(账户中继通道)。
    /// auto = true 为自动同步:静默执行(成功不打 toast,失败只记日志与状态)。
    func sync(auto: Bool = false) async {
        // 锁屏状态下禁止同步:密码已抹(空串),继续走会以空密码加密并
        // 覆盖云端/误报远端解不开(与 iOS 同款事故防护)
        guard phase == .unlocked else {
            Log.warn("sync", "sync skipped: vault locked")
            return
        }
        guard syncState != .syncing else {
            Log.debug("sync", "sync skipped: another sync already in flight")
            return
        }
        // 通道唯一:账户中继(注册表信封 + 服务端库体副本)
        guard let apiBinding = relay.binding(database: databaseName),
              let apiToken = relay.token(database: databaseName) else {
            syncState = .disabled
            Log.debug("sync", "sync skipped: relay not bound (account not logged in or vault not bound)")
            if !auto { AppToast.shared.show(L10n.t("not_configured_state")) }
            return
        }
        Log.info("sync", "sync \"\(databaseName)\" started (relay\(auto ? ", auto" : ""))")
        syncState = .syncing
        save()
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
                        Log.info("sync", "relay envelope adopted (remote changedAt newer)")
                    } else if record.passwordVersion > knownVersionBeforeFetch {
                        // 版本前进 + 会话密码解不开新信封 = 他机改密 → 强制锁定换新密码
                        Log.warn("sync", "sync detected remote password change (version → \(record.passwordVersion))")
                        forceLockForRemotePasswordChange(remoteEnvelope)
                        return
                    } else {
                        let firstHit = !syncRemoteUnreadable
                        syncRemoteUnreadable = true
                        syncState = .error(L10n.t("sync_remote_unreadable_error"))
                        Log.error("sync", "relay envelope unwrap failed (firstHit=\(firstHit))")
                        if firstHit {
                            promptAdoptRemotePassword()
                        } else if !auto {
                            AppToast.shared.show(L10n.t("sync_remote_unreadable_error"))
                        }
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
                    Log.info("sync", "relay short-circuit: content unchanged — skipping body round-trip")
                    if !auto { AppToast.shared.show(L10n.t("last_sync_completed_prompt")) }
                    return
                }
            }
            // 库体拉取(服务端副本);无副本 = 该库首次接入,本轮直接上传本地
            var remoteData: Data?
            do {
                remoteData = try await relayClient.getBody(token: apiToken, vaultId: apiBinding.vaultId)
            } catch RelayClient.RelayError.notFound {
                remoteData = nil
                Log.info("sync", "relay body absent — uploading local as first copy")
            }
            var local = database
            if let remoteData {
                let plain: Data
                do {
                    // 无库密钥说明信封环节已失败
                    guard let sessionKey else { throw SyncError.wrongPassword }
                    plain = try DatabaseCipher.decryptBody(remoteData, vaultKey: sessionKey)
                } catch {
                    // 远端被其他设备用新主密码重加密(或损坏):不进入合并,
                    // 主动弹窗引导输入新密码接管(边沿触发:同一事件只弹一次)
                    let firstHit = !syncRemoteUnreadable
                    syncRemoteUnreadable = true
                    syncState = .error(L10n.t("sync_remote_unreadable_error"))
                    Log.error("sync", "sync \"\(databaseName)\": remote undecryptable — adopt prompt offered (firstHit=\(firstHit))")
                    if firstHit {
                        promptAdoptRemotePassword()
                    } else if !auto {
                        // 自动同步的重试不打扰(修复前每轮都会失败),仅手动同步提示
                        AppToast.shared.show(L10n.t("sync_remote_unreadable_error"))
                    }
                    return
                }
                let remote = try PasswordDatabase.parse(plain)
                Log.info("sync", "remote: \(remote.cards.count) cards, \(remote.labels.count) labels; local: \(local.cards.count) cards")
                let localHash = SyncConflict.sha256Hex(local.xmlData())
                // 远端比较用「明文内容哈希」而非密文字节:密文每次上传都换随机
                // nonce,同样内容重传后哈希必变,会被误判为远端有修改(双端乒乓,
                // 详见 Cloud/DESIGN.md §4.2);内容域比较与 nonce 无关。
                let remoteHash = SyncConflict.sha256Hex(remote.xmlData())
                let verdict = SyncConflict.evaluate(
                    localXMLHash: localHash,
                    remoteXMLHash: remoteHash,
                    baselines: SyncConflict.Baselines(
                        localXMLHash: UserDefaults.standard.string(forKey: baselineLocalXMLKey),
                        remoteXMLHash: UserDefaults.standard.string(forKey: baselineRemoteDataKey)))
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
                // 双方自基线起均无变化:跳过上传(防无意义重传乒乓)
                if localHash == UserDefaults.standard.string(forKey: baselineLocalXMLKey),
                   remoteHash == UserDefaults.standard.string(forKey: baselineRemoteDataKey) {
                    lastSync = Date()
                    syncState = .idle
                    Log.info("sync", "no changes since baseline — skipping upload")
                    return
                }
                Log.info("sync", "no conflict — merging")
                local.merge(with: remote)
                database = local
                save()
                // 合并后内容与远端一致(本地原本落后,纯拉取场景):本地无可贡献,
                // 不回传——回传只会刷新密文 nonce,徒增对端"远端变更"误判
                if SyncConflict.sha256Hex(database.xmlData()) == remoteHash {
                    recordSyncBaseline()
                    lastSync = Date()
                    syncState = .idle
                    Log.info("sync", "merged content equals remote — skipping upload")
                    if !auto { AppToast.shared.show(L10n.t("last_sync_completed_prompt")) }
                    return
                }
            } else {
                Log.info("sync", "no remote database yet — uploading local")
            }
            guard let vaultKey else {
                Log.error("sync", "sync aborted: no vault key in session")
                syncState = .error(L10n.t("sync_error"))
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
                save()
                Log.warn("sync", "relay body changed mid-sync — merged fresh remote (\(freshRemote.cards.count) cards) before commit")
            }
            try await relayClient.putBody(token: apiToken, vaultId: apiBinding.vaultId, cipher: out)
            await relayReportHashes(cipher: out)
            recordSyncBaseline()
            syncRemoteUnreadable = false
            let finished = Date()
            lastSync = finished
            syncState = .idle
            Log.info("sync", "sync \"\(databaseName)\" finished via relay (uploaded \(out.count)B)")
            if !auto {
                AppToast.shared.show(L10n.t("last_sync_completed_prompt") + " "
                    + DateFormatter.localizedString(from: finished, dateStyle: .short, timeStyle: .short))
            }
        } catch {
            lastSyncFailed = Date()
            syncState = .error(error.localizedDescription)
            Log.error("sync", "sync \"\(databaseName)\" failed: \(error)")
            if !auto { AppToast.shared.show("\(L10n.t("sync_error")): \(error.localizedDescription)") }
        }
    }
}
