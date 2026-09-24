import Foundation
import Security
import LocalAuthentication

/// Per-database keychain storage, with an optional biometry-protected entry
/// for fast unlock (Touch ID).
enum PasswordStore {
    static func service(forDatabaseName name: String) -> String { "UPasswords-\(name)" }

    static func savePassword(_ password: String, databaseName: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(forDatabaseName: databaseName),
            kSecAttrAccount as String: "database",
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = Data(password.utf8)
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(attrs as CFDictionary, nil)
        Log.logKeychain("save \"database\" for \(service(forDatabaseName: databaseName)) (\(password.count) chars)", status: status)
    }

    /// Biometry-gated copy of the database password.
    ///
    /// 注意:带 SecAccessControl(.userPresence) 的钥匙串项要求 app 有正式签名 +
    /// keychain-access-groups 权限,否则 SecItemAdd 返回 -34018(missing
    /// entitlement),Touch ID 永远无法启用(未签名分发正好命中)。因此这里存
    /// 普通项(与 "database" 项同等保护级别,其他进程读取仍会弹系统授权框),
    /// Touch ID 门禁改由 biometricPassword 的 LAContext.evaluatePolicy 完成。
    static func savePasswordForBiometric(_ password: String, databaseName: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(forDatabaseName: databaseName),
            kSecAttrAccount as String: "biometric",
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = Data(password.utf8)
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(attrs as CFDictionary, nil)
        Log.logKeychain("save \"biometric\" for \(service(forDatabaseName: databaseName)) (\(password.count) chars)", status: status)
    }

    static func hasBiometricItem(databaseName: String) -> Bool {
        let query: [String: Any] = [
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
    static func biometricPassword(databaseName: String, completion: @escaping (String?) -> Void) {
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
                Log.debug("keychain", "Touch ID ok → reading biometric item")
                completion(loadPassword(databaseName: databaseName, biometric: true))
            } else {
                Log.warn("keychain", "Touch ID denied: \(error?.localizedDescription ?? "unknown")")
                completion(nil)
            }
        }
    }

    static func loadPassword(databaseName: String, biometric: Bool = false) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(forDatabaseName: databaseName),
            kSecAttrAccount as String: biometric ? "biometric" : "database",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        // biometric 项不带 ACL(evaluatePolicy 已做生物识别门禁),静默读取
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

    static func biometricAvailable() -> Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    static func removeBiometricPassword(databaseName: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(forDatabaseName: databaseName),
            kSecAttrAccount as String: "biometric",
        ]
        let status = SecItemDelete(query as CFDictionary)
        Log.debug("keychain", "removeBiometricPassword \(service(forDatabaseName: databaseName)) (OSStatus \(status))")
    }

    /// eraseDataForDatabaseName:
    static func eraseData(databaseName: String) {
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
    static func logKeychain(_ what: String, status: OSStatus) {
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
