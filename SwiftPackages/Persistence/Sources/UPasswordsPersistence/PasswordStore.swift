import Foundation
import Security
import LocalAuthentication
import UPasswordsCore

/// Per-database keychain storage, with an optional biometry-protected entry
/// for fast unlock (Touch ID).
public enum PasswordStore {
    public static func service(forDatabaseName name: String) -> String { "UPasswords-\(name)" }

    public static func savePassword(_ password: String, databaseName: String) {
        save(password: password, account: "database", databaseName: databaseName)
    }

    /// 测试缝隙:CI 无密码锁/生物识别,强制走普通项路径保证确定性。
    static var usePlainBiometricItemsForTesting = false

    /// Biometry-gated copy of the database password.
    ///
    /// 双层门禁:优先存 kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly +
    /// SecAccessControl(.userPresence) 项——读取必须过系统生物识别(硬件层),
    /// 配合 kSecUseAuthenticationContext 复用调用方已评估的 LAContext,
    /// 全程只弹一次。设备未设密码锁或未正确签名(SecItemAdd 失败,如 -34018)
    /// 时回退普通项,由 evaluatePolicy 做唯一门禁(历史行为)。
    public static func savePasswordForBiometric(_ password: String, databaseName: String) {
        if !usePlainBiometricItemsForTesting, saveSecured(password: password, databaseName: databaseName) {
            return
        }
        save(password: password, account: "biometric", databaseName: databaseName)
    }

    /// 带 userPresence ACL 的加固项;成功返回 true。
    private static func saveSecured(password: String, databaseName: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(forDatabaseName: databaseName),
            kSecAttrAccount as String: "biometric",
        ]
        SecItemDelete(query as CFDictionary)
        var accessError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            .userPresence,
            &accessError
        ) else {
            // 未设密码锁等场景:创建失败走普通项回退
            Log.warn("keychain", "secured biometric item unavailable (\(accessError?.takeRetainedValue().localizedDescription ?? "unknown")) — falling back to plain item")
            return false
        }
        var attrs = query
        attrs[kSecValueData as String] = Data(password.utf8)
        attrs[kSecAttrAccessControl as String] = access
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status == errSecSuccess {
            Log.info("keychain", "secured biometric item saved for \(service(forDatabaseName: databaseName)) (userPresence ACL)")
            return true
        }
        Log.logKeychain("save secured biometric item (falling back to plain)", status: status)
        SecItemDelete(query as CFDictionary)
        return false
    }

    /// 写入钥匙串密码副本的共用实现(普通项与生物识别项仅 account 不同)。
    private static func save(password: String, account: String, databaseName: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(forDatabaseName: databaseName),
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = Data(password.utf8)
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(attrs as CFDictionary, nil)
        Log.logKeychain("save \"\(account)\" for \(service(forDatabaseName: databaseName))", status: status)
    }

    /// 移除库的钥匙串密码副本(数据库项与生物识别项)。
    /// 他机改密后强制锁定时调用:清掉旧密码副本,避免锁屏预填/生物识别
    /// 用旧密码误导用户;重新解锁成功后由解锁路径自愈回写新密码。
    public static func removePassword(databaseName: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(forDatabaseName: databaseName),
        ]
        for account in ["database", "biometric"] {
            var query = base
            query[kSecAttrAccount as String] = account
            SecItemDelete(query as CFDictionary)
        }
        Log.logKeychain("remove password copies for \(service(forDatabaseName: databaseName))", status: errSecSuccess)
    }

    public static func hasBiometricItem(databaseName: String) -> Bool {        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(forDatabaseName: databaseName),
            kSecAttrAccount as String: "biometric",
        ]
        let ok = SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
        Log.debug("keychain", "hasBiometricItem \(service(forDatabaseName: databaseName)) = \(ok)")
        return ok
    }

    /// Prompts Touch ID, then (on success) returns the stored database password
    /// via `completion`. `completion` is called on an arbitrary queue.
    public static func biometricPassword(databaseName: String, completion: @escaping (String?) -> Void) {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err) else {
            Log.warn("keychain", "biometric unavailable: \(err?.localizedDescription ?? "unknown")")
            completion(nil)
            return
        }
        Log.debug("keychain", "evaluating Touch ID policy")
        ctx.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: L10n.t("touch_id_unlock_reason")
        ) { ok, error in
            if ok {
                Log.debug("keychain", "Touch ID ok → reading password copy")
                // 门禁已过,优先读普通副本:部分系统版本上读 ACL 项会再同步
                // 触发一次生物识别(双弹窗,极端时主线程卡死被看门狗杀),
                // 普通副本可静默读取,保证全程只弹一次。无副本再回退 ACL 项。
                if let plain = loadPassword(databaseName: databaseName) {
                    completion(plain)
                    return
                }
                completion(loadPassword(databaseName: databaseName, biometric: true, context: ctx))
            } else {
                Log.warn("keychain", "Touch ID denied: \(error?.localizedDescription ?? "unknown")")
                completion(nil)
            }
        }
    }

    /// - Parameter context: 已通过 evaluatePolicy 的 LAContext;带 ACL 的
    ///   biometric 项必须凭它静默读取(否则 errSecInteractionNotAllowed)。
    public static func loadPassword(databaseName: String, biometric: Bool = false,
                                    context: LAContext? = nil) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(forDatabaseName: databaseName),
            kSecAttrAccount as String: biometric ? "biometric" : "database",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let context {
            query[kSecUseAuthenticationContext as String] = context
        }
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        let account = biometric ? "biometric" : "database"
        guard status == errSecSuccess, let data = out as? Data else {
            Log.warn("keychain", "load \"\(account)\" for \(service(forDatabaseName: databaseName)) failed (OSStatus \(status))")
            return nil
        }
        Log.debug("keychain", "load \"\(account)\" for \(service(forDatabaseName: databaseName)) ok (\(data.count) chars)")
        return String(data: data, encoding: .utf8)
    }

    public static func biometricAvailable() -> Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    public static func removeBiometricPassword(databaseName: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(forDatabaseName: databaseName),
            kSecAttrAccount as String: "biometric",
        ]
        let status = SecItemDelete(query as CFDictionary)
        Log.debug("keychain", "removeBiometricPassword \(service(forDatabaseName: databaseName)) (OSStatus \(status))")
    }

    /// eraseDataForDatabaseName:
    public static func eraseData(databaseName: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(forDatabaseName: databaseName),
        ]
        let status = SecItemDelete(query as CFDictionary)
        Log.debug("keychain", "eraseData \(service(forDatabaseName: databaseName)) (OSStatus \(status))")
    }
}

extension Log {
    /// 钥匙串错误码统一翻译,常用的直接给含义(OSStatus 码难记)。
    public static func logKeychain(_ what: String, status: OSStatus) {
        if status == errSecSuccess {
            info("keychain", "\(what) ok")
            return
        }
        let meaning: String
        switch status {
        case errSecItemNotFound: meaning = "item not found"
        case errSecDuplicateItem: meaning = "duplicate item"
        case errSecInteractionNotAllowed: meaning = "interaction not allowed (locked keychain / ACL)"
        case -34018: meaning = "missing entitlement (app not properly signed)"
        default: meaning = "see Security framework docs"
        }
        error("keychain", "\(what) FAILED (OSStatus \(status): \(meaning))")
    }
}
