import Foundation
import Security
import UPasswordsCore

/// 本地库与 API 注册表的绑定:哪个账户下的哪个 vaultId。
public struct RelayBinding: Codable, Equatable {
    /// 绑定账户的邮箱；与密码库内容分开管理。
    public let email: String
    /// 账户下的服务端密码库身份。
    public let vaultId: String
    /// 服务端密码库展示名。
    public let vaultName: String

    /// 创建本地库与账户注册表的绑定值。
    ///
    /// - Parameters:
    ///   - email: 账户邮箱。
    ///   - vaultId: 服务端库身份。
    ///   - vaultName: 服务端库展示名。
    public init(email: String, vaultId: String, vaultName: String) {
        self.email = email
        self.vaultId = vaultId
        self.vaultName = vaultName
    }
}

/// 账户令牌存取(协议化以便测试注入内存实现)。
public protocol RelayTokenStoring: AnyObject {
    /// 更新账户令牌；实现须限制明文令牌的存储与日志访问。
    ///
    /// - Parameters:
    ///   - token: Bearer 令牌明文。
    ///   - email: 令牌所属账户邮箱。
    func saveToken(_ token: String, for email: String)

    /// 读取账户令牌；缺失或不可读时返回 nil。
    ///
    /// - Parameter email: 账户邮箱。
    /// - Returns: 调用云 API 所需的令牌明文。
    func token(for email: String) -> String?

    /// 移除本地账户令牌；远端会话撤销由调用方负责。
    ///
    /// - Parameter email: 账户邮箱。
    func deleteToken(for email: String)
}

/// 账户令牌钥匙串存储:每邮箱一项,设备本机有效期随会话(90 天滑动)。
public final class RelayTokenKeychain: RelayTokenStoring {
    private let service = "com.upasswords.relay.account"

    /// 创建使用本机非同步钥匙串项的账户令牌存储。
    public init() {}

    /// 更新账户令牌钥匙串项，失败通过安全日志报告。
    ///
    /// - Parameters:
    ///   - token: Bearer 令牌明文。
    ///   - email: 令牌所属账户邮箱。
    public func saveToken(_ token: String, for email: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: email,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            // 新增失败(如缺 entitlement)会让登录态重启后静默丢失,必须留痕
            Log.logKeychain("relay token add (email-length=\(email.count))", status: addStatus)
        } else if updateStatus != errSecSuccess {
            Log.logKeychain("relay token update (email-length=\(email.count))", status: updateStatus)
        }
        Log.debug("sync", "relay token saved for email-length=\(email.count)")
    }

    /// 读取账户钥匙串令牌。
    ///
    /// - Parameter email: 账户邮箱。
    /// - Returns: 可读令牌；缺失、无权限或编码无效时返回 nil。
    public func token(for email: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: email,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 删除指定账户的本机钥匙串令牌。
    ///
    /// - Parameter email: 账户邮箱；服务端会话撤销由调用方另行执行。
    public func deleteToken(for email: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: email,
        ]
        SecItemDelete(query as CFDictionary)
        Log.debug("sync", "relay token deleted for email-length=\(email.count)")
    }
}

/// 库级中继状态:绑定关系、密码版本高水位、账户清单(按库持久化于注入的 defaults)。
/// macOS 注入 .standard,iOS 注入 App Group 共享 suite——双端语义一致。
public final class RelayStore {
    private let defaults: UserDefaults
    private let tokens: RelayTokenStoring
    /// 会话令牌进程内缓存:自动同步每轮都要令牌,若每次都读钥匙串,
    /// 签名漂移/ACL 变化时会被 macOS 逐次弹授权——缓存后每进程只读一次。
    private let cacheLock = NSLock()
    private var tokenCache: [String: String] = [:]

    /// 创建库绑定与账户状态存储，令牌通过独立存储接口读写。
    ///
    /// - Parameters:
    ///   - defaults: macOS 使用标准偏好，iOS 使用 App Group suite。
    ///   - tokens: 令牌存储依赖，可注入测试实现。
    public init(defaults: UserDefaults, tokens: RelayTokenStoring = RelayTokenKeychain()) {
        self.defaults = defaults
        self.tokens = tokens
    }

    // MARK: - 绑定(库 → 注册表记录)

    private func bindingKey(_ database: String) -> String { "sync.relay.binding.\(database)" }

    /// 读取指定本地库的云端绑定。
    ///
    /// - Parameter database: 本地库名。
    /// - Returns: 已保存的绑定；不存在或记录损坏时为 nil。
    public func binding(database: String) -> RelayBinding? {
        defaults.data(forKey: bindingKey(database)).flatMap {
            try? JSONDecoder().decode(RelayBinding.self, from: $0)
        }
    }

    /// 保存或移除本地库绑定，同时记录该库曾经绑定的事实。
    ///
    /// - Parameters:
    ///   - binding: 新绑定；nil 仅移除当前绑定，不重置曾绑定标记。
    ///   - database: 本地库名。
    public func setBinding(_ binding: RelayBinding?, database: String) {
        guard let binding else {
            defaults.removeObject(forKey: bindingKey(database))
            Log.info("sync", "relay binding cleared for \"\(database)\"")
            return
        }
        defaults.set(try? JSONEncoder().encode(binding), forKey: bindingKey(database))
        defaults.set(true, forKey: "sync.relay.everb.\(database)")
        Log.info("sync", "relay binding set for \"\(database)\" vault=\(binding.vaultId.prefix(8))…")
    }

    /// 该库是否曾被绑定过(解绑后保持 true):自动补绑只发生在从未绑定的库上,
    /// 用户主动解绑不被下次解锁悄悄回绑。
    public func everBound(database: String) -> Bool {
        defaults.bool(forKey: "sync.relay.everb.\(database)")
    }

    /// 最近一次登录的账户邮箱(设备级):新装引导"先登录后建库"的判定依据
    /// (邮箱验证为必经步骤,未登录不得进入向导)。
    public var lastAccountEmail: String? {
        get { defaults.string(forKey: "sync.relay.account.email") }
        set { defaults.set(newValue, forKey: "sync.relay.account.email") }
    }

    /// 本地库改名:绑定与版本高水位随库名迁移(vaultId 身份不变)。
    public func migrateBinding(from oldDatabase: String, to newDatabase: String) {
        guard let binding = binding(database: oldDatabase), oldDatabase != newDatabase else { return }
        setBinding(RelayBinding(email: binding.email, vaultId: binding.vaultId,
                                vaultName: newDatabase), database: newDatabase)
        setBinding(nil, database: oldDatabase)
        if let version = knownPasswordVersion(database: oldDatabase) {
            defaults.set(version, forKey: versionKey(newDatabase))
            defaults.removeObject(forKey: versionKey(oldDatabase))
        }
        Log.info("sync", "relay binding migrated \"\(oldDatabase)\" → \"\(newDatabase)\"")
    }

    // MARK: - 密码版本高水位(改密检测的本地基准)

    private func versionKey(_ database: String) -> String { "sync.relay.version.\(database)" }

    /// 读取本机已确认的远端改密版本。
    ///
    /// - Parameter database: 本地库名。
    /// - Returns: 已记录版本；尚无记录时为 nil。
    public func knownPasswordVersion(database: String) -> Int? {
        let value = defaults.integer(forKey: versionKey(database))
        return value > 0 ? value : nil
    }

    /// 持久化指定库已确认的密码版本。
    ///
    /// - Parameters:
    ///   - version: 服务端返回的改密版本。
    ///   - database: 本地库名。
    public func recordPasswordVersion(_ version: Int, database: String) {
        let known = knownPasswordVersion(database: database) ?? 0
        guard version > known else { return }
        defaults.set(version, forKey: versionKey(database))
    }

    // MARK: - 会话令牌

    /// 该库绑定账户的会话令牌(带进程内缓存);未绑定或未登录返回 nil。
    public func token(database: String) -> String? {
        guard let binding = binding(database: database) else { return nil }
        return token(email: binding.email)
    }

    /// 按邮箱取会话令牌(带进程内缓存;引导登录先于库绑定时使用)。
    public func token(email: String) -> String? {
        cacheLock.lock()
        if let cached = tokenCache[email] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        guard let token = tokens.token(for: email) else { return nil }
        cacheLock.lock()
        tokenCache[email] = token
        cacheLock.unlock()
        return token
    }

    /// 登录成功后保存令牌并记住账户(引导门槛随之解除)。
    public func storeSession(token: String, email: String) {
        tokens.saveToken(token, for: email)
        cacheLock.lock()
        tokenCache[email] = token
        cacheLock.unlock()
        lastAccountEmail = email
    }

    /// 登出:清令牌(钥匙串与缓存)与该库绑定(库数据与网盘文件不动)。
    public func logout(database: String) {
        if let binding = binding(database: database) {
            tokens.deleteToken(for: binding.email)
            cacheLock.lock()
            tokenCache.removeValue(forKey: binding.email)
            cacheLock.unlock()
        }
        setBinding(nil, database: database)
    }

    /// 已登录账户邮箱(供设置页展示;按绑定推导)。
    public func accountEmail(database: String) -> String? {
        binding(database: database)?.email
    }
}
