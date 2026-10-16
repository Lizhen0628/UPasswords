import Foundation
import CryptoKit
import CommonCrypto

/// Encrypted database vault: v2 envelope cipher (dual-key) only.
///
/// 主密码(可改)只加密一个 32 字节随机「库密钥」(vault key);库密钥加密
/// 数据库本体。改主密码由会话层编排:轮换库密钥并重加密本体 + 重写信封
/// (<名>.upwkey),旧密文对旧密码永久作废;他端凭注册表信封决胜收敛,
/// 输一次新密码解开信封即完成接管。
public enum DatabaseCipher {
    /// 信封格式版本号
    public static let version: UInt32 = 1
    public static let saltLength = 16
    /// 新信封迭代数(OWASP 2023+ 档位;存量 310k 信封仍按文件头值读取)
    public static let iterations: UInt32 = 600_000
    /// 信封迭代下限:低于此值视为恶意/损坏文件,拒绝解(格式错误,非密码错误)
    public static let minimumEnvelopeIterations: UInt32 = 100_000
    /// 迭代上限(与 TS 端 vault-crypto 对齐):伪造 40 亿次迭代的信封
    /// 会把解密端 UI 冻结 1-2 小时
    public static let maximumEnvelopeIterations: UInt32 = 10_000_000

    public struct CipherError: LocalizedError {
        public let message: String
        public init(message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    // MARK: - DatabaseCipher class methods

    public static func deriveKey(password: String, salt: Data, iterations: UInt32) -> SymmetricKey {
        var derived = Data(repeating: 0, count: 32)
        let pw = Data(password.utf8)
        var derivationStatus = OSStatus(kCCSuccess)
        derived.withUnsafeMutableBytes { derivedPtr in
            salt.withUnsafeBytes { saltPtr in
                pw.withUnsafeBytes { pwPtr in
                    derivationStatus = CCKeyDerivationPBKDF(                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pwPtr.bindMemory(to: Int8.self).baseAddress, pw.count,
                        saltPtr.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        iterations,
                        derivedPtr.bindMemory(to: UInt8.self).baseAddress, 32
                    )
                }
            }
        }
        // 派生失败时零值密钥会在解封处被误报成「密码错误」,此处留排查线索
        // (不改变控制流:与历史行为一致继续返回 derived)
        if derivationStatus != kCCSuccess {
            Log.error("cipher", "pbkdf2 failed (OSStatus \(derivationStatus)) iterations=\(iterations)")
        }
        return SymmetricKey(data: derived)
    }
}

// MARK: - 容器布局
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

    // 信封字节布局常量(与上方布局图、Contracts 镜像、TS 端 vault-crypto 对齐)
    private static let envelopeIterationsOffset = 12
    private static let envelopeSaltOffset = 16
    private static let envelopeWrappedKeyOffset = 32
    private static let envelopeChangedAtOffset = 92
    private static let envelopeMinLength = 100

    /// 生成随机 256 位库密钥(每库一个;改密时由会话层轮换)。
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
        guard data.count >= envelopeChangedAtOffset, data.prefix(keyMagic.count) == keyMagic else {
            throw CipherError(message: "not a key envelope")
        }
        let iters = data.subdata(in: envelopeIterationsOffset..<(envelopeIterationsOffset + 4))
            .withUnsafeBytes { UInt32(littleEndian: $0.load(as: UInt32.self)) }
        guard iters >= Self.minimumEnvelopeIterations, iters <= Self.maximumEnvelopeIterations else {
            Log.warn("cipher", "envelope rejected: iterations out of bounds")
            throw CipherError(message: "not a key envelope")
        }
        let salt = data.subdata(in: envelopeSaltOffset..<(envelopeSaltOffset + saltLength))
        let key = deriveKey(password: password, salt: salt, iterations: iters)
        do {
            let box = try AES.GCM.SealedBox(combined: data.subdata(in: envelopeWrappedKeyOffset..<envelopeChangedAtOffset))
            let rawKey = try AES.GCM.open(box, using: key)
            return SymmetricKey(data: rawKey)
        } catch {
            throw CipherError(message: L10n.t("wrong_password_error"))
        }
    }

    /// 信封里的改密时间戳(展示用;读取失败返回 nil)。
    public static func envelopeChangedAt(_ data: Data) -> Date? {
        guard data.count >= envelopeMinLength, data.prefix(keyMagic.count) == keyMagic else { return nil }
        let bits = data.subdata(in: envelopeChangedAtOffset..<envelopeMinLength)
            .withUnsafeBytes { $0.load(as: UInt64.self) }
        return Date(timeIntervalSince1970: TimeInterval(bitPattern: UInt64(littleEndian: bits)))
    }
}
