import Foundation
import UPasswordsCore

/// Shared CSV card extraction with header auto-detection
/// (column names probed case-insensitively).
public struct CSVImporter: ImportFormat {
    /// 此导入源的稳定格式标识。
    public let id: String
    /// 此导入源在格式选择器中的展示名称。
    public let title: String
    /// 此导入器建议的文件扩展名。
    public let fileExtension = "csv"
    /// required/optional column aliases → field slot
    public let columnMap: [String: [String]]
    /// 记录格式声明的 TSV 偏好；当前 CSV.rows 同时接受逗号与制表符。
    public let tabSeparated: Bool

    /// 创建基于表头别名映射的 CSV 导入器。
    ///
    /// - Parameters:
    ///   - id: 格式稳定标识。
    ///   - title: 展示名称。
    ///   - tabSeparated: 保留的格式偏好；当前解析器同时处理逗号和制表符。
    ///   - columnMap: name、login、password、url、notes 槽位对应的候选表头别名。
    public init(id: String, title: String, tabSeparated: Bool = false,
         columnMap: [String: [String]]) {
        self.id = id
        self.title = title
        self.columnMap = columnMap
        self.tabSeparated = tabSeparated
    }

    /// 通过此格式的表头或结构特征进行快速探测，完整错误由 parse 报告。
    public func canParse(_ text: String) -> Bool {
        guard let header = CSV.rows(text).first else { return false }
        let lower = header.map { $0.lowercased() }
        return columnMap.values.contains { aliases in aliases.contains { lower.contains($0) } }
    }

    private func index(of aliases: [String], in header: [String]) -> Int? {
        let lower = header.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        for a in aliases {
            if let i = lower.firstIndex(of: a) { return i }
        }
        // prefix match fallback (e.g. "url" matches "url_login")
        for a in aliases {
            if let i = lower.firstIndex(where: { $0.hasPrefix(a) }) { return i }
        }
        return nil
    }

    /// 按此格式的字段映射将记录导入工作副本；参数与错误约定见 ImportFormat。
    public func parse(_ text: String, into db: inout PasswordDatabase, now: Date) throws -> Int {
        var rows = CSV.rows(text)
        guard rows.count >= 2 else { throw ImportError.cannotParse }
        let header = rows.removeFirst()
        guard let nameIdx = index(of: columnMap["name"] ?? [], in: header) else { throw ImportError.cannotParse }
        let loginIdx = index(of: columnMap["login"] ?? [], in: header)
        let pwIdx = index(of: columnMap["password"] ?? [], in: header)
        let urlIdx = index(of: columnMap["url"] ?? [], in: header)
        let noteIdx = index(of: columnMap["notes"] ?? [], in: header)

        var count = 0
        for row in rows {
            func col(_ i: Int?) -> String { i.map { $0 < row.count ? row[$0] : "" } ?? "" }
            if col(nameIdx).isEmpty && col(loginIdx).isEmpty && col(pwIdx).isEmpty { continue }
            var card = Card()
            card.title = col(nameIdx).isEmpty ? (col(loginIdx).isEmpty ? "—" : col(loginIdx)) : col(nameIdx)
            card.symbol = "key"
            card.color = "gray"
            card.created = now.millis
            card.modified = now.millis
            if !col(loginIdx).isEmpty { card.fields.append(Field(name: L10n.db("login_field"), type: .login, value: col(loginIdx), autofill: .username)) }
            if !col(pwIdx).isEmpty { card.fields.append(Field(name: L10n.db("password_field"), type: .password, value: col(pwIdx), autofill: .currentPassword)) }
            if !col(urlIdx).isEmpty { card.fields.append(Field(name: L10n.db("url_field"), type: .website, value: col(urlIdx), autofill: .url)) }
            if !col(noteIdx).isEmpty { card.notes = col(noteIdx) }
            db.cards.append(card)
            count += 1
        }
        return count
    }
}
