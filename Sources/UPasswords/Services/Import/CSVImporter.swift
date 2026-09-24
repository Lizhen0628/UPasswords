import Foundation

/// Shared CSV card extraction with header auto-detection
/// (column names probed case-insensitively).
struct CSVImporter: ImportFormat {
    let id: String
    let title: String
    let fileExtension = "csv"
    /// required/optional column aliases → field slot
    let columnMap: [String: [String]]
    let tabSeparated: Bool

    init(id: String, title: String, tabSeparated: Bool = false,
         columnMap: [String: [String]]) {
        self.id = id
        self.title = title
        self.columnMap = columnMap
        self.tabSeparated = tabSeparated
    }

    func canParse(_ text: String) -> Bool {
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

    func parse(_ text: String, into db: inout PasswordDatabase, now: Date) throws -> Int {
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
            var card = Card(id: db.nextItemId())
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
