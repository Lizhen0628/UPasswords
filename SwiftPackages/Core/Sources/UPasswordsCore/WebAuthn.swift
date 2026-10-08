import CryptoKit
import Foundation

// MARK: - WebAuthn 报文构造

/// WebAuthn 断言/注册报文构造(attestation 固定 "none",签名算法固定 ES256)。
/// 参考:WebAuthn Level 2 §6.1 authenticatorData、§6.5 attestationObject。
public enum WebAuthn {

    public enum WebAuthnError: LocalizedError {
        case invalidPrivateKey
        case invalidPublicKey

        public var errorDescription: String? { L10n.t("invalid_value_text") }
    }

    /// 生成新的 P-256 密钥对。
    /// - Returns: 私钥 rawRepresentation 与公钥 x963(04‖X‖Y,65 字节)。
    public static func generateKeyPair() -> (privateKey: Data, publicKeyX963: Data) {
        let key = P256.Signing.PrivateKey()
        return (key.rawRepresentation, key.publicKey.x963Representation)
    }

    /// 随机 credentialID(32 字节,SystemRandomNumberGenerator 加密安全)。
    public static func makeCredentialID() -> Data {
        Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
    }

    /// authenticatorData = rpIDHash ‖ flags ‖ signCount(4B BE) [‖ attestedCredentialData]。
    /// - Parameters:
    ///   - userVerified: 置 UV 位(扩展内完成解锁即视为已用户验证)
    ///   - attestedCredentialData: 注册时附带(同时置 AT 位)
    public static func authenticatorData(relyingParty: String, userVerified: Bool,
                                         signCount: UInt32,
                                         attestedCredentialData: Data? = nil) -> Data {
        var data = Data(SHA256.hash(data: Data(relyingParty.utf8)))
        var flags: UInt8 = 0x01 // UP(用户在场)
        if userVerified { flags |= 0x04 }
        if attestedCredentialData != nil { flags |= 0x40 }
        data.append(flags)
        data.append(contentsOf: signCount.bigEndianBytes)
        if let attestedCredentialData { data.append(attestedCredentialData) }
        return data
    }

    /// attestedCredentialData = AAGUID(16B 零) ‖ credIDLen(2B BE) ‖ credentialID ‖ COSE 公钥。
    /// AAGUID 全零表示无认证器型号(attestation "none" 配套)。
    public static func attestedCredentialData(credentialID: Data, publicKeyX963: Data) throws -> Data {
        var data = Data(count: 16)
        data.append(contentsOf: UInt16(credentialID.count).bigEndianBytes)
        data.append(credentialID)
        data.append(try cosePublicKey(x963: publicKeyX963))
        return data
    }

    /// attestationObject = CBOR { "fmt": "none", "attStmt": {}, "authData": <bytes> }。
    public static func attestationObject(authData: Data) -> Data {
        CBOR.encode(.map([
            (.text("fmt"), .text("none")),
            (.text("attStmt"), .map([])),
            (.text("authData"), .bytes(authData)),
        ]))
    }

    /// 断言签名:ES256(authData ‖ clientDataHash),返回 DER 编码签名。
    /// - Throws: `WebAuthnError.invalidPrivateKey` 私钥数据损坏或签名失败。
    public static func assertionSignature(privateKeyRaw: Data, authData: Data,
                                          clientDataHash: Data) throws -> Data {
        guard let key = try? P256.Signing.PrivateKey(rawRepresentation: privateKeyRaw) else {
            throw WebAuthnError.invalidPrivateKey
        }
        var message = authData
        message.append(clientDataHash)
        guard let signature = try? key.signature(for: message) else {
            throw WebAuthnError.invalidPrivateKey
        }
        return signature.derRepresentation
    }

    /// 65 字节未压缩公钥(04‖X‖Y) → COSE_Key(CBOR):
    /// { 1: 2(EC2), 3: -7(ES256), -1: 1(P-256), -2: X, -3: Y }。
    static func cosePublicKey(x963: Data) throws -> Data {
        guard x963.count == 65, x963.first == 0x04 else { throw WebAuthnError.invalidPublicKey }
        let x = x963.subdata(in: 1..<33)
        let y = x963.subdata(in: 33..<65)
        return CBOR.encode(.map([
            (.unsigned(1), .unsigned(2)),
            (.unsigned(3), .negative(6)),
            (.negative(0), .unsigned(1)),
            (.negative(1), .bytes(x)),
            (.negative(2), .bytes(y)),
        ]))
    }
}

// MARK: - 定长 CBOR 编码器(仅 WebAuthn 需要的子集)

enum CBOR {
    indirect enum Value {
        case unsigned(UInt64)
        /// 负数的编码参数 n,实际值为 -(1+n):如 .negative(6) 即 -7。
        case negative(UInt64)
        case bytes(Data)
        case text(String)
        case map([(Value, Value)])
    }

    static func encode(_ value: Value) -> Data {
        switch value {
        case .unsigned(let v): return head(major: 0, value: v)
        case .negative(let n): return head(major: 1, value: n)
        case .bytes(let d):
            var out = head(major: 2, value: UInt64(d.count))
            out.append(d)
            return out
        case .text(let s):
            let utf8 = Data(s.utf8)
            var out = head(major: 3, value: UInt64(utf8.count))
            out.append(utf8)
            return out
        case .map(let pairs):
            var out = head(major: 5, value: UInt64(pairs.count))
            for (key, value) in pairs {
                out.append(encode(key))
                out.append(encode(value))
            }
            return out
        }
    }

    private static func head(major: UInt8, value: UInt64) -> Data {
        let m = major << 5
        switch value {
        case 0..<24: return Data([m | UInt8(value)])
        case 0..<256: return Data([m | 24, UInt8(value)])
        case 0..<65536: return Data([m | 25]) + UInt16(value).bigEndianBytes
        default: return Data([m | 26]) + UInt32(value).bigEndianBytes
        }
    }
}

// MARK: - 大端字节助手(WebAuthn 整数一律大端)

extension UInt16 {
    var bigEndianBytes: [UInt8] {
        [UInt8((self >> 8) & 0xFF), UInt8(self & 0xFF)]
    }
}

extension UInt32 {
    var bigEndianBytes: [UInt8] {
        [UInt8((self >> 24) & 0xFF), UInt8((self >> 16) & 0xFF),
         UInt8((self >> 8) & 0xFF), UInt8(self & 0xFF)]
    }
}
