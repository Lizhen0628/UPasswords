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

    /// 填充流:密码(默认)或一次性验证码(iOS 18+ 由系统入口决定)。
    enum Flow { case password, oneTimeCode }

    @Published private(set) var flow: Flow = .password

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

    var biometricAvailable: Bool { PasswordStore.biometricAvailable() }

    /// 面容 ID 开关由主 App 写入共享 defaults。
    var showBiometricButton: Bool {
        SharedVaultStore.defaults.bool(forKey: "set.faceID") && biometricAvailable
    }

    func attach(context: ASCredentialProviderExtensionContext,
                serviceIdentifiers: [ASCredentialServiceIdentifier],
                flow: Flow = .password) {
        self.context = context
        self.flow = flow
        serviceHosts = serviceIdentifiers.compactMap { Self.normalizeHost($0.identifier) }
        guard let main = SharedVaultStore.mainDatabase() else {
            Log.info("app", "autofill: no vault found in shared container")
            stage = .noVault
            return
        }
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
        accept(database: db)
    }

    private func unlock(withStoredPassword name: String) {
        guard let pw = PasswordStore.loadPassword(databaseName: name),
              let db = try? SharedVaultStore.store.load(name: name, password: pw) else {
            stage = .locked
            return
        }
        accept(database: db)
    }

    private func accept(database db: PasswordDatabase) {
        all = db.cards.filter {
            guard !$0.trashed && !$0.archived && !$0.template else { return false }
            switch flow {
            case .password:
                return !$0.login.isEmpty && !$0.password.isEmpty
            case .oneTimeCode:
                return $0.fields.contains { $0.type.isOneTimePassword && $0.hasValue }
            }
        }
        stage = .unlocked
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

    /// 与当前页面域名匹配的建议条目。
    var suggested: [Card] {
        guard !serviceHosts.isEmpty else { return [] }
        return filtered(all.filter { card in
            guard let h = cardHost(card) else { return false }
            return serviceHosts.contains { Self.hostMatches(h, service: $0) }
        })
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
