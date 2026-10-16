import Foundation
import AuthenticationServices
import CryptoKit
import LocalAuthentication

import UPasswordsCore
import UPasswordsPersistence

// MARK: - 扩展状态机:未建库 → 解锁 → 凭证列表
//
// 数据源是 App Group 容器里的真实加密库(.upw):
// 优先钥匙串静默/生物读取主密码(同 Team keychain 共享),失败则要求手输。

@MainActor
final class AutoFillModel: ObservableObject {

    enum Stage { case noVault, locked, unlocked }

    /// 填充流:密码/一次性验证码/通行密钥断言/通行密钥注册(由系统入口决定)。
    enum Flow { case password, oneTimeCode, passkey, passkeyRegistration }

    @Published private(set) var flow: Flow = .password
    @Published var registerError = false

    @Published private(set) var stage: Stage = .locked
    @Published private(set) var canAutoUnlock = false
    @Published var query = ""
    @Published var masterInput = ""
    @Published var showUnlockError = false
    @Published private(set) var biometricWorking = false
    @Published private(set) var pickedID: Int? = nil

    private var context: ASCredentialProviderExtensionContext?
    private var serviceHosts: [String] = []
    private var all: [Card] = []
    /// 断言签名输入(列表流)。
    private var passkeyParams: ASPasskeyCredentialRequestParameters? = nil
    /// 指定请求(断言精确流 / 注册流)。
    private var passkeyRequest: ASPasskeyCredentialRequest? = nil
    /// 解锁后的库与库密钥(通行密钥写回 signCount / 注册入库用)。
    private var vaultDB: PasswordDatabase? = nil
    private var vaultName: String? = nil
    private var vaultKey: SymmetricKey? = nil

    var biometricAvailable: Bool { PasswordStore.biometricAvailable() }

    /// 面容 ID 开关由主 App 写入共享 defaults。
    var showBiometricButton: Bool {
        SharedVaultStore.defaults.bool(forKey: "set.faceID") && biometricAvailable
    }

    func attach(context: ASCredentialProviderExtensionContext,
                serviceIdentifiers: [ASCredentialServiceIdentifier],
                flow: Flow = .password) {
        self.flow = flow
        serviceHosts = serviceIdentifiers.compactMap { Self.normalizeHost($0.identifier) }
        begin(context: context)
    }

    /// 通行密钥断言列表流:系统给出 rpID/clientDataHash/allowedCredentials。
    func attachPasskeyList(context: ASCredentialProviderExtensionContext,
                           params: ASPasskeyCredentialRequestParameters) {
        flow = .passkey
        passkeyParams = params
        serviceHosts = [params.relyingPartyIdentifier]
        begin(context: context)
    }

    /// 指定请求的交互流(QuickType 选中或系统要求用户验证;密码与通行密钥共用解锁页)。
    func attach(context: ASCredentialProviderExtensionContext, request: any ASCredentialRequest) {
        if let passkeyReq = request as? ASPasskeyCredentialRequest {
            flow = .passkey
            passkeyRequest = passkeyReq
            let rp = (passkeyReq.credentialIdentity as? ASPasskeyCredentialIdentity)?.relyingPartyIdentifier
            serviceHosts = rp.map { [$0] } ?? []
        } else {
            flow = .password
            serviceHosts = [Self.normalizeHost(request.credentialIdentity.serviceIdentifier.identifier)].compactMap { $0 }
        }
        begin(context: context)
    }

    /// 通行密钥注册流。
    func attachPasskeyRegistration(context: ASCredentialProviderExtensionContext,
                                   request: any ASCredentialRequest) {
        flow = .passkeyRegistration
        passkeyRequest = request as? ASPasskeyCredentialRequest
        let rp = (request.credentialIdentity as? ASPasskeyCredentialIdentity)?.relyingPartyIdentifier
        serviceHosts = rp.map { [$0] } ?? []
        begin(context: context)
    }

    /// 各入口共用的装配:读库、判断解锁路径。
    private func begin(context: ASCredentialProviderExtensionContext) {
        self.context = context
        guard let main = SharedVaultStore.mainDatabase() else {
            Log.info("app", "autofill: no vault found in shared container")
            stage = .noVault
            return
        }
        vaultName = main.name
        // 钥匙串里有主密码则可解锁;用户启用了生物识别快解(biometric 副本
        // 存在)时,静默路径同样必须过 evaluatePolicy——否则持已解锁设备者
        // 打开 AutoFill 即可无面容读全库,快解形同虚设
        canAutoUnlock = PasswordStore.loadPassword(databaseName: main.name) != nil
        // 存在性探测必须用 hasBiometricItem:ACL 项的值读取需要已评估的 ctx
        let biometricEnabled = PasswordStore.hasBiometricItem(databaseName: main.name)
        if canAutoUnlock, biometricEnabled {
            Task { await unlockWithBiometrics() }
        } else if canAutoUnlock {
            // 普通钥匙串副本存在但无生物识别副本:静默解锁前必须过设备所有者
            // 认证(密码锁或生物识别)——否则持已解锁设备者可免验证浏览全库
            Task { await unlockGatedByDeviceOwnerAuthentication() }
        } else if showBiometricButton {
            Task { await unlockWithBiometrics() }
        } else {
            stage = .locked
        }
    }

    // MARK: 解锁

    /// 手输主密码解锁(解密失败即拒绝)。
    func unlock() {
        guard let main = SharedVaultStore.mainDatabase() else { return }
        guard let (db, vek) = try? SharedVaultStore.store.loadUnlocked(name: main.name, password: masterInput) else {
            Log.warn("app", "autofill: manual unlock rejected (wrong password)")
            showUnlockError = true
            masterInput = ""
            return
        }
        showUnlockError = false
        vaultKey = vek
        accept(database: db)
        Log.info("app", "autofill: manual unlock ok cards=\(db.cards.count)")
    }

    func unlockWithBiometrics() async {
        guard !biometricWorking else { return }
        guard let main = SharedVaultStore.mainDatabase(),
              PasswordStore.hasBiometricItem(databaseName: main.name) else { return }
        biometricWorking = true
        defer { biometricWorking = false }
        // 双层门禁:先应用层评估(交互入口),再凭已评估的 ctx 读取——
        // ACL 项(设备已设密码锁时)读取本身也要求生物识别,全程单次弹窗
        let context = LAContext()
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &policyError) else {
            Log.warn("keychain", "autofill: biometry unavailable (code \(policyError?.code ?? -1))")
            return
        }
        do {
            let ok = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: L10n.t("ios_autofill_biometric_reason"))
            guard ok else { return }
        } catch {
            Log.warn("keychain", "autofill: biometric evaluate failed: \(error)")
            return
        }
        guard let pw = PasswordStore.loadPassword(databaseName: main.name, biometric: true, context: context) else {
            Log.warn("keychain", "autofill: biometric item unreadable")
            return
        }
        guard let (db, vek) = try? SharedVaultStore.store.loadUnlocked(name: main.name, password: pw) else {
            Log.warn("keychain", "autofill: biometric password rejected")
            return
        }
        vaultKey = vek
        accept(database: db)
    }

    /// 无生物识别副本路径的门禁:.deviceOwnerAuthentication(密码锁或生物
    /// 识别)通过后才用普通钥匙串副本静默解锁;取消/失败/未设密码锁一律
    /// 退回手输主密码页,绝不免验证解库。
    private func unlockGatedByDeviceOwnerAuthentication() async {
        guard let name = vaultName else { return }
        let context = LAContext()
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            Log.warn("keychain", "autofill: device owner auth unavailable (code \(policyError?.code ?? -1)) → manual password")
            stage = .locked
            return
        }
        do {
            guard try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: L10n.t("ios_autofill_biometric_reason")) else {
                Log.info("keychain", "autofill: device owner auth denied → manual password")
                stage = .locked
                return
            }
        } catch {
            Log.warn("keychain", "autofill: device owner auth failed: \(error)")
            stage = .locked
            return
        }
        Log.info("keychain", "autofill: device owner auth ok → silent unlock with stored password")
        unlock(withStoredPassword: name)
    }

    private func unlock(withStoredPassword name: String) {
        guard let pw = PasswordStore.loadPassword(databaseName: name),
              let (db, vek) = try? SharedVaultStore.store.loadUnlocked(name: name, password: pw) else {
            stage = .locked
            return
        }
        vaultKey = vek
        accept(database: db)
    }

    private func accept(database db: PasswordDatabase) {
        vaultDB = db
        all = db.cards.filter {
            guard !$0.trashed && !$0.archived && !$0.template else { return false }
            switch flow {
            case .password:
                return !$0.login.isEmpty && !$0.password.isEmpty
            case .oneTimeCode:
                return $0.fields.contains { $0.type.isOneTimePassword && $0.hasValue }
            case .passkey:
                return $0.passkey != nil
            case .passkeyRegistration:
                return false // 注册流不展示列表
            }
        }
        stage = .unlocked
    }

    /// 合并写:以磁盘最新库为基线应用单点变更后落盘。
    /// 主 App 与扩展是共享同一 .upw 的两个进程,整库快照覆盖会把对端
    /// 并发保存静默回滚(last-writer-wins);重放式合并消除覆盖窗口。
    /// v2 本体只需库密钥即可解密重解析,无需主密码。
    /// - Parameter mutate: 在最新库上应用变更;返回 false 表示无事可做
    ///   (如目标条目已被对端删除),此时放弃写入、绝不覆盖。
    @discardableResult
    private func saveMerged(reason: String, _ mutate: (inout PasswordDatabase) -> Bool) -> Bool {
        guard let name = vaultName, let vaultKey else { return false }
        do {
            let data = try Data(contentsOf: SharedVaultStore.store.url(for: name))
            guard DatabaseCipher.isV2Container(data) else {
                Log.warn("db", "autofill: merge-write skipped: container not v2 (\(reason))")
                return false
            }
            var latest = try PasswordDatabase.parse(DatabaseCipher.decryptBody(data, vaultKey: vaultKey))
            guard mutate(&latest) else {
                Log.debug("db", "autofill: merge-write no-op (\(reason))")
                return false
            }
            try SharedVaultStore.store.save(latest, name: name, vaultKey: vaultKey)
            vaultDB = latest
            return true
        } catch {
            Log.error("db", "autofill: merge-write failed (\(reason)): \(error)")
            return false
        }
    }

    // MARK: 凭证匹配

    /// 规范化 host:兼容 "github.com" 与 "https://github.com/login"。
    static func normalizeHost(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if s.isEmpty { return nil }
        if !s.contains("://") { s = "https://" + s }
        guard let host = URL(string: s)?.host, !host.isEmpty else { return nil }
        return host
    }

    static func hostMatches(_ cardHost: String, service serviceHost: String) -> Bool {
        guard !cardHost.isEmpty, !serviceHost.isEmpty else { return false }
        if cardHost == serviceHost { return true }
        // 守卫与 WebExtensions domain.ts / SafariWebExtensionHandler 对齐:
        // 单标签 host(裸公共后缀 com/io)与纯数字标签(IP 尾段)禁止泛匹配,
        // 只允许全等——否则存了裸后缀/IP 尾段的条目会在任意外部域名被候选
        let labels = { (host: String) in host.split(separator: ".").filter { !$0.isEmpty } }
        guard labels(cardHost).count >= 2, labels(serviceHost).count >= 2 else { return false }
        let isNumericHost = { (host: String) in host.split(separator: ".").allSatisfy { UInt($0) != nil } }
        if isNumericHost(cardHost) || isNumericHost(serviceHost) { return false }
        return cardHost.hasSuffix("." + serviceHost)
            || serviceHost.hasSuffix("." + cardHost)
    }

    private func cardHost(_ card: Card) -> String? { Self.normalizeHost(card.website) }

    /// 与当前页面域名匹配的建议条目(通行密钥流按 RP 精确匹配)。
    var suggested: [Card] {
        if flow == .passkey { return filtered(all.filter(passkeyMatch)) }
        guard !serviceHosts.isEmpty else { return [] }
        return filtered(all.filter { card in
            guard let h = cardHost(card) else { return false }
            return serviceHosts.contains { Self.hostMatches(h, service: $0) }
        })
    }

    /// 当前断言的签名输入(rpID + clientDataHash),来自列表参数或指定请求。
    private var passkeySigningInput: (relyingParty: String, clientDataHash: Data)? {
        if let params = passkeyParams {
            return (params.relyingPartyIdentifier, params.clientDataHash)
        }
        if let request = passkeyRequest,
           let identity = request.credentialIdentity as? ASPasskeyCredentialIdentity {
            return (identity.relyingPartyIdentifier, request.clientDataHash)
        }
        return nil
    }

    /// 通行密钥匹配:RP 精确相等;列表流受 allowedCredentials 限制,
    /// 指定请求流精确到 credentialID。
    private func passkeyMatch(_ card: Card) -> Bool {
        guard let passkey = card.passkey,
              let input = passkeySigningInput,
              passkey.relyingParty == input.relyingParty else { return false }
        if let allowed = passkeyParams?.allowedCredentials, !allowed.isEmpty {
            return allowed.contains(passkey.credentialID)
        }
        if let request = passkeyRequest,
           let identity = request.credentialIdentity as? ASPasskeyCredentialIdentity {
            return passkey.credentialID == identity.credentialID
        }
        return true
    }

    /// 注册流展示信息(rpID + 用户名)。
    var registrationInfo: (relyingParty: String, userName: String)? {
        guard flow == .passkeyRegistration, let request = passkeyRequest,
              let identity = request.credentialIdentity as? ASPasskeyCredentialIdentity else { return nil }
        return (identity.relyingPartyIdentifier, identity.userName)
    }

    /// 其余条目(标题排序)。
    var others: [Card] {
        let ids = Set(suggested.map(\.id))
        return filtered(all.filter { !ids.contains($0.id) })
            .sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
    }

    var serviceHostLabel: String? { serviceHosts.first }

    private func filtered(_ cards: [Card]) -> [Card] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return cards }
        return cards.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || $0.login.localizedCaseInsensitiveContains(q)
                || $0.website.localizedCaseInsensitiveContains(q)
        }
    }

    // MARK: 点选与取消

    func pick(_ card: Card) {
        guard pickedID == nil else { return }
        switch flow {
        case .password:
            pickPassword(card)
        case .oneTimeCode:
            if #available(iOS 18.0, *) {
                pickOneTimeCode(card)
            }
        case .passkey:
            pickPasskey(card)
        case .passkeyRegistration:
            break // 注册走 registerPasskey()
        }
    }

    /// 断言签名:signCount +1 写回后提交系统。
    private func pickPasskey(_ card: Card) {
        guard let input = passkeySigningInput, var passkey = card.passkey else { return }
        let newCount = passkey.signCount &+ 1
        let authData = WebAuthn.authenticatorData(relyingParty: input.relyingParty,
                                                  userVerified: true, signCount: newCount)
        do {
            let signature = try WebAuthn.assertionSignature(privateKeyRaw: passkey.privateKey,
                                                            authData: authData,
                                                            clientDataHash: input.clientDataHash)
            passkey.signCount = newCount
            persistSignCount(passkey, on: card.id)
            pickedID = card.id
            Log.info("app", "autofill: passkey assertion cardId=\(card.id) rp=\(input.relyingParty)")
            let credential = ASPasskeyAssertionCredential(userHandle: passkey.userHandle,
                                                          relyingParty: input.relyingParty,
                                                          signature: signature,
                                                          clientDataHash: input.clientDataHash,
                                                          authenticatorData: authData,
                                                          credentialID: passkey.credentialID)
            context?.completeAssertionRequest(using: credential, completionHandler: nil)
        } catch {
            Log.error("app", "autofill: passkey sign failed cardId=\(card.id): \(error)")
        }
    }

    /// 断言后的计数器写回(失败不阻塞本次登录,仅记日志)。
    private func persistSignCount(_ passkey: Passkey, on cardID: Int) {
        saveMerged(reason: "signCount") { db in
            guard let i = db.cards.firstIndex(where: { $0.id == cardID }) else { return false }
            db.cards[i].setPasskey(passkey)
            return true
        }
    }

    /// 注册流确认创建:生成密钥对与 attestation,凭据入库后提交系统。
    func registerPasskey() {
        guard flow == .passkeyRegistration,
              let request = passkeyRequest,
              let identity = request.credentialIdentity as? ASPasskeyCredentialIdentity,
              vaultDB != nil else { return }
        registerError = false
        do {
            let pair = WebAuthn.generateKeyPair()
            let credentialID = WebAuthn.makeCredentialID()
            let attested = try WebAuthn.attestedCredentialData(credentialID: credentialID,
                                                               publicKeyX963: pair.publicKeyX963)
            let authData = WebAuthn.authenticatorData(relyingParty: identity.relyingPartyIdentifier,
                                                      userVerified: true, signCount: 0,
                                                      attestedCredentialData: attested)
            let attestation = WebAuthn.attestationObject(authData: authData)
            let passkey = Passkey(credentialID: credentialID,
                                  relyingParty: identity.relyingPartyIdentifier,
                                  userHandle: identity.userHandle,
                                  userName: identity.userName,
                                  privateKey: pair.privateKey,
                                  signCount: 0, created: Date().millis)
            var card = Card(id: 0)  // id 在合并闭包内按最新库分配
            card.title = identity.relyingPartyIdentifier
            card.symbol = "person.badge.key.fill"
            card.autofillEnabled = true
            card.created = Date().millis
            card.modified = Date().millis
            card.fields = [
                Field(name: L10n.db("login_field"), type: .login, value: identity.userName),
                Field(name: L10n.db("url_field"), type: .website,
                      value: "https://\(identity.relyingPartyIdentifier)"),
            ]
            card.setPasskey(passkey)
            let register: (inout PasswordDatabase) -> Bool = { db in
                card.id = db.nextItemId()
                db.cards.append(card)
                return true
            }
            guard saveMerged(reason: "passkey register", register) else {
                registerError = true
                return
            }
            Log.info("app", "autofill: passkey registered rp=\(identity.relyingPartyIdentifier) cardId=\(card.id)")
            let credential = ASPasskeyRegistrationCredential(relyingParty: identity.relyingPartyIdentifier,
                                                             clientDataHash: request.clientDataHash,
                                                             credentialID: credentialID,
                                                             attestationObject: attestation)
            context?.completeRegistrationRequest(using: credential, completionHandler: nil)
        } catch {
            registerError = true
            Log.error("app", "autofill: passkey register failed: \(error)")
        }
    }

    private func pickPassword(_ card: Card) {
        pickedID = card.id
        Log.info("app", "autofill: picked cardId=\(card.id) (只提交该站点凭据)")
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            let credential = ASPasswordCredential(user: card.login, password: card.password)
            context?.completeRequest(withSelectedCredential: credential)
        }
    }

    /// 验证码流点选:现场解析 TOTP 配置并计算当前码提交(iOS 18+)。
    @available(iOS 18.0, *)
    private func pickOneTimeCode(_ card: Card) {
        guard let field = card.fields.first(where: { $0.type.isOneTimePassword && $0.hasValue }),
              let config = try? TOTP.parse(field.value),
              let code = try? TOTP.code(config: config) else {
            Log.warn("app", "autofill: otp parse/generate failed cardId=\(card.id)")
            return
        }
        pickedID = card.id
        Log.info("app", "autofill: picked otp cardId=\(card.id)")
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            context?.completeOneTimeCodeRequest(using: ASOneTimeCodeCredential(code: code),
                                                completionHandler: nil)
        }
    }

    func cancel() {
        context?.cancelRequest(withError: NSError(
            domain: ASExtensionErrorDomain,
            code: ASExtensionError.userCanceled.rawValue))
    }
}
