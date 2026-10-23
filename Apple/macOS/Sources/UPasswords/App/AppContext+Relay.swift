import Foundation
import CryptoKit
import UPasswordsCore
import UPasswordsPersistence

/// UPasswords 云同步(api.upasswords.com)接线:登录/绑定/解绑、
/// 解锁前的密码版本检查、同步时的信封通道与哈希上报(见 Cloud/DESIGN.md)。
/// 账户层只做授权——令牌入钥匙串,绑定与版本高水位入标准 defaults。
extension AppContext {

    static let relayStore = RelayStore(defaults: .standard)
    static let relayClient = RelayClient()

    var relay: RelayStore { Self.relayStore }
    var relayClient: RelayClient { Self.relayClient }

    /// 当前库是否已绑定云同步(注册表有记录)。
    var relayBound: Bool { relay.binding(database: databaseName) != nil }

    /// 设置页展示:当前库绑定账户的邮箱。
    var relayAccountEmail: String? { relay.accountEmail(database: databaseName) }

    /// 新装引导是否需要先走账户登录:无本地库 + 设备从未登录。
    /// 邮箱验证为必经步骤(注册/验证在打开软件时最先完成),不设跳过出口。
    var relayOnboardingNeeded: Bool {
        phase == .setup && store.list().isEmpty && relay.lastAccountEmail == nil
    }

    // MARK: - 登录与启用

    /// 登录成功后的会话收尾:先自撤销本机旧令牌的会话(同一设备反复登录
    /// 不再堆积多条同名会话),再保存新会话。撤销失败只留痕不阻塞——
    /// 服务端旧会话 90 天自然过期。
    private func relayAdoptSession(_ session: RelayClient.Session, email: String) async {
        if let oldToken = relay.token(email: email), oldToken != session.token {
            do {
                try await relayClient.revokeOwnSession(token: oldToken)
                Log.info("sync", "relay stale session self-revoked (email length \(email.count))")
            } catch {
                Log.debug("sync", "relay stale session revoke failed (ignored): \(error)")
            }
        }
        relay.storeSession(token: session.token, email: email)
    }

    /// 发送登录验证码(设置页「发送验证码」)。
    /// - Returns: 重发冷却秒数(成功=60;429=服务端 Retry-After;其他失败=0 不倒计时)
    @discardableResult
    func relaySendCode(email: String) async -> Int {
        do {
            try await relayClient.requestCode(email: email, lang: L10n.effectiveLanguage)
            Log.info("sync", "relay code requested (email length \(email.count))")
            AppToast.shared.show(L10n.t("relay_code_sent_toast"))
            return 60
        } catch RelayClient.RelayError.rateLimited(let wait) {
            Log.warn("sync", "relay code rate limited (retry after \(wait)s)")
            AppToast.shared.show(RelayClient.RelayError.rateLimited(retryAfter: wait).localizedDescription)
            return max(wait, 1)
        } catch {
            Log.warn("sync", "relay code request failed: \(error)")
            AppToast.shared.show(error.localizedDescription)
            return 0
        }
    }

    /// 一步完成「登录 + 为当前库启用云同步」:
    /// 验证码登录 → 登记当前库 → 上报本地信封 → 记录版本基准 → 立即同步一轮。
    func relayLoginAndEnable(email: String, code: String) async {
        do {
            // 护栏:一个本地库同时只归属一个账户;换账户须先解绑,
            // 防止把 A 账户的数据同步进 B 账户的库
            if let binding = relay.binding(database: databaseName), binding.email != email {
                Log.warn("sync", "relay enable rejected: \"\(databaseName)\" bound to another account")
                AppToast.shared.show(L10n.t("relay_already_bound_hint"))
                return
            }
            let device = Host.current().localizedName ?? "Mac"
            let session = try await relayClient.verify(email: email, code: code,
                                                       deviceName: device, platform: .macos)
            await relayAdoptSession(session, email: email)
            Log.info("sync", "relay login ok userId=\(session.userId.prefix(8))… expires=\(session.expiresAt)")
            try await relayEnableForCurrentVault(token: session.token, email: email)
        } catch {
            Log.warn("sync", "relay login/enable failed: \(error)")
            AppToast.shared.show(error.localizedDescription)
        }
    }

    /// 登记当前库并绑定(登录后自动调用;也可为已登录账户的其他库单独启用)。
    /// 创建即携带初始信封;绑定即全量上行由随后的一轮 sync 完成
    /// (快照基线为空 → 全部条目进脏集合),失败不回滚——下轮自愈。
    private func relayEnableForCurrentVault(token: String, email: String) async throws {
        guard phase == .unlocked else {
            throw SyncError.notConfigured
        }
        guard let envelope = store.envelopeData(for: databaseName) else {
            throw DatabaseCipher.CipherError(message: L10n.t("envelope_missing_error"))
        }
        // 其他设备可能已登记过同名库(先绑定的一侧):认领现有登记而非撞 409
        let registered = try await relayClient.listVaults(token: token)
            .first { $0.name == databaseName }
        let vaultId: String
        if let registered {
            vaultId = registered.vaultId
            // 认领须验密:本地主密码必须能解开该库信封且与会话库密钥一致。
            // 不验密的认领会让两端在同一座库里各持各的 VEK——互相拉不开
            // 对方条目还被静默丢弃/撞冲突,"都在同步却互不相通"且无任何报错
            // (真实事故)。验不开不静默绑定:亮出接管/覆盖修复入口收敛。
            if let detail = try? await relayClient.getVault(token: token, vaultId: vaultId),
               let remoteEnvelope = detail.envelope {
                let claimedVek = try? DatabaseCipher.unwrapVaultKey(remoteEnvelope, password: password)
                if claimedVek != vaultKey {
                    Log.warn("sync", "relay claim \(databaseName): master password mismatch with vault envelope — takeover required")
                    relay.setBinding(RelayBinding(email: email, vaultId: vaultId, vaultName: databaseName),
                                     database: databaseName)
                    relay.recordPasswordVersion(registered.passwordVersion, database: databaseName)
                    relayStateChanged()
                    syncRemoteUnreadable = true
                    promptAdoptRemotePassword()
                    AppToast.shared.show(L10n.t("relay_claim_password_mismatch"))
                    return
                }
            }
            // 无信封(极旧库)或详情拉取失败(网络抖动):无从校验,按原行为
            // 认领,下轮同步自愈
        } else {
            vaultId = try await relayClient.createVault(token: token, name: databaseName, envelope: envelope)
        }
        relay.setBinding(RelayBinding(email: email, vaultId: vaultId, vaultName: databaseName),
                         database: databaseName)
        // 绑定即记录版本基准(认领旧登记用其现值),避免下一轮被误判为"密码已被他机修改"
        relay.recordPasswordVersion(registered?.passwordVersion ?? 1, database: databaseName)
        relayStateChanged()
        AppToast.shared.show(L10n.t("relay_login_ok_toast"))
        Log.info("sync", "relay enabled for \"\(databaseName)\" vault=\(vaultId.prefix(8))…")
        // 绑定即全量上行:重置行同步状态(快照基线清空 → 全部条目视为脏)
        resetRowSyncForFreshBinding()
        Task { await sync(auto: true) }
    }

    /// 登出:先在服务端吊销本机会话(令牌即刻作废),再清本机令牌与当前库绑定
    /// (账户与网盘文件不动)。服务端撤销失败仍继续本地登出——令牌已在本地销毁。
    func relayLogout() async {
        if let token = relay.token(database: databaseName) {
            do {
                try await relayClient.revokeOwnSession(token: token)
                Log.info("sync", "relay logout: session self-revoked")
            } catch {
                Log.warn("sync", "relay logout: session revoke failed (continuing): \(error)")
            }
        }
        relay.logout(database: databaseName)
        relayStateChanged()
        AppToast.shared.show(L10n.t("relay_logout_ok_toast"))
    }

    // MARK: - 新装引导(登录先于建库/恢复)

    /// 引导第一步的仅登录(此刻尚无库可绑定):验证码登录 → 记住账户;
    /// 库创建/恢复完成后由 relayBindCurrentVaultIfNeeded 自动补绑。
    func relayLoginOnly(email: String, code: String) async -> Bool {
        do {
            let device = Host.current().localizedName ?? "Mac"
            let session = try await relayClient.verify(email: email, code: code,
                                                       deviceName: device, platform: .macos)
            await relayAdoptSession(session, email: email)
            relayStateChanged()
            Log.info("sync", "relay login (onboarding) ok userId=\(session.userId.prefix(8))…")
            return true
        } catch {
            Log.warn("sync", "relay login (onboarding) failed: \(error)")
            AppToast.shared.show(error.localizedDescription)
            return false
        }
    }

    /// 库就绪但尚未绑定云同步时自动补绑(引导登录在先的场景):
    /// 登记或认领当前库 → 上报信封 → 记录版本基准。幂等;
    /// 曾绑定过的库不自动回绑(尊重用户主动解绑)。
    func relayBindCurrentVaultIfNeeded() async {
        guard phase == .unlocked,
              relay.binding(database: databaseName) == nil,
              !relay.everBound(database: databaseName),
              let email = relay.lastAccountEmail,
              let token = relay.token(email: email) else { return }
        do {
            try await relayEnableForCurrentVault(token: token, email: email)
            Log.info("sync", "relay auto-bound \"\(databaseName)\" after onboarding login")
        } catch {
            Log.warn("sync", "relay auto-bind \"\(databaseName)\" failed: \(error)")
        }
    }

    /// 引导「在线恢复」的账户库清单:已登录(引导登录在先)时从注册表
    /// 预列库名,免先配网盘即可看到名下有哪些库。未登录或拉取失败返回
    /// nil,表单回落纯网盘路径(既有行为不变)。
    func relayVaultsForRestore() async -> [RelayClient.VaultRecord]? {
        guard let email = relay.lastAccountEmail,
              let token = relay.token(email: email) else { return nil }
        do {
            let records = try await relayClient.listVaults(token: token)
            Log.info("sync", "relay restore list: \(records.count) vault(s) fetched")
            return records
        } catch {
            Log.warn("sync", "relay restore list failed: \(error)")
            return nil
        }
    }

    // MARK: - 同步编排的数据通道(供 AppContext+Sync 调用)

    /// 拉取注册表(未绑定/网络失败返回 nil,同步走纯网盘路径)。
    func relayRegistryRecord() async -> RelayClient.VaultRecord? {
        guard let binding = relay.binding(database: databaseName),
              let token = relay.token(database: databaseName) else { return nil }
        do {
            let record = try await relayClient.getVault(token: token, vaultId: binding.vaultId)
            relay.recordPasswordVersion(record.passwordVersion, database: databaseName)
            return record
        } catch RelayClient.RelayError.unauthorized {
            handleSessionExpired()
            return nil
        } catch {
            Log.warn("sync", "relay registry fetch failed: \(error)")
            return nil
        }
    }

    /// 网盘上传成功后上报双哈希(密文=网盘文件身份;明文 XML=下轮同步短路判据)。
    /// 解锁后刷新本会话设备名(管理设备页显示型号;历史通用名自愈)。
    func relayRenameCurrentSession() async {
        guard let token = relay.token(database: databaseName) else { return }
        let device = Host.current().localizedName ?? "Mac"
        do {
            try await relayClient.renameSession(token: token, deviceName: device)
        } catch {
            // 自愈性改名,失败不影响功能;留痕即可
            Log.debug("sync", "relay session rename failed: \(error)")
        }
    }

    // MARK: - 设备会话管理

    /// 本账户已登录设备列表(设置页「管理设备」)。
    func relaySessions() async -> [RelayClient.DeviceSession] {
        guard relay.binding(database: databaseName) != nil,
              let token = relay.token(database: databaseName) else { return [] }
        do {
            let sessions = try await relayClient.listSessions(token: token)
            Log.info("sync", "relay sessions listed: \(sessions.count) device(s)")
            return sessions
        } catch {
            Log.warn("sync", "relay sessions list failed: \(error)")
            AppToast.shared.show(error.localizedDescription)
            return []
        }
    }

    /// 撤销指定设备会话(被撤销的设备下次请求会收到 401,引导重新登录)。
    func relayRevokeSession(id: String) async {
        guard relay.binding(database: databaseName) != nil,
              let token = relay.token(database: databaseName) else { return }
        do {
            try await relayClient.revokeSession(token: token, id: id)
            Log.info("sync", "relay session revoked id=\(id.prefix(8))…")
        } catch {
            Log.warn("sync", "relay session revoke failed: \(error)")
            AppToast.shared.show(error.localizedDescription)
        }
    }

    // MARK: - 敏感操作(解绑/注销,需当次 sensitive 验证码)

    /// 请求发送敏感操作验证码到绑定邮箱。
    func relayRequestSensitiveCode() async {
        guard let email = relayAccountEmail else { return }
        await relaySendSensitiveCode(to: email)
    }

    /// 向指定邮箱发送敏感操作验证码(换绑邮箱:码发往**新**邮箱)。
    func relaySendSensitiveCode(to email: String) async {
        do {
            try await relayClient.requestCode(email: email, purpose: .sensitive, lang: L10n.effectiveLanguage)
            Log.info("sync", "relay sensitive code sent (email length \(email.count))")
            AppToast.shared.show(L10n.t("relay_sensitive_code_sent"))
        } catch {
            Log.warn("sync", "relay sensitive code request failed: \(error)")
            AppToast.shared.show(error.localizedDescription)
        }
    }

    /// 解绑当前库:删除注册表记录(不动网盘文件与本地数据)。
    func relayUnbindVault(code: String) async {
        guard let binding = relay.binding(database: databaseName),
              let token = relay.token(database: databaseName) else { return }
        do {
            try await relayClient.deleteVault(token: token, vaultId: binding.vaultId, code: code)
            relay.setBinding(nil, database: databaseName)
            relayStateChanged()
            Log.info("sync", "relay vault unbound \"\(databaseName)\"")
            AppToast.shared.show(L10n.t("relay_unbind_ok_toast"))
        } catch {
            Log.warn("sync", "relay unbind failed: \(error)")
            AppToast.shared.show(error.localizedDescription)
        }
    }

    /// 注销账户:服务端立即清敏感数据并吊销全部会话;本地清绑定。
    func relayDeregisterAccount(code: String) async {
        guard let binding = relay.binding(database: databaseName),
              let token = relay.token(database: databaseName) else { return }
        do {
            try await relayClient.deregister(token: token, code: code)
            relay.setBinding(nil, database: databaseName)
            relayStateChanged()
            Log.warn("sync", "relay account deregistered (email length \(binding.email.count))")
            AppToast.shared.show(L10n.t("relay_deregister_ok_toast"))
        } catch {
            Log.warn("sync", "relay deregister failed: \(error)")
            AppToast.shared.show(error.localizedDescription)
        }
    }

    // MARK: - 换绑邮箱(注册表转移)

    /// 换绑邮箱:本地先验当前主密码(唯一信任根) → 服务端把注册表记录迁移到
    /// 新邮箱名下(云端同步结构随之换主,vaultId/信封/哈希不变) →
    /// 保存新账户会话并更新绑定邮箱。
    func relayTransferVault(masterPassword: String, newEmail: String, code: String,
                                 currentCode: String) async -> Bool {
        guard let binding = relay.binding(database: databaseName),
              let token = relay.token(database: databaseName) else { return false }
        do {
            _ = try store.load(name: databaseName, password: masterPassword)
        } catch {
            Log.warn("sync", "relay transfer rejected: wrong master password")
            AppToast.shared.show(L10n.t("wrong_password_error"))
            return false
        }
        do {
            let device = Host.current().localizedName ?? "Mac"
            let session = try await relayClient.transferVault(
                token: token, vaultId: binding.vaultId, email: newEmail, code: code,
                currentCode: currentCode, deviceName: device, platform: .macos)
            await relayAdoptSession(session, email: newEmail)
            relay.setBinding(
                RelayBinding(email: newEmail, vaultId: binding.vaultId, vaultName: binding.vaultName),
                database: databaseName)
            relayStateChanged()
            Log.info("sync", "relay vault transferred to new email (vault=\(binding.vaultId.prefix(8))…)")
            AppToast.shared.show(L10n.t("relay_transfer_ok_toast"))
            return true
        } catch {
            Log.warn("sync", "relay transfer failed: \(error)")
            AppToast.shared.show(error.localizedDescription)
            return false
        }
    }

    // MARK: - 本地库改名后的云端迁移

    /// 本地库改名后迁移云端身份:本地绑定换键 + 注册表改名(vaultId 不变)。
    /// 失败仅记日志:注册表名不影响 vaultId 寻址,下轮同步自愈。
    func relayMigrateAfterRename(from oldName: String, to newName: String) async {
        guard let binding = relay.binding(database: oldName),
              let token = relay.token(database: oldName) else { return }
        relay.migrateBinding(from: oldName, to: newName)
        do {
            try await relayClient.renameVault(token: token, vaultId: binding.vaultId, name: newName)
        } catch {
            Log.warn("sync", "relay registry rename failed: \(error)")
        }
    }

    // MARK: - 解锁版本检查(信封先行)

    /// 会话失效(401):令牌过期/被其他设备撤销/账户已注销。此时绑定已是
    /// 本地残影(服务端可能连库都不存在了)——原地登出并提示重新登录,
    /// 否则客户端会永远拿着死令牌静默失败,用户以为还登录着。
    func handleSessionExpired() {
        guard relay.binding(database: databaseName) != nil else { return }
        Log.warn("sync", "relay session expired/revoked — clearing binding, re-login required")
        relay.logout(database: databaseName)
        syncState = .disabled
        relayStateChanged()
        AppToast.shared.show(L10n.t("relay_session_expired_toast"))
    }

    /// 解锁后异步检查注册表密码版本:版本前进且会话密码解不开远端新信封 →
    /// 他机改密,本机强制锁定，待新密码验证后重建并提交配套文件
    /// (本机即改密端时会话密码可解新信封,仅追平本地副本,不锁)。
    func checkRelayPasswordVersion() async {
        guard phase == .unlocked, let key = vaultKey,
              let binding = relay.binding(database: databaseName),
              let token = relay.token(database: databaseName) else { return }
        let name = databaseName
        let sessionID = syncSessionID
        let record: RelayClient.VaultRecord?
        do {
            record = try await relayClient.getVault(token: token, vaultId: binding.vaultId)
        } catch RelayClient.RelayError.unauthorized {
            guard syncSessionID == sessionID, databaseName == name else { return }
            handleSessionExpired()
            return
        } catch {
            // 改密检测入口:网络失败留痕,否则「他机改密为何没触发锁定」无从排查
            Log.debug("sync", "relay password-version check fetch failed (network/offline)")
            return
        }
        guard let record, phase == .unlocked, syncSessionID == sessionID,
              databaseName == name, vaultKey == key, !Task.isCancelled else { return }
        let known = relay.knownPasswordVersion(database: name) ?? record.passwordVersion
        guard record.passwordVersion > known else {
            relay.recordPasswordVersion(record.passwordVersion, database: name)
            return
        }
        guard let envelope = record.envelope else {
            Log.error("sync", "password-version check has no remote envelope")
            return
        }
        Log.info("sync", "relay password version advanced \(known) → \(record.passwordVersion)")
        if (try? DatabaseCipher.unwrapVaultKey(envelope, password: password)) == key {
            do {
                try commitSyncSnapshot(database, name: name, vaultKey: key,
                                       state: rowSync, envelope: envelope)
                relay.recordPasswordVersion(record.passwordVersion, database: name)
            } catch {
                Log.error("sync", "password-version adoption failed: \(error)")
            }
            return
        }
        forceLockForRemotePasswordChange(envelope)
    }

    /// 他机改密后保存配套的本地快照并锁定;远端新信封只能随新钥库体一起提交。
    /// - Parameter envelope: 用于确认远端改密的有效信封，不替换本地旧钥信封。
    func forceLockForRemotePasswordChange(_ envelope: Data) {
        guard let vaultKey, DatabaseCipher.envelopeChangedAt(envelope) != nil else { return }
        do {
            try commitSyncSnapshot(database, name: databaseName, vaultKey: vaultKey, state: rowSync)
        } catch {
            Log.error("sync", "force-lock local snapshot commit failed: \(error)")
            syncRemoteUnreadable = true
            return
        }
        PasswordStore.removePassword(databaseName: databaseName)
        Log.warn("sync", "remote password change — force locking \"\(databaseName)\" for new password")
        lock()
        AppToast.shared.show(L10n.t("relay_force_lock_message"))
    }
}
