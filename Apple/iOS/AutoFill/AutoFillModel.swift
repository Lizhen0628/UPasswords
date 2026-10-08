import Foundation
import AuthenticationServices

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
    /// 解锁后的库与凭据(通行密钥写回 signCount / 注册入库用)。
    private var vaultDB: PasswordDatabase? = nil
    private var vaultName: String? = nil
    private var vaultPassword: String? = nil

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
        // 钥匙串里有主密码则可直接(静默或经面容 ID)解锁
        canAutoUnlock = PasswordStore.loadPassword(databaseName: main.name) != nil
        if canAutoUnlock {
            unlock(withStoredPassword: main.name)
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
        guard let db = try? SharedVaultStore.store.load(name: main.name, password: masterInput) else {
            Log.warn("app", "autofill: manual unlock rejected (wrong password)")
            showUnlockError = true
            masterInput = ""
            return
        }
        showUnlockError = false
        vaultPassword = masterInput
        accept(database: db)
        Log.info("app", "autofill: manual unlock ok cards=\(db.cards.count)")
    }

    func unlockWithBiometrics() async {
        guard !biometricWorking else { return }
        guard let main = SharedVaultStore.mainDatabase(),
              let pw = PasswordStore.loadPassword(databaseName: main.name, biometric: true) else { return }
        biometricWorking = true
        defer { biometricWorking = false }
        guard let db = try? SharedVaultStore.store.load(name: main.name, password: pw) else {
            Log.warn("keychain", "autofill: biometric password rejected")
            return
        }
        vaultPassword = pw
        accept(database: db)
    }

    private func unlock(withStoredPassword name: String) {
        guard let pw = PasswordStore.loadPassword(databaseName: name),
              let db = try? SharedVaultStore.store.load(name: name, password: pw) else {
            stage = .locked
            return
        }
        vaultPassword = pw
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

    /// 解锁后的写库(signCount 写回 / 注册入库);失败仅记日志。
    @discardableResult
    private func saveDatabase(_ db: PasswordDatabase, reason: String) -> Bool {
        guard let name = vaultName, let password = vaultPassword else { return false }
        do {
            try SharedVaultStore.store.save(db, name: name, password: password)
            vaultDB = db
            return true
        } catch {
            Log.error("db", "autofill: save failed (\(reason)): \(error)")
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
        cardHost == serviceHost
            || cardHost.hasSuffix("." + serviceHost)
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
        guard var db = vaultDB, let i = db.cards.firstIndex(where: { $0.id == cardID }) else { return }
        db.cards[i].setPasskey(passkey)
        saveDatabase(db, reason: "signCount")
    }

    /// 注册流确认创建:生成密钥对与 attestation,凭据入库后提交系统。
    func registerPasskey() {
        guard flow == .passkeyRegistration,
              let request = passkeyRequest,
              let identity = request.credentialIdentity as? ASPasskeyCredentialIdentity,
              var db = vaultDB else { return }
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
            var card = Card(id: db.nextItemId())
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
            db.cards.append(card)
            guard saveDatabase(db, reason: "passkey register") else {
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
            try? await Task.sleep(nanoseconds: 350_000_000)
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
            try? await Task.sleep(nanoseconds: 350_000_000)
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
