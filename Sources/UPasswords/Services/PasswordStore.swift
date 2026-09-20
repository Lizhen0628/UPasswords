import Foundation
import Security
import LocalAuthentication

/// Mirrors `PasswordStore` (Services/PasswordStore.h) — per-database keychain
/// storage, with an optional biometry-protected entry for fast unlock
/// (fast_unlock_setting / Touch ID).
enum PasswordStore {
    static func service(forDatabaseName name: String) -> String { "UPasswords-\(name)" }

    static func hasPassword(databaseName: String) -> Bool {
        loadPassword(databaseName: databaseName, biometric: false) != nil
    }

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
        SecItemAdd(attrs as CFDictionary, nil)
    }

    /// Biometry-protected copy: reading it triggers Touch ID / Apple watch prompt.
    static func savePasswordForBiometric(_ password: String, databaseName: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(forDatabaseName: databaseName),
            kSecAttrAccount as String: "biometric",
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = Data(password.utf8)
        let acl = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, nil
        )
        if let acl { attrs[kSecAttrAccessControl as String] = acl }
        SecItemAdd(attrs as CFDictionary, nil)
    }

    static func loadPassword(databaseName: String, biometric: Bool = false) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(forDatabaseName: databaseName),
            kSecAttrAccount as String: biometric ? "biometric" : "database",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if biometric {
            query[kSecUseAuthenticationContext as String] = LAContext()
        }
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Returns the biometric-protected password after a successful Touch ID
    /// prompt, or nil if unavailable/cancelled.
    static func biometricPassword(databaseName: String) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(forDatabaseName: databaseName),
            kSecAttrAccount as String: "biometric",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        let ctx = LAContext()
        query[kSecUseAuthenticationContext as String] = ctx
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else { return nil }
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
        SecItemDelete(query as CFDictionary)
    }

    /// eraseDataForDatabaseName:
    static func eraseData(databaseName: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(forDatabaseName: databaseName),
        ]
        SecItemDelete(query as CFDictionary)
    }
}
