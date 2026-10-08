import Foundation
import CryptoKit
import CommonCrypto

/// Encrypted database container:
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
public enum DatabaseCipher {
    public static let magic = Data("UPWDB1\0\0".utf8)
    public static let version: UInt32 = 1
    public static let saltLength = 16
    public static let iterations: UInt32 = 310_000

    public struct CipherError: LocalizedError {
    public init(message: String) { self.message = message }
        public let message: String
        public var errorDescription: String? { message }
    }

    // MARK: - DatabaseCipher class methods

    public static func encryptedData(_ plaintext: Data, password: String) throws -> Data {
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

    public static func decryptedData(_ data: Data, password: String) throws -> Data {
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

    public static func checkFileMagic(_ data: Data) -> Bool {
        guard data.count >= 16 + saltLength else { return false }
        return data.prefix(magic.count) == magic
    }

    public static func deriveKey(password: String, salt: Data, iterations: UInt32) -> SymmetricKey {
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

// MARK: - v2 信封加密(双密钥)
//
// 主密码(可改)只加密一个 32 字节随机「库密钥」(vault key);库密钥(永不变)
// 加密数据库本体。改主密码只重写 ~100 字节的信封文件(<名>.upwkey),
// 本体(<名>.upw)不动——改密传播零重写、零竞态窗口,其他端输一次新密码
// 解开信封即完成接管。
//
// 本体 v2 容器布局:
// ```
/// offset 0  : magic "UPWDB2\0\0"        (8 bytes)
/// offset 8  : format version = 2        (UInt32)
/// offset 12 : flags = 0                 (UInt32, 预留)
/// offset 16 : AES-GCM sealed box        (nonce 12 + ct + tag 16, key = vault key)
/// ```
/// 信封容器布局:
/// ```
/// offset 0  : magic "UPWKEY1\0"         (8 bytes)
/// offset 8  : version = 1               (UInt32)
/// offset 12 : PBKDF2 iterations          (UInt32)
/// offset 16 : password salt              (16 bytes)
/// offset 32 : wrapped vault key box      (nonce 12 + ct 32 + tag 16)
/// offset 92 : changedAt                  (Double LE, 改密/创建时间戳)
/// ```
extension DatabaseCipher {
    public static let magicV2 = Data("UPWDB2\0\0".utf8)
    public static let keyMagic = Data("UPWKEY1\0".utf8)
    public static let versionV2: UInt32 = 2
    /// v2 头固定 16 字节(magic+version+flags),其后即密封盒
    private static let v2HeaderLength = 16

    /// 生成随机 256 位库密钥(每库一个,创建/v1 迁移时生成,永不变)。
    public static func generateVaultKey() -> SymmetricKey { SymmetricKey(size: .bits256) }

    public static func isV2Container(_ data: Data) -> Bool {
        data.count >= v2HeaderLength && data.prefix(magicV2.count) == magicV2
    }

    /// 本体加密(v2):随机 nonce + 库密钥。
    public static func encryptBody(_ plaintext: Data, vaultKey: SymmetricKey) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: vaultKey)
        guard let combined = sealed.combined else {
            throw CipherError(message: "AES-GCM combined representation unavailable")
        }
        var out = magicV2
        out.append(withUnsafeBytes(of: versionV2.littleEndian) { Data($0) })
        out.append(withUnsafeBytes(of: UInt32(0).littleEndian) { Data($0) })
        out.append(combined)
        return out
    }

    /// 本体解密(v2):库密钥直接解,与主密码无关。
    public static func decryptBody(_ data: Data, vaultKey: SymmetricKey) throws -> Data {
        guard isV2Container(data) else {
            throw CipherError(message: "not a v2 container")
        }
        do {
            let box = try AES.GCM.SealedBox(combined: data.subdata(in: v2HeaderLength..<data.count))
            return try AES.GCM.open(box, using: vaultKey)
        } catch {
            throw CipherError(message: "vault key mismatch")
        }
    }

    /// 信封封装:主密码派生密钥包裹库密钥。changedAt 供对端提示改密时间。
    public static func wrapVaultKey(_ vaultKey: SymmetricKey, password: String,
                                    changedAt: Date = Date()) throws -> Data {
        let salt = Data((0..<saltLength).map { _ in UInt8.random(in: 0...255) })
        let key = deriveKey(password: password, salt: salt, iterations: iterations)
        let rawKey = vaultKey.withUnsafeBytes { Data($0) }
        let sealed = try AES.GCM.seal(rawKey, using: key)
        guard let combined = sealed.combined else {
            throw CipherError(message: "AES-GCM combined representation unavailable")
        }
        var out = keyMagic
        out.append(withUnsafeBytes(of: version.littleEndian) { Data($0) })
        out.append(withUnsafeBytes(of: iterations.littleEndian) { Data($0) })
        out.append(salt)
        out.append(combined)
        out.append(withUnsafeBytes(of: changedAt.timeIntervalSince1970.bitPattern.littleEndian) { Data($0) })
        return out
    }

    /// 信封解封:主密码解出库密钥;密码错抛 wrong_password_error。
    public static func unwrapVaultKey(_ data: Data, password: String) throws -> SymmetricKey {
        guard data.count >= 92, data.prefix(keyMagic.count) == keyMagic else {
            throw CipherError(message: "not a key envelope")
        }
        let iters = data.subdata(in: 12..<16).withUnsafeBytes { $0.load(as: UInt32.self) }
        let salt = data.subdata(in: 16..<(16 + saltLength))
        let key = deriveKey(password: password, salt: salt, iterations: iters)
        do {
            let box = try AES.GCM.SealedBox(combined: data.subdata(in: 32..<92))
            let rawKey = try AES.GCM.open(box, using: key)
            return SymmetricKey(data: rawKey)
        } catch {
            throw CipherError(message: L10n.t("wrong_password_error"))
        }
    }

    /// 信封里的改密时间戳(展示用;读取失败返回 nil)。
    public static func envelopeChangedAt(_ data: Data) -> Date? {
        guard data.count >= 100, data.prefix(keyMagic.count) == keyMagic else { return nil }
        let bits = data.subdata(in: 92..<100).withUnsafeBytes { $0.load(as: UInt64.self) }
        return Date(timeIntervalSince1970: TimeInterval(bitPattern: UInt64(littleEndian: bits)))
    }
}
