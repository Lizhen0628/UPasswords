import Foundation
import CryptoKit
import CommonCrypto

/// Encrypted database vault: v2 envelope cipher (dual-key) only.
///
/// 主密码(可改)只加密一个 32 字节随机「库密钥」(vault key);库密钥加密
/// 数据库本体。改主密码由会话层编排:轮换库密钥并重加密本体 + 重写信封
/// (<名>.upwkey),新本体只能由新库密钥解开;旧文件副本仍可用旧密码读取。
/// 他端凭注册表信封收敛，输入新密码解开信封后重建本地库。
public enum DatabaseCipher {
    /// 信封格式版本号
    public static let version: UInt32 = 1
    /// 主密码 PBKDF2 派生盐长度，单位为字节。
    public static let saltLength = 16
    /// 新信封迭代数(OWASP 2023+ 档位;存量 310k 信封仍按文件头值读取)
    public static let iterations: UInt32 = 600_000
    /// 信封迭代下限:低于此值视为恶意/损坏文件,拒绝解(格式错误,非密码错误)
    public static let minimumEnvelopeIterations: UInt32 = 100_000
    /// 迭代上限(与 TS 端 vault-crypto 对齐):伪造 40 亿次迭代的信封
    /// 会把解密端 UI 冻结 1-2 小时
    public static let maximumEnvelopeIterations: UInt32 = 10_000_000

    /// 加密容器读取、密钥验证或加密输出失败的错误。
    public struct CipherError: LocalizedError {
        /// 向调用方传播的错误描述；不得包含密码或密钥。
        public let message: String
        /// 创建不携带密码或密钥的加密错误描述。
        ///
        /// - Parameter message: 可向调用方展示的错误消息。
        public init(message: String) { self.message = message }
        /// 向 LocalizedError 调用方提供的错误消息。
        public var errorDescription: String? { message }
    }

    // MARK: - DatabaseCipher class methods

    /// 通过 PBKDF2-HMAC-SHA256 从主密码派生 256 位密钥。
    ///
    /// 该同步调用执行成本较高，调用方应避免在逐键输入路径反复调用。
    /// - Parameters:
    ///   - password: UTF-8 编码的主密码，不作额外规范化。
    ///   - salt: 派生盐；信封格式使用 16 字节随机盐。
    ///   - iterations: PBKDF2 迭代次数；读取不可信信封须先校验上下限。
    /// - Returns: 派生密钥；底层派生失败时沿用现有行为记录错误并返回缓冲区内容。
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
    /// 数据库本体容器的 8 字节魔数。
    public static let magicV2 = Data("UPWDB2\0\0".utf8)
    /// 库密钥信封的 8 字节魔数。
    public static let keyMagic = Data("UPWKEY1\0".utf8)
    /// 数据库本体格式版本，与产品开发版本号无关。
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

    /// 检查最小头长度与数据库本体魔数。
    ///
    /// - Parameter data: 待检查的容器字节。
    /// - Returns: 是否符合头部初筛；此结果不证明密文认证、版本或内容有效。
    public static func isV2Container(_ data: Data) -> Bool {
        data.count >= v2HeaderLength && data.prefix(magicV2.count) == magicV2
    }

    /// 使用随机 nonce 和库密钥生成带 v2 头部的 AES-GCM 容器。
    ///
    /// - Parameters:
    ///   - plaintext: 数据库 XML 的 UTF-8 字节；不得记录到日志。
    ///   - vaultKey: 当前会话的库密钥。
    /// - Returns: 固定头部与 nonce、密文、认证标签组成的完整容器。
    /// - Throws: AES-GCM 加密或组合表示生成失败。
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

    /// 校验容器魔数和最小长度后，用库密钥认证并解密本体。
    ///
    /// - Parameters:
    ///   - data: 完整 v2 本体容器。
    ///   - vaultKey: 从配套信封解出的库密钥。
    /// - Returns: 已认证的明文字节；XML 解析由调用方完成。
    /// - Throws: 容器头部不符合初筛，或密封盒损坏、认证失败。
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

    /// 使用主密码派生密钥包裹库密钥，写出独立信封。
    ///
    /// - Parameters:
    ///   - vaultKey: 被包裹的 256 位库密钥。
    ///   - password: 用于 PBKDF2 派生的主密码。
    ///   - changedAt: 创建或改密时间，按 Unix 秒数写入，供界面提示。
    /// - Returns: 含随机盐、迭代次数、密封库密钥和时间的信封字节。
    /// - Throws: AES-GCM 加密或组合表示生成失败。
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

    /// 检查信封长度、魔数及迭代次数后，用主密码解出库密钥。
    ///
    /// - Parameters:
    ///   - data: 信封字节；兼容不含尾部 changedAt 的旧信封。
    ///   - password: 用户提供的主密码。
    /// - Returns: 解封后的库密钥，不解密数据库本体。
    /// - Throws: 头部或迭代次数非法时抛格式错误；密封盒或认证失败时抛密码错误。
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
