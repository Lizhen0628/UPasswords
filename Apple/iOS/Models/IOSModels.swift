import Foundation

import UPasswordsCore

// MARK: - iOS 侧模型适配(SortOrder / 模板分组 / Card 派生标记)

/// 拼音首字母分组键(A…Z / #)。
func pinyinInitial(_ s: String) -> String {
    guard let first = s.first else { return "#" }
    let m = NSMutableString(string: String(first))
    CFStringTransform(m as CFMutableString, nil, kCFStringTransformToLatin, false)
    CFStringTransform(m as CFMutableString, nil, kCFStringTransformStripDiacritics, false)
    let latin = m.uppercased
    if let c = latin.first, c >= "A", c <= "Z" { return String(c) }
    return "#"
}

/// 排序方式(列表页 8 种),仅在 iOS 端使用。
enum SortOrder: Int, CaseIterable, Identifiable {
    case titleAsc, titleDesc, modifiedDesc, modifiedAsc, createdDesc, createdAsc, sizeDesc, sizeAsc
    var id: Int { rawValue }
    var name: String {
        switch self {
        case .titleAsc: return L10n.t("ios_sort_title_asc")
        case .titleDesc: return L10n.t("ios_sort_title_desc")
        case .modifiedDesc: return L10n.t("ios_sort_modified_desc")
        case .modifiedAsc: return L10n.t("ios_sort_modified_asc")
        case .createdDesc: return L10n.t("ios_sort_created_desc")
        case .createdAsc: return L10n.t("ios_sort_created_asc")
        case .sizeDesc: return L10n.t("ios_sort_size_desc")
        case .sizeAsc: return L10n.t("ios_sort_size_asc")
        }
    }
    func sorted(_ cards: [Card]) -> [Card] {
        switch self {
        case .titleAsc: return cards.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
        case .titleDesc: return cards.sorted { $0.title.localizedCompare($1.title) == .orderedDescending }
        case .modifiedDesc: return cards.sorted { $0.modified > $1.modified }
        case .modifiedAsc: return cards.sorted { $0.modified < $1.modified }
        case .createdDesc: return cards.sorted { $0.created > $1.created }
        case .createdAsc: return cards.sorted { $0.created < $1.created }
        case .sizeDesc: return cards.sorted { $0.size > $1.size }
        case .sizeAsc: return cards.sorted { $0.size < $1.size }
        }
    }
}

// MARK: - Card 的 iOS 派生标记

/// 导航值语义:按 id 哈希(SwiftUI navigationDestination 需 Hashable;
/// 相等性沿用 Core 的全字段 ==,不影响)。
extension Card: Hashable {
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension Card {
    var otpField: Field? { fields.first { $0.type.isOneTimePassword } }

    /// 通行密钥条目:包含名为「通行密钥」的机密字段(按本地化名匹配)。
    var hasPasskey: Bool {
        let passkeyName = L10n.t("ios_passkey_field_name")
        return fields.contains { $0.type == .secret && $0.name == passkeyName }
    }
}

// MARK: - 模板展示适配(Core Templates 是字符串键名制,此处补 UI 分组与配色)

enum TemplateGroups {
    struct Item: Identifiable {
        let id: Int
        let title: String
        let symbol: String?
        let color: String
        let spec: Templates.Spec
    }

    /// 分组名沿用既有字符串表键,缺失时回退。
    static var groups: [(name: String, items: [Item])] {
        func pick(_ ids: [Int]) -> [Item] { ids.compactMap { item(id: $0) } }
        return [
            (L10n.t("ios_template_group_common"), pick([102, 103, 104, 100, 120])),
            (L10n.t("ios_template_group_finance"), pick([101, 108, 107, 106])),
            (L10n.t("ios_template_group_identity"), pick([105, 109, 110])),
            (L10n.t("ios_template_group_network"), pick([111, 112, 113])),
            (L10n.t("ios_template_group_other"), pick([114])),
        ]
    }

    static func item(id: Int) -> Item? {
        guard let spec = Templates.spec(id: id) else { return nil }
        return Item(id: spec.id, title: L10n.db(spec.titleKey), symbol: displaySymbol(spec),
                    color: color(for: spec), spec: spec)
    }

    /// Core 的 symbol 词表与 iOS 展示词表个别不一致,此处做展示映射。
    private static func displaySymbol(_ spec: Templates.Spec) -> String? {
        switch spec.symbol {
        case "web_site": return "globe"
        case "email": return "envelope"
        case "code": return "lock"
        case "id": return "person.text.rectangle"
        case "insurance": return "umbrella"
        default: return spec.symbol
        }
    }

    private static func color(for spec: Templates.Spec) -> String {
        switch spec.id {
        case 102, 103: return "blue"
        case 104, 100, 114: return "gray"
        case 120: return "green"
        case 101, 108: return "purple"
        case 107, 106: return "teal"
        case 105, 109, 110: return "yellow"
        case 111, 112: return "green"
        case 113: return "red"
        default: return "gray"
        }
    }

    /// 内置模板 id 集合(用于区分"我的模板"与内置模板卡)。
    static let builtInTemplateIds = Set(Templates.all.map(\.id))
}
