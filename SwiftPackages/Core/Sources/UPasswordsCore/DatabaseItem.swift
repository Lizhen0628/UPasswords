import Foundation

// MARK: - 条目级编解码(v7 行级同步基元)
//
// 行级同步的条目体 = 单条目 XML 元素的 UTF-8 字节(服务端只见其 AES-GCM
// 密文)。本文件提供 Card/CardLabel ↔ 元素字节的编解码,以及同步冲突的
// 逐条裁决(LWW:mtime 新者胜;标签按 timeStamp)。

/// 一个可同步条目(与 MariaDB `vault_items.kind` 对应:1=card 2=label)。
public enum DatabaseItem: Equatable {
    case card(Card)
    case label(CardLabel)

    public var uuid: UUID {
        switch self {
        case .card(let c): return c.id
        case .label(let l): return l.id
        }
    }

    /// 行级同步的决胜时间:卡片用 modified,标签用 timeStamp。
    public var modifiedMs: TimeInterval {
        switch self {
        case .card(let c): return c.modified
        case .label(let l): return l.timeStamp
        }
    }

    /// 服务端 kind 值(与 worker 契约一致)。
    public var syncKind: UInt8 {
        switch self {
        case .card: return 1
        case .label: return 2
        }
    }
}

public enum DatabaseItemCodec {

    /// 条目体序列化(单元素字节;卡内标签引用按 id 写出,名称查 `labelNames`)。
    public static func xmlData(_ item: DatabaseItem, labelNames: [UUID: String] = [:]) -> Data {
        switch item {
        case .card(let c):
            return Data(PasswordDatabase.cardElement(c, labelNames: labelNames).utf8)
        case .label(let l):
            return Data(PasswordDatabase.labelElement(l).utf8)
        }
    }

    /// 条目体解析:接受单元素片段(`<card …/>` 或 `<label …/>`)。
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
        default:
            return nil
        }
    }

    /// 逐条冲突裁决(§6.2/§6.6):本地与对端同改一条目时,新者胜。
    /// 相等时间保留本地(避免刷新 nonce 制造对端误判)。
    public static func resolve(local: DatabaseItem, remote: DatabaseItem) -> DatabaseItem {
        local.modifiedMs >= remote.modifiedMs ? local : remote
    }
}
