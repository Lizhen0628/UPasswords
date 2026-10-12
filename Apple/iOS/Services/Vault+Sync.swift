import Foundation
import CryptoKit

import UPasswordsCore
import UPasswordsPersistence

// MARK: - iOS 云同步:驱动构造/手动与自动同步/冲突裁决(与 macOS 同一套判定语义)
//
// 复用 Persistence 的 CloudDriver(WebDAV / iCloud Drive)、SyncConflict 基线判定与
// PasswordDatabase.merge 收敛合并;本体经库密钥加解密(v2 信封),基线哈希存共享 defaults。

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

    var cloud: CloudType { CloudType(rawValue: cloudTypeRaw) ?? .none }

    /// 信封 changedAt 的时钟偏差容差(秒):差值不超过它视为同一时刻,
    /// 不触发信封决胜(两端时钟不可能完全同步)。
    private static let envelopeClockSkewTolerance: TimeInterval = 1

    // MARK: iCloud 云端文件夹(iOS 沙盒经安全作用域书签访问云盘)

    /// 已保存 iCloud 云盘文件夹书签(设置页据此显示入口状态)。
    var hasICloudFolder: Bool { d.data(forKey: DefaultsKey.icloudBookmark) != nil }

    /// 记录用户在文件 App 里选定的云端目录(安全作用域书签持久化)。
    /// 选中的若是已有 .upw 的 UPasswords 文件夹则作为容器本体;
    /// 否则视为云盘根目录,容器取其下的 UPasswords/(首次同步自动创建)。
    /// - Returns: 书签保存是否成功
    @discardableResult
    func setICloudFolder(_ picked: URL) async -> Bool {
        let granted = picked.startAccessingSecurityScopedResource()
        defer { if granted { picked.stopAccessingSecurityScopedResource() } }
        guard let bookmark = try? picked.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else {
            Log.warn("sync", "ios icloud bookmark create failed for \"\(picked.lastPathComponent)\"")
            showToast(L10n.t("ios_icloud_folder_error"))
            return false
        }
        d.set(bookmark, forKey: DefaultsKey.icloudBookmark)
        d.set(picked.lastPathComponent, forKey: DefaultsKey.icloudFolderName)
        icloudFolderName = picked.lastPathComponent

        // 探测所选目录内容:决定容器模式(云盘根 → 容器取其下 UPasswords/)
        let driver = ICloudDriver(databaseName: databaseName, iCloudFolder: picked)
        let names = (try? await driver.listDatabases()) ?? []
        let isContainer = picked.lastPathComponent == "UPasswords" || !names.isEmpty
        d.set(isContainer ? "explicit" : "root", forKey: DefaultsKey.icloudMode)
        Log.info("sync", "ios icloud folder picked: \"\(picked.lastPathComponent)\", mode=\(isContainer ? "explicit" : "root"), cloud dbs=\(names.count)")
        return true
    }

    /// 文件导入的来源若在 iCloud 云盘:把所在文件夹存为云端容器书签并启用
    /// iCloud 同步(首次装机从云盘导入后同步开箱即用)。文档选择器对父目录的
    /// 安全作用域不作保证,失败仅记日志,用户仍可在设置里手动选文件夹。
    func adoptICloudFolderIfUbiquitous(fileURL: URL) {
        guard cloud == .none else { return }
        let ubiquitous = (try? fileURL.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
            || fileURL.path.contains("/Mobile Documents/")
        guard ubiquitous else { return }
        let folder = fileURL.deletingLastPathComponent()
        // 文件选择器只保证被选文件的作用域;父文件夹拿不到授权时造出的书签
        // 后续必然解析失败,不如不配置(用户可在设置里手动选文件夹)
        let granted = folder.startAccessingSecurityScopedResource()
        guard granted else {
            Log.info("sync", "ios import: no scope for folder \"\(folder.lastPathComponent)\" — skip auto sync setup")
            return
        }
        defer { folder.stopAccessingSecurityScopedResource() }
        guard let bookmark = try? folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else {
            Log.warn("sync", "ios import: icloud folder bookmark failed for \"\(folder.lastPathComponent)\" — pick manually in settings")
            return
        }
        d.set(bookmark, forKey: DefaultsKey.icloudBookmark)
        d.set(folder.lastPathComponent, forKey: DefaultsKey.icloudFolderName)
        // 导入的 .upw 直接躺在该文件夹里 → 该文件夹即同步容器
        d.set("explicit", forKey: DefaultsKey.icloudMode)
        icloudFolderName = folder.lastPathComponent
        cloudTypeRaw = CloudType.icloud.rawValue
        Log.info("sync", "ios import: adopted icloud folder \"\(folder.lastPathComponent)\", sync enabled")
    }

    /// 解析书签并取得安全作用域访问权;调用方必须在用完后调用返回的
    /// release 闭包(stopAccessingSecurityScopedResource)。
    private func resolveICloudFolder() -> (folder: URL, release: () -> Void)? {
        guard let data = d.data(forKey: DefaultsKey.icloudBookmark) else {
            Log.info("sync", "ios icloud folder not picked yet — pick it in settings first")
            return nil
        }
        var stale = false
        guard let folder = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            Log.warn("sync", "ios icloud bookmark resolve failed — cleared, re-pick folder in settings")
            // 无效书签(如无作用域造出的半成品)会造成永久“未配置”,清掉回到未选定状态
            d.removeObject(forKey: DefaultsKey.icloudBookmark)
            d.removeObject(forKey: DefaultsKey.icloudFolderName)
            icloudFolderName = ""
            return nil
        }
        guard folder.startAccessingSecurityScopedResource() else {
            Log.warn("sync", "ios icloud security scope denied for \"\(folder.lastPathComponent)\"")
            return nil
        }
        if stale, let refreshed = try? folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            // 书签过期(系统刷新路径):尽力续期,失败不影响本次同步
            d.set(refreshed, forKey: DefaultsKey.icloudBookmark)
            Log.debug("sync", "ios icloud bookmark refreshed")
        }
        return (folder, { folder.stopAccessingSecurityScopedResource() })
    }

    // MARK: 驱动与基线

    /// 当前云类型的驱动;iCloud 分支同时返回安全作用域访问权的释放闭包。
    /// 远端库名与本地库名一致(多库管理下由用户命名,跨端同名即同库)。
    func makeCloudDriver(databaseName name: String? = nil) -> (driver: CloudDriver, releaseAccess: (() -> Void)?)? {
        let dbName = name ?? databaseName
        switch cloud {
        case .webdav:
            return (WebDavDriver(settings: webdav, databaseName: dbName), nil)
        case .icloud:
            guard let mounted = resolveICloudFolder() else { return nil }
            let driver: ICloudDriver
            if d.string(forKey: DefaultsKey.icloudMode) == "root" {
                driver = ICloudDriver(databaseName: dbName, cloudRoot: mounted.folder)
            } else {
                driver = ICloudDriver(databaseName: dbName, iCloudFolder: mounted.folder)
            }
            return (driver, mounted.release)
        default:
            return nil
        }
    }

    /// 云端是否已就绪(iCloud 已选文件夹 / WebDAV 已填主机)。
    var cloudConfigured: Bool {
        switch cloud {
        case .icloud: return hasICloudFolder
        case .webdav: return !webdav.host.isEmpty
        default: return false
        }
    }

    /// 改主密码后的云端接力:v2 只需上传本地信封(~100B),本体不重传;
    /// 信封同时推送到网盘副本与 API 注册表(强一致通道)。
    func uploadCloudEnvelope() async {
        guard let mounted = makeCloudDriver(),
              let envelope = store.envelopeData(for: databaseName) else { return }
        defer { mounted.releaseAccess?() }
        do {
            try await mounted.driver.testConnection()
            try await mounted.driver.uploadKey(envelope)
            await relayPushEnvelope()
            Log.info("sync", "ios cloud handoff: envelope uploaded (\(envelope.count)B) after password change")
        } catch {
            Log.warn("sync", "ios cloud envelope handoff failed: \(error)")
        }
    }

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
    /// 输入新密码 → 解密远端并合并进本地 → 本地以新密码重加密落盘并更新钥匙串
    /// → 上传合并结果。库体通道:relay 绑定时走 API 副本,否则走网盘。
    @discardableResult
    func adoptRemotePassword(_ newPassword: String) async -> AdoptResult {
        let apiBinding = relay.binding(database: databaseName)
        let apiToken = relay.token(database: databaseName)
        let apiReady = apiBinding != nil && apiToken != nil
        let mounted = makeCloudDriver()
        defer { mounted?.releaseAccess?() }
        do {
            if !apiReady {
                guard let mounted else { return .wrongPassword }
                try await mounted.driver.testConnection()
            }
            // 信封取最新来源:API 注册表(强一致)通常比云端驱动更快
            var keyData: Data?
            if let mounted, !apiReady {
                keyData = try await mounted.driver.downloadKey()
            }
            if let record = await relayRegistryRecord(), let apiEnvelope = record.envelope {
                let apiChanged = DatabaseCipher.envelopeChangedAt(apiEnvelope) ?? .distantPast
                let driverChanged = keyData.flatMap { DatabaseCipher.envelopeChangedAt($0) } ?? .distantPast
                if apiChanged > driverChanged { keyData = apiEnvelope }
            }
            if apiReady, keyData == nil {
                // API 通道无网盘信封可读:直接以注册表信封为源
                if let record = await relayRegistryRecord() { keyData = record.envelope }
            }
            // v2 路径:只需解开远端信封——收敛库身份(云端为准),顺带合并本体
            if let keyData {
                guard let remoteVEK = try? DatabaseCipher.unwrapVaultKey(keyData, password: newPassword) else {
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
                let remoteBody: Data?
                if let apiBinding, let apiToken {
                    remoteBody = try? await relayClient.getBody(token: apiToken, vaultId: apiBinding.vaultId)
                } else {
                    remoteBody = try await mounted?.driver.download()
                }
                if let remoteData = remoteBody,
                   DatabaseCipher.isV2Container(remoteData),
                   let plain = try? DatabaseCipher.decryptBody(remoteData, vaultKey: remoteVEK),
                   let remote = try? PasswordDatabase.parse(plain) {
                    var merged = database
                    merged.merge(with: remote)
                    database = merged
                    try store.save(merged, name: databaseName, vaultKey: remoteVEK)
                    let out = try DatabaseCipher.encryptBody(merged.xmlData(), vaultKey: remoteVEK)
                    if let apiBinding, let apiToken {
                        try await relayClient.putBody(token: apiToken, vaultId: apiBinding.vaultId, cipher: out)
                        await relayReportHashes(cipher: out)
                    } else {
                        try await mounted?.driver.upload(out)
                    }
                    recordSyncBaseline()
                }
                syncRemoteUnreadable = false
                Log.info("sync", "ios adopted new password via envelope (identity converged, body merged)")
                return .success
            }
            // 远端无信封:库已损坏或不完整,无法接管——只能用本地覆盖
            Log.warn("sync", "ios adopt failed: remote has no envelope")
            return .wrongPassword
        } catch {
            Log.warn("sync", "ios adopt remote password failed: \(error)")
            return .wrongPassword
        }
    }

    /// 远端不可解密(旧主密码加密/数据损坏)时的修复:以当前密码重传本地库并重设基线。
    /// 会丢弃云端现有内容,UI 层须先经用户确认。
    func overwriteUnreadableRemote() async {
        let apiBinding = relay.binding(database: databaseName)
        let apiToken = relay.token(database: databaseName)
        let apiReady = apiBinding != nil && apiToken != nil
        let mounted = makeCloudDriver()
        defer { mounted?.releaseAccess?() }
        guard apiReady || mounted != nil, let vaultKey else { return }
        syncState = .syncing
        do {
            let out = try DatabaseCipher.encryptBody(database.xmlData(), vaultKey: vaultKey)
            if let apiBinding, let apiToken {
                try await relayClient.putBody(token: apiToken, vaultId: apiBinding.vaultId, cipher: out)
                await relayReportHashes(cipher: out)
            } else {
                guard let mounted else { return }
                try await mounted.driver.testConnection()
                try await mounted.driver.upload(out)
                if let envelope = store.envelopeData(for: databaseName) {
                    try await mounted.driver.uploadKey(envelope)
                }
            }
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

    /// 列出云端已有的库(设置端"从 iCloud 导入"清单)。
    func listCloudDatabases() async -> [String] {
        guard let mounted = makeCloudDriver() else { return [] }
        defer { mounted.releaseAccess?() }
        do {
            try await mounted.driver.testConnection()
            let names = try await mounted.driver.listDatabases()
            Log.info("sync", "ios cloud list: \(names.count) db(s) [\(names.joined(separator: ","))]")
            return names
        } catch {
            Log.warn("sync", "ios cloud list failed: \(error)")
            return []
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

    /// 到期检查:启用自动同步、同步通道可用(relay API 或网盘)、非同步中才发起;
    /// 有未决冲突时不再发起新同步(冲突弹窗由 RootView 常驻呈现,裁决后恢复)。
    func autoSyncTick() {
        let relayReady = relay.binding(database: databaseName) != nil && relay.token(database: databaseName) != nil
        guard !locked, autoSyncEnabled, relayReady || (cloud.functional && cloud != .none),
              syncState != .syncing else { return }
        // 网盘通道就绪性检查(API 通道无网盘前置);未就绪保持安静,
        // 不刷"到期"日志,配置齐了下一跳自然恢复
        if !relayReady {
            switch cloud {
            case .icloud: guard hasICloudFolder else { return }
            case .webdav: guard !webdav.host.isEmpty else { return }
            default: return
            }
        }
        if pendingSyncConflict != nil { return }
        let interval = TimeInterval(max(autoSyncSeconds, Self.minAutoSyncSeconds))
        if let last = lastSync, Date().timeIntervalSince(last) < interval { return }
        // 失败退避:距上次尝试(无论成败)不足间隔时不重试,
        // 避免云端不可用时每个 5s tick 都重放一遍失败
        if let attempt = lastSyncAttempt, Date().timeIntervalSince(attempt) < interval { return }
        Log.info("sync", "ios auto sync due (interval \(Int(interval))s, cloud=\(cloud.rawValue))")
        Task { await sync(auto: true) }
    }

    // MARK: 同步主流程

    /// sync: — 云驱动 download/冲突判定/merge/upload(WebDAV / iCloud Drive)。
    /// auto = true 为自动同步:静默执行(成功/未配置不打 toast,失败只记日志与状态)。
    func sync(auto: Bool = false) async {
        // 锁屏状态下禁止同步:库已清空、密码已抹,继续走会以空密码加密空库
        // 覆盖云端(真实事故:18:46 锁屏态同步把 122B 空库传上了 iCloud)
        guard !locked else {
            Log.warn("sync", "ios sync skipped: vault locked")
            return
        }
        // API 数据面(relay 绑定的默认通道):库体直连 relay(R2 副本),
        // 网盘仅在"API 尚无副本"时作迁移兜底;未绑定 relay 才走纯网盘路径。
        let apiBinding = relay.binding(database: databaseName)
        let apiToken = relay.token(database: databaseName)
        let apiMode = apiBinding != nil && apiToken != nil
        guard apiMode || cloud != .none else {
            syncState = .idle
            Log.debug("sync", "ios sync skipped: cloud disabled and relay not bound")
            if !auto { showToast(L10n.t("sync_disabled_state")) }
            return
        }
        let mounted = makeCloudDriver()
        let driver = mounted?.driver
        defer { mounted?.releaseAccess?() }
        guard !syncInFlight else {
            Log.debug("sync", "ios sync skipped: already in flight")
            return
        }
        syncInFlight = true
        syncState = .syncing
        lastSyncAttempt = Date()
        defer { syncInFlight = false }
        Log.info("sync", "ios sync \"\(databaseName)\" started (\(apiMode ? "relay-api" : cloud.rawValue)\(auto ? ", auto" : ""))")
        persist()
        do {
            if !apiMode {
                guard let driver else {
                    throw SyncError.notConfigured
                }
                try await driver.testConnection()
            }
            // API 注册表(强一致):信封决胜 + 密码版本高水位 + 内容短路
            var sessionKey = vaultKey
            var driverEnvelopeNeeded = true
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
                        // 云端驱动的信封追平(iCloud/WebDAV 上还是改密前的旧信封;
                        // 仅网盘通道需要——API 通道以注册表为强一致源)
                        if !apiMode, let envelope = store.envelopeData(for: databaseName) {
                            do {
                                try await driver?.uploadKey(envelope)
                            } catch {
                                // 追平失败下轮同步自愈,但原因要留痕
                                Log.warn("sync", "ios driver envelope catch-up upload failed: \(error)")
                            }
                        }
                        driverEnvelopeNeeded = false
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
                // 内容短路:本地明文 XML == 注册表内容 → 本轮零网盘操作
                if let remoteXml = record.xmlSha256,
                   remoteXml == SyncConflict.sha256Hex(database.xmlData()) {
                    lastSync = Date()
                    syncState = .idle
                    Log.info("sync", "ios relay short-circuit: content unchanged — skipping drive round-trip")
                    if !auto { showToast(L10n.t("last_sync_completed_prompt")) }
                    return
                }
            }
            // v2 信封先行(网盘通道;API 通道已在注册表决胜采用,无需网盘信封):
            // 远端有信封 → 本体用库密钥解密;信封解不开 = 对端刚改密 → 弹窗接管
            if driverEnvelopeNeeded, !apiMode, let keyData = try await driver?.downloadKey() {
                if let remoteVEK = try? DatabaseCipher.unwrapVaultKey(keyData, password: password) {
                    sessionKey = remoteVEK
                    joinRemoteVaultIdentity(remoteVEK)
                } else {
                    syncRemoteUnreadable = true
                    syncState = .failed(L10n.t("sync_remote_unreadable_error"))
                    Log.error("sync", "ios sync \"\(databaseName)\": envelope unwrap failed — peer changed password")
                    if !auto { showToast(L10n.t("sync_remote_unreadable_error")) }
                    return
                }
            }
            // 库体拉取:API 通道默认 relay 副本;API 尚无副本(老库首次迁移)
            // 时回退网盘;未绑定 relay 的存量用户直接走网盘。
            let remoteData: Data?
            if apiMode, let apiBinding, let apiToken {
                do {
                    remoteData = try await relayClient.getBody(token: apiToken, vaultId: apiBinding.vaultId)
                } catch RelayClient.RelayError.notFound {
                    remoteData = try await driver?.download()
                    Log.info("sync", "ios relay body absent — migration fallback to drive (\(remoteData != nil ? "found" : "empty"))")
                }
            } else {
                remoteData = try await driver?.download()
            }
            var local = database
            if let remoteData {
                let plain: Data
                do {
                    // iCloud 驱动已保证 v2 魔数;无库密钥说明信封环节已失败
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
                // 双方自基线起均无变化:纯轮询命中,跳过上传。
                // (iCloud 分歧期本端会不断读回自己的旧版本;盲传会把「最后写入者」
                //  反复拉回旧版本,阻碍云端收敛)
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
            if apiMode, let apiBinding, let apiToken {
                // 读-改-写护栏(API):提交前再取一次,窗口内有他机提交先并入
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
                Log.info("sync", "ios sync \"\(databaseName)\" finished via relay api (uploaded \(out.count)B)")
                if !auto { showToast(L10n.t("last_sync_completed_prompt")) }
                return
            }
            // —— 网盘通道(未绑定 relay 的存量路径)——
            guard let driver else {
                syncState = .failed(L10n.t("not_configured_state"))
                Log.error("sync", "ios sync aborted: no cloud driver for drive path")
                return
            }
            // 读-改-写竞态护栏(与 macOS 同款):上传前再取一次远端,版本变了
            // 先合并再传;新远端解不开(对端刚改密)则中止上传走接管流程
            if let fresh = try await driver.download() {
                let seenHash = remoteData.map { SyncConflict.sha256Hex($0) }
                if SyncConflict.sha256Hex(fresh) != seenHash {
                    // 远端在同步窗口内被对端改写:v2 容器用信封阶段确认的库密钥解密
                    let freshPlain = sessionKey.flatMap { try? DatabaseCipher.decryptBody(fresh, vaultKey: $0) }
                    if let freshPlain,
                       let freshRemote = try? PasswordDatabase.parse(freshPlain) {
                        var merged = database
                        merged.merge(with: freshRemote)
                        database = merged
                        persist()
                        Log.warn("sync", "ios remote changed mid-sync — merged fresh remote (\(freshRemote.cards.count) cards) before upload")
                    } else {
                        syncRemoteUnreadable = true
                        syncState = .failed(L10n.t("sync_remote_unreadable_error"))
                        Log.error("sync", "ios remote changed mid-sync and undecryptable — aborting upload, adopt prompt offered")
                        return
                    }
                }
            }
            let driveOut = try DatabaseCipher.encryptBody(database.xmlData(), vaultKey: vaultKey)
            // 上传前把远端当前件留档为 .upw.old(上传失败的恢复点;失败不阻塞上传)
            try? await driver.backupRemoteForUpload()
            try await driver.upload(driveOut)
            // 远端缺信封则补传(首次同步;之后仅改密时传)
            if try await driver.downloadKey() == nil, let envelope = store.envelopeData(for: databaseName) {
                try await driver.uploadKey(envelope)
                Log.info("sync", "ios cloud envelope uploaded (first v2 sync)")
            }
            // 网盘上传成功 → 上报双哈希 + 推库体副本(扩展数据通路;失败下轮自愈)
            await relayReportHashes(cipher: driveOut)
            await relayPushBody(cipher: driveOut)
            recordSyncBaseline()
            syncRemoteUnreadable = false
            syncState = .idle
            Log.info("sync", "ios sync \"\(databaseName)\" finished (uploaded \(driveOut.count)B)")
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
            let out = try DatabaseCipher.encryptBody(database.xmlData(), vaultKey: vaultKey)
            // API 通道:裁决结果提交到 relay;存量网盘用户走网盘
            if let binding = relay.binding(database: databaseName),
               let token = relay.token(database: databaseName) {
                try await relayClient.putBody(token: token, vaultId: binding.vaultId, cipher: out)
                await relayReportHashes(cipher: out)
            } else {
                guard let mounted = makeCloudDriver() else {
                    syncState = .idle
                    Log.warn("sync", "ios conflict resolution \"\(databaseName)\" aborted: no sync channel")
                    return
                }
                defer { mounted.releaseAccess?() }
                try await mounted.driver.upload(out)
            }
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
