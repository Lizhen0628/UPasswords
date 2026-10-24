import Foundation

// MARK: - 条目级编解码与行级同步基元
//
// 行级同步的条目体 = 单条目 XML 元素的 UTF-8 字节(服务端只见其 AES-GCM
// 密文)。本文件提供 Card/CardLabel/UserProfile 与元素字节的编解码,以及同步冲突的
// 逐条裁决(LWW:mtime 新者胜;标签按 timeStamp)。

/// 一个可同步条目(客户端 kind:1=card、2=label、3=user profile;部署端支持情况须与 Cloud 的迁移状态一并核对)。
public enum DatabaseItem: Equatable {
    case card(Card)
    case label(CardLabel)
    case userProfile(UserProfile)

    /// 条目的稳定 UUID，用于同步定位与 AES-GCM AAD 绑定。
    public var uuid: UUID {
        switch self {
        case .card(let c): return c.id
        case .label(let l): return l.id
        case .userProfile(let profile): return profile.id
        }
    }

    /// 行级同步的决胜时间，单位为 Unix 毫秒：卡片和资料用 modified，标签用 timeStamp。
    public var modifiedMs: TimeInterval {
        switch self {
        case .card(let c): return c.modified
        case .label(let l): return l.timeStamp
        case .userProfile(let profile): return profile.modified
        }
    }

    /// 同步类型码：1 为卡片、2 为标签、3 为个人资料；须与服务端和 TS 契约一致。
    public var syncKind: UInt8 {
        switch self {
        case .card: return 1
        case .label: return 2
        case .userProfile: return 3
        }
    }
}

/// 整库 XML 与同步行共用的条目编解码及冲突裁决入口。
public enum DatabaseItemCodec {

    /// 条目体序列化(单元素字节;卡内标签引用按 id 写出,名称查 `labelNames`)。
    ///
    /// - Parameters:
    ///   - item: 待编码的已解密条目值。
    ///   - labelNames: 卡片标签 UUID 到展示名的映射。
    /// - Returns: 单个 XML 元素的 UTF-8 字节，尚未加密。
    public static func xmlData(_ item: DatabaseItem, labelNames: [UUID: String] = [:]) -> Data {
        switch item {
        case .card(let c):
            return Data(PasswordDatabase.cardElement(c, labelNames: labelNames).utf8)
        case .label(let l):
            return Data(PasswordDatabase.labelElement(l).utf8)
        case .userProfile(let profile):
            return Data(PasswordDatabase.userProfileElement(profile).utf8)
        }
    }

    /// 从 XML 字节中按 kind 选择首个卡片、标签或个人资料，并核对 UUID。
    ///
    /// 调用方应传入单元素片段；本方法不会额外拒绝含多个同类元素的文档。
    /// - Parameters:
    ///   - kind: 同步类型码，1 为卡片、2 为标签、3 为个人资料。
    ///   - uuid: 同步行声明的稳定身份。
    ///   - data: 已解密 XML 字节。
    /// - Returns: 解析失败或 uuid 不匹配返回 nil。
    public static func parse(kind: UInt8, uuid: UUID, data: Data) -> DatabaseItem? {
        let parser = DBXMLParser()
        let pp = XMLParser(data: data)
        pp.delegate = parser
        pp.shouldResolveExternalEntities = false
        guard pp.parse(), !parser.failed else { return nil }
        switch kind {
        case 1:
            guard let c = parser.cards.first, c.id == uuid else { return nil }
            return .card(c)
        case 2:
            guard let l = parser.labels.first, l.id == uuid else { return nil }
            return .label(l)
        case 3:
            guard let profile = parser.userProfiles.first, profile.id == uuid else { return nil }
            return .userProfile(profile)
        default:
            return nil
        }
    }

    /// 逐条冲突裁决(§6.2/§6.6):本地与对端同改一条目时,新者胜。
    /// 相等时间保留本地(避免刷新 nonce 制造对端误判)。
    ///
    /// - Parameters:
    ///   - local: 本地条目；调用方须保证与 remote 为同一身份。
    ///   - remote: 远端条目。
    /// - Returns: 按修改时间选出的完整条目，不逐字段合并。
    public static func resolve(local: DatabaseItem, remote: DatabaseItem) -> DatabaseItem {
        local.modifiedMs >= remote.modifiedMs ? local : remote
    }
}
