import Foundation

import UPasswordsCore
import UPasswordsPersistence

// MARK: - iOS 云同步:驱动构造/手动与自动同步/冲突裁决(与 macOS 同一套判定语义)
//
// 复用 Persistence 的 CloudDriver(WebDAV / iCloud Drive)、SyncConflict 基线判定与
// PasswordDatabase.merge 收敛合并;密文经主密码加解密,基线哈希存共享 defaults。

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

    // MARK: iCloud 云端文件夹(iOS 沙盒经安全作用域书签访问云盘)

    /// 已保存 iCloud 云盘文件夹书签(设置页据此显示入口状态)。
    var hasICloudFolder: Bool { d.data(forKey: "sync.icloud.bookmark") != nil }

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
        d.set(bookmark, forKey: "sync.icloud.bookmark")
        d.set(picked.lastPathComponent, forKey: "sync.icloud.name")
        icloudFolderName = picked.lastPathComponent

        // 探测所选目录内容:决定容器模式(云盘根 → 容器取其下 UPasswords/)
        let driver = ICloudDriver(databaseName: databaseName, iCloudFolder: picked)
        let names = (try? await driver.listDatabases()) ?? []
        let isContainer = picked.lastPathComponent == "UPasswords" || !names.isEmpty
        d.set(isContainer ? "explicit" : "root", forKey: "sync.icloud.mode")
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
        d.set(bookmark, forKey: "sync.icloud.bookmark")
        d.set(folder.lastPathComponent, forKey: "sync.icloud.name")
        // 导入的 .upw 直接躺在该文件夹里 → 该文件夹即同步容器
        d.set("explicit", forKey: "sync.icloud.mode")
        icloudFolderName = folder.lastPathComponent
        cloudTypeRaw = CloudType.icloud.rawValue
        Log.info("sync", "ios import: adopted icloud folder \"\(folder.lastPathComponent)\", sync enabled")
    }

    /// 解析书签并取得安全作用域访问权;调用方必须在用完后调用返回的
    /// release 闭包(stopAccessingSecurityScopedResource)。
    private func resolveICloudFolder() -> (folder: URL, release: () -> Void)? {
        guard let data = d.data(forKey: "sync.icloud.bookmark") else {
            Log.info("sync", "ios icloud folder not picked yet — pick it in settings first")
            return nil
        }
        var stale = false
        guard let folder = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            Log.warn("sync", "ios icloud bookmark resolve failed — cleared, re-pick folder in settings")
            // 无效书签(如无作用域造出的半成品)会造成永久“未配置”,清掉回到未选定状态
            d.removeObject(forKey: "sync.icloud.bookmark")
            d.removeObject(forKey: "sync.icloud.name")
            icloudFolderName = ""
            return nil
        }
        guard folder.startAccessingSecurityScopedResource() else {
            Log.warn("sync", "ios icloud security scope denied for \"\(folder.lastPathComponent)\"")
            return nil
        }
        if stale, let refreshed = try? folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            // 书签过期(系统刷新路径):尽力续期,失败不影响本次同步
            d.set(refreshed, forKey: "sync.icloud.bookmark")
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
            if d.string(forKey: "sync.icloud.mode") == "root" {
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

    /// 主密码变更后的云端接力:远端容器仍是旧密码加密,用旧密码解密合并后
    /// 以新密码重传并重设基线;失败仅记日志,下次同步走「远端不可解密」修复路径。
    func reencryptCloudAfterPasswordChange(old: String) async {
        guard let mounted = makeCloudDriver() else { return }
        defer { mounted.releaseAccess?() }
        do {
            try await mounted.driver.testConnection()
            if let remoteData = try await mounted.driver.download(),
               let plain = try? DatabaseCipher.decryptedData(remoteData, password: old),
               let remote = try? PasswordDatabase.parse(plain) {
                var local = database
                local.merge(with: remote)
                database = local
                persist()
                Log.info("sync", "ios cloud handoff: merged remote (\(remote.cards.count) cards) after password change")
            }
            let out = try DatabaseCipher.encryptedData(database.xmlData(), password: password)
            try await mounted.driver.upload(out)
            recordSyncBaseline(uploaded: out)
            syncRemoteUnreadable = false
            Log.info("sync", "ios cloud handoff: remote re-encrypted with new password (\(out.count)B)")
        } catch {
            Log.warn("sync", "ios cloud handoff after password change failed: \(error)")
        }
    }

    /// 接管远端的结果:成功 / 密码不对 / 远端是「锁屏同步空库覆盖」残骸
    /// (空密码加密,任何真实密码都解不开,只能用本地覆盖恢复)。
    enum AdoptResult {
        case success, wrongPassword, emptyClobber
    }

    /// 远端用「其他设备改后的新主密码」加密时的接管流程:
    /// 输入新密码 → 解密远端并合并进本地 → 本地以新密码重加密落盘并更新钥匙串
    /// → 上传合并结果。
    @discardableResult
    func adoptRemotePassword(_ newPassword: String) async -> AdoptResult {
        guard let mounted = makeCloudDriver() else { return .wrongPassword }
        defer { mounted.releaseAccess?() }
        do {
            try await mounted.driver.testConnection()
            guard let remoteData = try await mounted.driver.download() else {
                return .wrongPassword
            }
            guard let plain = try? DatabaseCipher.decryptedData(remoteData, password: newPassword),
                  let remote = try? PasswordDatabase.parse(plain) else {
                // 已知事故形态自检:锁屏态同步曾以空密码上传空库覆盖云端
                if let emptyPlain = try? DatabaseCipher.decryptedData(remoteData, password: ""),
                   let empty = try? PasswordDatabase.parse(emptyPlain), empty.cards.isEmpty {
                    Log.error("sync", "ios remote is the empty-vault clobber (locked-sync artifact) — user must overwrite with local")
                    return .emptyClobber
                }
                Log.warn("sync", "ios adopt remote password failed: cannot decrypt with given password")
                return .wrongPassword
            }
            var merged = database
            merged.merge(with: remote)
            database = merged
            try store.save(merged, name: databaseName, password: newPassword)
            password = newPassword
            PasswordStore.savePassword(newPassword, databaseName: databaseName)
            if PasswordStore.hasBiometricItem(databaseName: databaseName) {
                PasswordStore.savePasswordForBiometric(newPassword, databaseName: databaseName)
            }
            let out = try DatabaseCipher.encryptedData(merged.xmlData(), password: newPassword)
            try await mounted.driver.upload(out)
            recordSyncBaseline(uploaded: out)
            syncRemoteUnreadable = false
            Log.info("sync", "ios adopted remote password: merged \(remote.cards.count) remote cards, re-encrypted local+cloud")
            return .success
        } catch {
            Log.warn("sync", "ios adopt remote password failed: \(error)")
            return .wrongPassword
        }
    }

    /// 远端不可解密(旧主密码加密/数据损坏)时的修复:以当前密码重传本地库并重设基线。
    /// 会丢弃云端现有内容,UI 层须先经用户确认。
    func overwriteUnreadableRemote() async {
        guard let mounted = makeCloudDriver() else { return }
        defer { mounted.releaseAccess?() }
        syncState = .syncing
        do {
            try await mounted.driver.testConnection()
            let out = try DatabaseCipher.encryptedData(database.xmlData(), password: password)
            try await mounted.driver.upload(out)
            recordSyncBaseline(uploaded: out)
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

    /// 上次成功同步的基线哈希键(按数据库分开):本地明文 XML 与远端容器字节。
    private var baselineLocalXMLKey: String { "sync.baseline.local.\(databaseName)" }
    private var baselineRemoteDataKey: String { "sync.baseline.remote.\(databaseName)" }

    /// 记录本次成功同步的基线哈希与完成时间,供下次同步做冲突判定。
    private func recordSyncBaseline(uploaded: Data) {
        d.set(SyncConflict.sha256Hex(database.xmlData()), forKey: baselineLocalXMLKey)
        d.set(SyncConflict.sha256Hex(uploaded), forKey: baselineRemoteDataKey)
        d.set(Date().timeIntervalSince1970, forKey: "sync.last.\(databaseName)")
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

    /// 到期检查:启用自动同步、云端可用、非同步中才发起;有未决冲突时不再发起新同步
    /// (冲突弹窗由 RootView 常驻呈现,裁决后恢复)。
    func autoSyncTick() {
        guard !locked, autoSyncEnabled, cloud.functional, cloud != .none,
              syncState != .syncing else { return }
        // 云端未就绪(iCloud 未选文件夹 / WebDAV 未填主机)时保持安静:
        // 不刷"到期"日志,也不进同步流程,配置齐了下一跳自然恢复
        switch cloud {
        case .icloud: guard hasICloudFolder else { return }
        case .webdav: guard !webdav.host.isEmpty else { return }
        default: return
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
        guard cloud != .none else {
            syncState = .idle
            Log.debug("sync", "ios sync skipped: cloud disabled")
            if !auto { showToast(L10n.t("sync_disabled_state")) }
            return
        }
        guard let mounted = makeCloudDriver() else {
            Log.debug("sync", "ios sync skipped: cloud=\(cloud.rawValue) not configured")
            if !auto { showToast(L10n.t("not_configured_state")) }
            return
        }
        let driver = mounted.driver
        defer { mounted.releaseAccess?() }
        guard !syncInFlight else {
            Log.debug("sync", "ios sync skipped: already in flight")
            return
        }
        syncInFlight = true
        syncState = .syncing
        lastSyncAttempt = Date()
        defer { syncInFlight = false }
        Log.info("sync", "ios sync \"\(databaseName)\" started (\(cloud.rawValue)\(auto ? ", auto" : ""))")
        persist()
        do {
            try await driver.testConnection()
            let remoteData = try await driver.download()
            var local = database
            if let remoteData {
                let plain: Data
                do {
                    plain = try DatabaseCipher.decryptedData(remoteData, password: password)
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
                let remoteHash = SyncConflict.sha256Hex(remoteData)
                let verdict = SyncConflict.evaluate(
                    localXMLHash: localHash,
                    remoteDataHash: remoteHash,
                    baselines: SyncConflict.Baselines(
                        localXMLHash: d.string(forKey: baselineLocalXMLKey),
                        remoteDataHash: d.string(forKey: baselineRemoteDataKey)))
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
                if localHash == d.string(forKey: baselineLocalXMLKey),
                   remoteHash == d.string(forKey: baselineRemoteDataKey) {
                    lastSync = Date()
                    syncState = .idle
                    Log.info("sync", "ios no changes since baseline — skipping upload")
                    return
                }
                Log.info("sync", "ios no conflict — merging")
                local.merge(with: remote)
                database = local
                persist()
            } else {
                Log.info("sync", "ios no remote database yet — uploading local")
            }
            // 读-改-写竞态护栏(与 macOS 同款):上传前再取一次远端,版本变了
            // 先合并再传;新远端解不开(对端刚改密)则中止上传走接管流程
            if let fresh = try await driver.download() {
                let seenHash = remoteData.map { SyncConflict.sha256Hex($0) }
                if SyncConflict.sha256Hex(fresh) != seenHash {
                    if let freshPlain = try? DatabaseCipher.decryptedData(fresh, password: password),
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
            let out = try DatabaseCipher.encryptedData(database.xmlData(), password: password)
            try await driver.upload(out)
            recordSyncBaseline(uploaded: out)
            syncRemoteUnreadable = false
            syncState = .idle
            Log.info("sync", "ios sync \"\(databaseName)\" finished (uploaded \(out.count)B)")
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
        guard let mounted = makeCloudDriver() else {
            syncState = .idle
            Log.warn("sync", "ios conflict resolution \"\(databaseName)\" aborted: cloud not configured")
            return
        }
        let driver = mounted.driver
        defer { mounted.releaseAccess?() }
        Log.info("sync", "ios conflict resolution \"\(databaseName)\": overwrite \(useLocal ? "remote with local" : "local with remote")")
        syncState = .syncing
        do {
            if !useLocal {
                // 用云端覆盖本地:整库替换为远端版本并落盘
                let plain = try DatabaseCipher.decryptedData(conflict.remoteData, password: password)
                let remote = try PasswordDatabase.parse(plain)
                database = remote
                persist()
                Log.info("sync", "ios local replaced by remote (\(remote.cards.count) cards, \(remote.labels.count) labels)")
            }
            let out = try DatabaseCipher.encryptedData(database.xmlData(), password: password)
            try await driver.upload(out)
            recordSyncBaseline(uploaded: out)
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
