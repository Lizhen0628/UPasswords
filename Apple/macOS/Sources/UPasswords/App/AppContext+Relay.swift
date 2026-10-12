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

    /// 发送登录验证码(设置页「发送验证码」)。
    func relaySendCode(email: String) async {
        do {
            try await relayClient.requestCode(email: email)
            Log.info("sync", "relay code requested (email length \(email.count))")
            AppToast.shared.show(L10n.t("relay_code_sent_toast"))
        } catch {
            Log.warn("sync", "relay code request failed: \(error)")
            AppToast.shared.show(error.localizedDescription)
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
            let session = try await relayClient.verify(email: email, code: code, deviceName: device)
            relay.storeSession(token: session.token, email: email)
            Log.info("sync", "relay login ok userId=\(session.userId.prefix(8))… expires=\(session.expiresAt)")
            try await relayEnableForCurrentVault(token: session.token, email: email)
        } catch {
            Log.warn("sync", "relay login/enable failed: \(error)")
            AppToast.shared.show(error.localizedDescription)
        }
    }

    /// 登记当前库并上报信封(登录后自动调用;也可为已登录账户的其他库单独启用)。
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
        } else {
            vaultId = try await relayClient.createVault(token: token, name: databaseName)
        }
        relay.setBinding(RelayBinding(email: email, vaultId: vaultId, vaultName: databaseName),
                         database: databaseName)
        let changedAt = DatabaseCipher.envelopeChangedAt(envelope) ?? Date()
        _ = try await relayClient.putEnvelope(token: token, vaultId: vaultId,
                                              envelope: envelope, changedAt: changedAt)
        // 绑定即记录版本基准(认领旧登记用其现值),避免下一轮被误判为"密码已被他机修改"
        relay.recordPasswordVersion(registered?.passwordVersion ?? 1, database: databaseName)
        AppToast.shared.show(L10n.t("relay_login_ok_toast"))
        Log.info("sync", "relay enabled for \"\(databaseName)\" vault=\(vaultId.prefix(8))…")
        if settings.cloud != .none {
            Task { await sync() }
        }
    }

    /// 登出:清本机令牌与当前库绑定(账户与网盘文件不动)。
    func relayLogout() async {
        relay.logout(database: databaseName)
        AppToast.shared.show(L10n.t("relay_logout_ok_toast"))
    }

    // MARK: - 新装引导(登录先于建库/恢复)

    /// 引导第一步的仅登录(此刻尚无库可绑定):验证码登录 → 记住账户;
    /// 库创建/恢复完成后由 relayBindCurrentVaultIfNeeded 自动补绑。
    func relayLoginOnly(email: String, code: String) async -> Bool {
        do {
            let device = Host.current().localizedName ?? "Mac"
            let session = try await relayClient.verify(email: email, code: code, deviceName: device)
            relay.storeSession(token: session.token, email: email)
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

    // MARK: - 同步编排的数据通道(供 AppContext+Sync 调用)

    /// 拉取注册表(未绑定/网络失败返回 nil,同步走纯网盘路径)。
    func relayRegistryRecord() async -> RelayClient.VaultRecord? {
        guard let binding = relay.binding(database: databaseName),
              let token = relay.token(database: databaseName) else { return nil }
        do {
            let record = try await relayClient.getVault(token: token, vaultId: binding.vaultId)
            relay.recordPasswordVersion(record.passwordVersion, database: databaseName)
            return record
        } catch {
            Log.warn("sync", "relay registry fetch failed: \(error)")
            return nil
        }
    }

    /// 推送本地信封到注册表(改密/自愈;失败仅记日志,网盘副本仍在)。
    func relayPushEnvelope() async {
        guard let binding = relay.binding(database: databaseName),
              let token = relay.token(database: databaseName),
              let envelope = store.envelopeData(for: databaseName) else { return }
        let changedAt = DatabaseCipher.envelopeChangedAt(envelope) ?? Date()
        do {
            let outcome = try await relayClient.putEnvelope(
                token: token, vaultId: binding.vaultId, envelope: envelope, changedAt: changedAt)
            if case .accepted(let version, _) = outcome {
                relay.recordPasswordVersion(version, database: databaseName)
            }
            Log.info("sync", "relay envelope pushed (\(envelope.count)B, outcome=\(outcome))")
        } catch {
            Log.warn("sync", "relay envelope push failed: \(error)")
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

    func relayReportHashes(cipher: Data) async {
        guard let binding = relay.binding(database: databaseName),
              let token = relay.token(database: databaseName) else { return }
        do {
            try await relayClient.putHashes(
                token: token, vaultId: binding.vaultId,
                cipherSha256: SyncConflict.sha256Hex(cipher),
                xmlSha256: SyncConflict.sha256Hex(database.xmlData()))
            Log.debug("sync", "relay hashes reported")
        } catch {
            Log.warn("sync", "relay hash report failed: \(error)")
        }
    }

    /// 库体密文副本推送(standalone Safari 扩展数据通路):网盘上传成功后
    /// 镜像到服务端 R2。失败不阻塞同步(副本缺失只影响扩展,下轮自愈)。
    func relayPushBody(cipher: Data) async {
        guard let binding = relay.binding(database: databaseName),
              let token = relay.token(database: databaseName) else { return }
        do {
            try await relayClient.putBody(token: token, vaultId: binding.vaultId, cipher: cipher)
        } catch RelayClient.RelayError.quotaExceeded {
            Log.warn("sync", "relay body push skipped: quota exceeded (vault=\(databaseName) size=\(cipher.count))")
        } catch {
            Log.warn("sync", "relay body push failed: \(error)")
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
            try await relayClient.requestCode(email: email, purpose: .sensitive)
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
    func relayTransferVault(masterPassword: String, newEmail: String, code: String) async -> Bool {
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
                token: token, vaultId: binding.vaultId, email: newEmail, code: code, deviceName: device)
            relay.storeSession(token: session.token, email: newEmail)
            relay.setBinding(
                RelayBinding(email: newEmail, vaultId: binding.vaultId, vaultName: binding.vaultName),
                database: databaseName)
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

    /// 本地库改名后迁移云端身份:网盘三件套改名 → 注册表 PATCH(vaultId 不变)
    /// → 本地绑定换键。失败仅记日志:残留旧名文件由下轮同步自愈重建,
    /// 注册表名不影响 vaultId 寻址。
    func relayMigrateAfterRename(from oldName: String, to newName: String) async {
        guard let binding = relay.binding(database: oldName),
              let token = relay.token(database: oldName) else { return }
        relay.migrateBinding(from: oldName, to: newName)
        if let driver = makeCloudDriver(databaseName: oldName) {
            do {
                try await driver.testConnection()
                try await driver.renameRemoteFiles(to: newName)
            } catch {
                Log.warn("sync", "relay drive rename failed: \(error)")
            }
        }
        do {
            try await relayClient.renameVault(token: token, vaultId: binding.vaultId, name: newName)
        } catch {
            Log.warn("sync", "relay registry rename failed: \(error)")
        }
    }

    // MARK: - 解锁版本检查(信封先行)

    /// 解锁后异步检查注册表密码版本:版本前进且会话密码解不开远端新信封 →
    /// 他机改密,本机强制锁定并换入新信封,用户须以新密码解锁
    /// (本机即改密端时会话密码可解新信封,仅追平本地副本,不锁)。
    func checkRelayPasswordVersion() async {
        guard phase == .unlocked, let binding = relay.binding(database: databaseName),
              let token = relay.token(database: databaseName) else { return }
        guard let record = try? await relayClient.getVault(token: token, vaultId: binding.vaultId) else {
            // 改密检测入口:网络失败留痕,否则「他机改密为何没触发锁定」无从排查
            Log.debug("sync", "relay password-version check fetch failed (network/offline)")
            return
        }
        let known = relay.knownPasswordVersion(database: databaseName) ?? record.passwordVersion
        relay.recordPasswordVersion(record.passwordVersion, database: databaseName)
        guard record.passwordVersion > known, let envelope = record.envelope else { return }
        Log.info("sync", "relay password version advanced \(known) → \(record.passwordVersion)")
        if (try? DatabaseCipher.unwrapVaultKey(envelope, password: password)) != nil {
            // 本机即改密端:本地信封已是新值,换入等价副本即可
            try? store.saveEnvelope(envelope, for: databaseName)
            return
        }
        forceLockForRemotePasswordChange(envelope)
    }

    /// 他机改密后的强制锁定:先落盘未保存修改,换入新信封(新密码可解锁),
    /// 清除钥匙串旧密码副本(防预填/生物识别误导),锁屏等待新密码。
    /// 换信封失败不锁定——旧密码仍可解锁本地,退回原接管提示路径。
    func forceLockForRemotePasswordChange(_ envelope: Data) {
        save()
        do {
            try store.saveEnvelope(envelope, for: databaseName)
            // 快照同步换新信封:锁定期间扩展侧用新密码即可解锁,不必等主 App 解锁
            SafariSnapshotBridge.push(databaseName: databaseName, store: store)
        } catch {
            Log.error("sync", "force-lock envelope swap failed: \(error)")
            syncRemoteUnreadable = true
            promptAdoptRemotePassword()
            return
        }
        PasswordStore.removePassword(databaseName: databaseName)
        Log.warn("sync", "remote password change — force locking \"\(databaseName)\" for new password")
        lock()
        AppToast.shared.show(L10n.t("relay_force_lock_message"))
    }
}
