import Foundation
import CryptoKit

/// RFC 6238 TOTP for `one_time_password` fields.
/// Accepts a bare base32 secret or a full `otpauth://` URI
/// (secret / digits / period / algorithm / issuer).
enum TOTP {
    struct Config: Equatable {
        var secret: [UInt8]
        var digits: Int = 6
        var period: Int = 30
        var algorithm: String = "SHA1"
        var issuer: String? = nil
        var account: String? = nil
    }

    enum TOTPError: LocalizedError {
        case invalidSecret
        case unsupportedAlgorithm
        var errorDescription: String? { L10n.t("invalid_value_text") }
    }

    static func base32Decode(_ s: String) throws -> [UInt8] {
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
    static func parse(_ raw: String) throws -> Config {
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
                case "digits": cfg.digits = Int(item.value ?? "6") ?? 6
                case "period": cfg.period = Int(item.value ?? "30") ?? 30
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

    /// RFC 6238 test vectors use 8 digits; UI uses the field's configured digits.
    static func code(config: Config, at date: Date = Date()) throws -> String {
        let counter = UInt64(date.timeIntervalSince1970 / Double(config.period))
        return try hotp(config: config, counter: counter)
    }

    static func hotp(config: Config, counter: UInt64) throws -> String {
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
    static func remainingSeconds(period: Int, at date: Date = Date()) -> Int {
        period - Int(date.timeIntervalSince1970) % period
    }
}
