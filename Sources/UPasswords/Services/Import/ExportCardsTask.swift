import Foundation

// MARK: - Export

/// 导出格式;name 走 Localizable `*_format_text`。
enum ExportFormat: String, CaseIterable, Identifiable {
    case xml, csv, txt
    var id: String { rawValue }
    var name: String { L10n.t("\(rawValue)_format_text") }
}

/// 导出任务:卡片集 → 指定格式文本。
enum ExportCardsTask {
    /// - Parameters:
    ///   - cards: 待导出卡片(顺序保留)
    ///   - labels: 标签表(xml 格式需要)
    ///   - format: 目标格式;仅 xml 可重新导入
    /// - Returns: 导出文本;xml 序列化失败时返回空串
    static func export(_ cards: [Card], labels: [CardLabel], format: ExportFormat) -> String {
        switch format {
        case .xml:
            var db = PasswordDatabase()
            db.labels = labels
            db.cards = cards
            return String(data: db.xmlData(), encoding: .utf8) ?? ""
        case .csv:
            var rows = [["title", "login", "password", "website", "notes"]]
            for c in cards {
                rows.append([c.title, c.login, c.password, c.website, c.notes])
            }
            return rows.map { $0.map(CSV.escape).joined(separator: ",") }.joined(separator: "\n")
        case .txt:
            return cards.map { $0.asPlainText() }.joined(separator: "\n\n" + String(repeating: "—", count: 30) + "\n\n")
        }
    }
}
