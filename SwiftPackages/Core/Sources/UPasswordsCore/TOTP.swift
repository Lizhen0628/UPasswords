import Foundation
import CryptoKit

/// RFC 6238 TOTP for `one_time_password` fields.
/// Accepts a bare base32 secret or a full `otpauth://` URI
/// (secret / digits / period / algorithm / issuer).
public enum TOTP {
    /// 一次性密码生成配置；调用方直接构造时负责保证位数和周期有效。
    public struct Config: Equatable {
        /// Base32 解码后的共享密钥字节，不得进入日志。
        public var secret: [UInt8]
        /// 验证码位数；直接构造配置时调用方须保证在 6 至 8 范围内。
        public var digits: Int = 6
        /// 时间步长，单位为秒；直接构造配置时必须大于 0。
        public var period: Int = 30
        /// HMAC 算法名称，支持 SHA1、SHA256、SHA512。
        public var algorithm: String = "SHA1"
        /// 可选的凭据发行方描述。
        public var issuer: String? = nil
        /// 可选的账户描述；当前 URI 解析器不从路径填充此字段。
        public var account: String? = nil
    }

    /// RFC 6238 位数与周期的合法区间:URI 里的越界值(会令取模/除零 trap)
    /// 一律回退默认,杜绝畸形 otpauth:// 崩溃进程。
    private static let allowedDigits = 6...8
    private static let defaultDigits = 6
    private static let defaultPeriod = 30

    /// 密钥缺失或 HMAC 算法不受支持的配置错误。
    public enum TOTPError: LocalizedError {
        case invalidSecret
        case unsupportedAlgorithm
        /// 供用户界面展示的本地化配置错误。
        public var errorDescription: String? { L10n.t("invalid_value_text") }
    }

    /// 宽松解码 Base32 文本，跳过填充符和字母表外字符。
    ///
    /// - Parameter s: 不区分大小写的 Base32 文本。
    /// - Returns: 解码字节；没有有效字符时为空数组。
    /// - Throws: 当前实现不主动抛错，保留 throws 供既有调用接口使用。
    public static func base32Decode(_ s: String) throws -> [UInt8] {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bits = 0
        var value = 0
        var out: [UInt8] = []
        for ch in s.uppercased() {
            guard let index = alphabet.firstIndex(of: ch) else { continue } // 跳过 '=' 等非字母表字符
            value = (value << 5) | index
            bits += 5
            if bits >= 8 {
                out.append(UInt8((value >> (bits - 8)) & 0xFF))
                bits -= 8
            }
        }
        return out
    }

    /// Parses a raw field value: bare base32 secret or otpauth:// URI.
    public static func parse(_ raw: String) throws -> Config {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TOTPError.invalidSecret }
        if trimmed.lowercased().hasPrefix("otpauth://") {
            guard let url = URL(string: trimmed) else { throw TOTPError.invalidSecret }
            var cfg = Config(secret: [])
            if let host = url.host, !host.isEmpty { cfg.issuer = host }
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            for item in comps?.queryItems ?? [] {
                switch item.name.lowercased() {
                case "secret":
                    if let v = item.value, let dec = try? base32Decode(v), !dec.isEmpty {
                        cfg.secret = dec
                    }
                case "digits": cfg.digits = clampedDigits(Int(item.value ?? "") ?? defaultDigits)
                case "period":
                    let parsed = Int(item.value ?? "") ?? defaultPeriod
                    cfg.period = max(parsed, 1)
                case "algorithm": cfg.algorithm = (item.value ?? "SHA1").uppercased()
                case "issuer": cfg.issuer = item.value
                default: break
                }
            }
            if cfg.secret.isEmpty { throw TOTPError.invalidSecret }
            return cfg
        }
        return Config(secret: try base32Decode(trimmed))
    }

    /// 越界位数回退默认(digits ≥ 19 会令 10^digits 溢出,≤ 0 无意义)。
    private static func clampedDigits(_ value: Int) -> Int {
        allowedDigits.contains(value) ? value : defaultDigits
    }

    /// RFC 6238 test vectors use 8 digits; UI uses the field's configured digits.
    public static func code(config: Config, at date: Date = Date()) throws -> String {
        let counter = UInt64(date.timeIntervalSince1970 / Double(config.period))
        return try hotp(config: config, counter: counter)
    }

    /// 按 RFC 4226 对计数器进行 HMAC 和动态截断。
    ///
    /// - Parameters:
    ///   - config: 位数为 6 至 8、算法受支持的密钥配置。
    ///   - counter: 无符号计数器，按 8 字节大端形式参与 HMAC。
    /// - Returns: 保留前导零的验证码字符串。
    /// - Throws: 算法名称不受支持时抛出 TOTPError.unsupportedAlgorithm。
    public static func hotp(config: Config, counter: UInt64) throws -> String {
        var msg = [UInt8](repeating: 0, count: 8)
        for i in 0..<8 { msg[i] = UInt8((counter >> (56 - 8 * UInt64(i))) & 0xFF) }
        let digest: [UInt8]
        switch config.algorithm {
        case "SHA1": digest = Array(HMAC<Insecure.SHA1>.authenticationCode(for: msg, using: SymmetricKey(data: Data(config.secret))).makeIterator())
        case "SHA256": digest = Array(HMAC<SHA256>.authenticationCode(for: msg, using: SymmetricKey(data: Data(config.secret))).makeIterator())
        case "SHA512": digest = Array(HMAC<SHA512>.authenticationCode(for: msg, using: SymmetricKey(data: Data(config.secret))).makeIterator())
        default: throw TOTPError.unsupportedAlgorithm
        }
        let offset = Int(digest[digest.count - 1] & 0x0F)
        var bin = 0
        for i in 0..<4 { bin = (bin << 8) | Int(digest[offset + i]) }
        bin &= 0x7FFFFFFF
        let mod = Int(pow(10, Double(config.digits)))
        let code = bin % mod
        return String(format: "%0\(config.digits)d", code)
    }

    /// Seconds until the current code rolls over.
    public static func remainingSeconds(period: Int, at date: Date = Date()) -> Int {
        period - Int(date.timeIntervalSince1970) % period
    }
}
