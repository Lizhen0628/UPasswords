import Foundation
import CryptoKit
import CommonCrypto

/// Mirrors `DatabaseCipher` (Services/DatabaseCipher.h).
///
/// The original binary's exact cipher parameters are not recoverable from the
/// Mach-O (only `CCCryptor` / SHA references are visible). This replica uses
/// the modern equivalent chosen by the reverse-engineering notes:
/// PBKDF2-SHA256 × 310,000 + AES-256-GCM.
///
/// Container layout (little-endian fixed fields + ciphertext):
/// ```
/// offset 0  : magic "UPWDB1\0\0"        (8 bytes)
/// offset 8  : format version            (UInt32)
/// offset 12 : PBKDF2 iterations          (UInt32)
/// offset 16 : salt                       (16 bytes)
/// offset 32 : AES-GCM sealed box         (nonce 12 + ct + tag 16)
/// ```
enum DatabaseCipher {
    static let magic = Data("UPWDB1\0\0".utf8)
    static let version: UInt32 = 1
    static let saltLength = 16
    static let iterations: UInt32 = 310_000

    struct CipherError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: - DatabaseCipher class methods

    static func encryptedData(_ plaintext: Data, password: String) throws -> Data {
        let salt = Data((0..<saltLength).map { _ in UInt8.random(in: 0...255) })
        let key = deriveKey(password: password, salt: salt, iterations: iterations)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else {
            throw CipherError(message: "AES-GCM combined representation unavailable")
        }
        var out = magic
        out.append(withUnsafeBytes(of: version.littleEndian) { Data($0) })
        out.append(withUnsafeBytes(of: iterations.littleEndian) { Data($0) })
        out.append(salt)
        out.append(combined)
        return out
    }

    static func decryptedData(_ data: Data, password: String) throws -> Data {
        guard checkFileMagic(data) else {
            throw CipherError(message: L10n.t("wrong_database_format_error"))
        }
        let iters = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self) }
        let salt = data.subdata(in: 16..<(16 + saltLength))
        let boxData = data.subdata(in: (16 + saltLength)..<data.count)
        let key = deriveKey(password: password, salt: salt, iterations: iters)
        do {
            let box = try AES.GCM.SealedBox(combined: boxData)
            return try AES.GCM.open(box, using: key)
        } catch {
            throw CipherError(message: L10n.t("wrong_password_error"))
        }
    }

    static func checkFileMagic(_ data: Data) -> Bool {
        guard data.count >= 16 + saltLength else { return false }
        return data.prefix(magic.count) == magic
    }

    static func deriveKey(password: String, salt: Data, iterations: UInt32) -> SymmetricKey {
        var derived = Data(repeating: 0, count: 32)
        let pw = Data(password.utf8)
        derived.withUnsafeMutableBytes { derivedPtr in
            salt.withUnsafeBytes { saltPtr in
                pw.withUnsafeBytes { pwPtr in
                    _ = CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pwPtr.bindMemory(to: Int8.self).baseAddress, pw.count,
                        saltPtr.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        iterations,
                        derivedPtr.bindMemory(to: UInt8.self).baseAddress, 32
                    )
                }
            }
        }
        return SymmetricKey(data: derived)
    }
}
