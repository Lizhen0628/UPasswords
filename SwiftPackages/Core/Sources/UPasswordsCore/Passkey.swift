import Foundation

// MARK: - 通行密钥凭据模型

/// 卡片上保存的 WebAuthn 通行密钥凭据(iOS 自动填充扩展用它完成断言/注册)。
/// 以 JSON 存进类型 .secret、名为 `Card.passkeyFieldName` 的字段:数据库结构不变,
/// 旧版本 App 只看到一个普通私密字段;整库加密,私钥不出库。
public struct Passkey: Codable, Equatable, Sendable {
    public init(credentialID: Data, relyingParty: String, userHandle: Data,
                userName: String, privateKey: Data, signCount: UInt32, created: TimeInterval) {
        self.credentialID = credentialID
        self.relyingParty = relyingParty
        self.userHandle = userHandle
        self.userName = userName
        self.privateKey = privateKey
        self.signCount = signCount
        self.created = created
    }

    /// WebAuthn credentialID(注册时生成的随机字节)。
    public var credentialID: Data
    /// RP ID(如 "github.com"),断言/注册匹配用它,精确相等。
    public var relyingParty: String
    public var userHandle: Data
    public var userName: String
    /// CryptoKit P-256 私钥 rawRepresentation。
    public var privateKey: Data
    /// 签名计数器:每次断言 +1 并写回(供 RP 做克隆检测)。
    public var signCount: UInt32
    /// 创建时间(毫秒,与 Card 时间戳一致)。
    public var created: TimeInterval
}

extension Card {
    /// 通行密钥凭据的固定机读字段名(不随语言变化,勿本地化)。
    public static let passkeyFieldName = "passkey"

    /// 解析卡片上的通行密钥凭据;无凭据或数据损坏返回 nil。
    public var passkey: Passkey? {
        guard let field = fields.first(where: { $0.type == .secret && $0.name == Card.passkeyFieldName }),
              let data = field.value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Passkey.self, from: data)
    }

    /// 写入/更新卡片上的通行密钥凭据(JSON 存进固定字段)。
    public mutating func setPasskey(_ passkey: Passkey) {
        guard let data = try? JSONEncoder().encode(passkey),
              let json = String(data: data, encoding: .utf8) else { return }
        if let i = fields.firstIndex(where: { $0.type == .secret && $0.name == Card.passkeyFieldName }) {
            fields[i].value = json
        } else {
            fields.append(Field(name: Card.passkeyFieldName, type: .secret, value: json))
        }
    }
}
