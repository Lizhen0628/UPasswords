import Foundation

/// Mirrors `ImportFormat` / `ImportFormatFactory` (App/Import/ImportFormat.h):
/// a pluggable family of competitor password-manager importers. Each format
/// converts raw text into `[Card]`.
protocol ImportFormat {
    var id: String { get }
    var title: String { get }
    var fileExtension: String { get }
    func canParse(_ text: String) -> Bool
    func parse(_ text: String, into db: inout PasswordDatabase, now: Date) throws -> Int
}

enum ImportError: LocalizedError {
    case cannotParse
    var errorDescription: String? { L10n.t("wrong_database_format_error") }
}

// MARK: - CSV engine (CsvFormat.h)

enum CSV {
    /// RFC 4180-ish parser supporting quotes and embedded separators.
    static func rows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var field = ""
        var row: [String] = []
        var inQuotes = false
        var i = text.startIndex
        let end = text.endIndex
        while i < end {
            let c = text[i]
            if inQuotes {
                if c == "\"" {
                    let next = text.index(after: i)
                    if next < end, text[next] == "\"" { field.append("\""); i = next }
                    else { inQuotes = false }
                } else {
                    field.append(c)
                }
            } else if c == "\"" {
                inQuotes = true
            } else if c == "," || c == "\t" {
                row.append(field); field = ""
            } else if c == "\n" {
                row.append(field); field = ""
                if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                row = []
            } else if c != "\r" {
                field.append(c)
            }
            i = text.index(after: i)
        }
        row.append(field)
        if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
        return rows
    }

    static func escape(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

/// Shared CSV card extraction with header auto-detection — the behavior of the
/// original `CsvFormat` (column names probed case-insensitively).
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

// MARK: - Concrete formats (ImportFormatFactory)

enum ImportFormatFactory {
    /// The import source catalog shown by ImportSourceViewController.
    static let all: [any ImportFormat] = [
        SafeInCloudXMLFormat(),
        ChromeFormat(browser: "Chrome"),
        ChromeFormat(browser: "Brave"),
        ChromeFormat(browser: "Edge"),
        ChromeFormat(browser: "Opera"),
        ChromeFormat(browser: "Firefox"),
        LastPassFormat(),
        BitwardenCsvFormat(),
        BitwardenJsonFormat(),
        DashlaneCsvFormat(),
        OnePasswordCsvFormat(),
        ApplePasswordsFormat(),
        NordPassFormat(),
        ProtonPassFormat(),
        KeePassFormat(),
        KeeperFormat(),
        RoboFormFormat(),
        CommonCsvFormat(),
    ]

    static func format(id: String) -> (any ImportFormat)? { all.first { $0.id == id } }
}

/// SafeInCloud XML (XmlFormat.h) — accepts full `<database>` docs or a bare
/// list of `<card>` elements.
struct SafeInCloudXMLFormat: ImportFormat {
    let id = "safeincloud-xml"
    let title = "XML (SafeInCloud)"
    let fileExtension = "xml"

    func canParse(_ text: String) -> Bool {
        text.contains("<database") || text.contains("<card")
    }

    func parse(_ text: String, into db: inout PasswordDatabase, now: Date) throws -> Int {
        let parsed = try PasswordDatabase.parse(Data(text.utf8))
        let existingIds = Set(db.cards.map(\.id))
        let existingTitles = Set(db.cards.filter { !$0.template }.map(\.title))
        var count = 0
        for c in parsed.cards where !c.template && !existingTitles.contains(c.title) {
            var card = c
            if existingIds.contains(card.id) { card.id = db.nextItemId() }
            db.cards.append(card)
            count += 1
        }
        return count
    }
}

struct ChromeFormat: ImportFormat {
    let browser: String
    var id: String { "chrome-\(browser.lowercased())" }
    var title: String { browser }
    let fileExtension = "csv"

    func canParse(_ text: String) -> Bool {
        text.lowercased().contains("name") && text.lowercased().contains("username")
    }

    func parse(_ text: String, into db: inout PasswordDatabase, now: Date) throws -> Int {
        let imp = CSVImporter(
            id: id, title: title,
            columnMap: [
                "name": ["name"], "login": ["username", "login", "login_username"],
                "password": ["password"], "url": ["url", "website", "origin_url"],
                "notes": ["note", "notes"],
            ]
        )
        return try imp.parse(text, into: &db, now: now)
    }
}

struct LastPassFormat: ImportFormat {
    let id = "lastpass"
    let title = "LastPass"
    let fileExtension = "csv"
    func canParse(_ text: String) -> Bool { text.lowercased().contains("url") && text.lowercased().contains("username") }
    func parse(_ text: String, into db: inout PasswordDatabase, now: Date) throws -> Int {
        let imp = CSVImporter(id: id, title: title, columnMap: [
            "name": ["name"], "login": ["username"], "password": ["password"],
            "url": ["url"], "notes": ["extra", "notes"],
        ])
        return try imp.parse(text, into: &db, now: now)
    }
}

struct BitwardenCsvFormat: ImportFormat {
    let id = "bitwarden-csv"
    let title = "Bitwarden (CSV)"
    let fileExtension = "csv"
    func canParse(_ text: String) -> Bool { text.lowercased().contains("login_uri") || text.lowercased().contains("folder") }
    func parse(_ text: String, into db: inout PasswordDatabase, now: Date) throws -> Int {
        var rows = CSV.rows(text)
        guard rows.count >= 2 else { throw ImportError.cannotParse }
        let header = rows.removeFirst().map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        func idx(_ aliases: [String]) -> Int? {
            for a in aliases { if let i = header.firstIndex(of: a) { return i } }
            return nil
        }
        let nIdx = idx(["name"]), uIdx = idx(["login_username", "username"]), pIdx = idx(["login_password", "password"])
        let urlIdx = idx(["login_uri", "uri"]), noteIdx = idx(["notes"]), folderIdx = idx(["folder"])
        var count = 0
        for row in rows {
            func col(_ i: Int?) -> String { i.map { $0 < row.count ? row[$0] : "" } ?? "" }
            if col(nIdx).isEmpty && col(uIdx).isEmpty { continue }
            var card = Card(id: db.nextItemId())
            card.title = col(nIdx).isEmpty ? col(uIdx) : col(nIdx)
            card.symbol = "key"; card.color = "gray"
            card.created = now.millis; card.modified = now.millis
            if !col(uIdx).isEmpty { card.fields.append(Field(name: L10n.db("login_field"), type: .login, value: col(uIdx), autofill: .username)) }
            if !col(pIdx).isEmpty { card.fields.append(Field(name: L10n.db("password_field"), type: .password, value: col(pIdx), autofill: .currentPassword)) }
            if !col(urlIdx).isEmpty { card.fields.append(Field(name: L10n.db("url_field"), type: .website, value: col(urlIdx), autofill: .url)) }
            if !col(noteIdx).isEmpty { card.notes = col(noteIdx) }
            let folder = col(folderIdx)
            if !folder.isEmpty {
                card.labelIds.append(Self.ensureLabel(named: folder, in: &db, now: now))
            }
            db.cards.append(card)
            count += 1
        }
        return count
    }

    static func ensureLabel(named name: String, in db: inout PasswordDatabase, now: Date) -> Int {
        if let l = db.labels.first(where: { $0.name == name }) { return l.id }
        let id = db.nextItemId()
        db.labels.append(CardLabel(id: id, name: name, timeStamp: now.millis))
        return id
    }
}

struct BitwardenJsonFormat: ImportFormat {
    let id = "bitwarden-json"
    let title = "Bitwarden (JSON)"
    let fileExtension = "json"
    func canParse(_ text: String) -> Bool { text.contains("\"items\"") || text.contains("\"vault\"") }
    func parse(_ text: String, into db: inout PasswordDatabase, now: Date) throws -> Int {
        guard let data = text.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ImportError.cannotParse }
        let items = (obj["items"] as? [[String: Any]]) ?? ((obj["vault"] as? [String: Any])?["items"] as? [[String: Any]]) ?? []
        let folders = (obj["folders"] as? [[String: Any]]) ?? []
        var folderNames: [String: String] = [:]
        for f in folders {
            if let id = f["id"] as? String, let name = f["name"] as? String { folderNames[id] = name }
        }
        var count = 0
        for item in items {
            guard let t = item["name"] as? String else { continue }
            let login = item["login"] as? [String: Any]
            var card = Card(id: db.nextItemId())
            card.title = t.isEmpty ? "—" : t
            card.symbol = "key"; card.color = "gray"
            card.created = now.millis; card.modified = now.millis
            if let u = login?["username"] as? String, !u.isEmpty {
                card.fields.append(Field(name: L10n.db("login_field"), type: .login, value: u, autofill: .username))
            }
            if let p = login?["password"] as? String, !p.isEmpty {
                card.fields.append(Field(name: L10n.db("password_field"), type: .password, value: p, autofill: .currentPassword))
            }
            if let uris = login?["uris"] as? [[String: Any]],
               let first = uris.first?["uri"] as? String, !first.isEmpty {
                card.fields.append(Field(name: L10n.db("url_field"), type: .website, value: first, autofill: .url))
            }
            if let totp = login?["totp"] as? String, !totp.isEmpty {
                card.fields.append(Field(name: L10n.db("one_time_password_field"), type: .oneTimePassword, value: totp, autofill: .oneTimeCode))
            }
            if let n = item["notes"] as? String, !n.isEmpty { card.notes = n }
            if let fid = item["folderId"] as? String, let fname = folderNames[fid] {
                card.labelIds.append(BitwardenCsvFormat.ensureLabel(named: fname, in: &db, now: now))
            }
            db.cards.append(card)
            count += 1
        }
        return count
    }
}

struct DashlaneCsvFormat: ImportFormat {
    let id = "dashlane-csv"
    let title = "Dashlane (CSV)"
    let fileExtension = "csv"
    func canParse(_ text: String) -> Bool { text.lowercased().contains("login") && text.lowercased().contains("password") }
    func parse(_ text: String, into db: inout PasswordDatabase, now: Date) throws -> Int {
        let imp = CSVImporter(id: id, title: title, columnMap: [
            "name": ["title", "name"], "login": ["login", "username", "email"],
            "password": ["password"], "url": ["url", "website"], "notes": ["note", "notes"],
        ])
        return try imp.parse(text, into: &db, now: now)
    }
}

struct OnePasswordCsvFormat: ImportFormat {
    let id = "1password-csv"
    let title = "1Password (CSV)"
    let fileExtension = "csv"
    func canParse(_ text: String) -> Bool { text.lowercased().contains("username") && text.lowercased().contains("password") }
    func parse(_ text: String, into db: inout PasswordDatabase, now: Date) throws -> Int {
        let imp = CSVImporter(id: id, title: title, columnMap: [
            "name": ["title", "name"], "login": ["username"], "password": ["password"],
            "url": ["url"], "notes": ["notes"],
        ])
        return try imp.parse(text, into: &db, now: now)
    }
}

struct ApplePasswordsFormat: ImportFormat {
    let id = "apple-passwords"
    let title = "Safari / Apple Passwords"
    let fileExtension = "csv"
    func canParse(_ text: String) -> Bool { text.lowercased().contains("username") }
    func parse(_ text: String, into db: inout PasswordDatabase, now: Date) throws -> Int {
        let imp = CSVImporter(id: id, title: title, columnMap: [
            "name": ["title"], "login": ["username"], "password": ["password"],
            "url": ["url"], "notes": ["notes"],
        ])
        return try imp.parse(text, into: &db, now: now)
    }
}

struct NordPassFormat: ImportFormat {
    let id = "nordpass"
    let title = "NordPass"
    let fileExtension = "csv"
    func canParse(_ text: String) -> Bool { text.lowercased().contains("username") }
    func parse(_ text: String, into db: inout PasswordDatabase, now: Date) throws -> Int {
        let imp = CSVImporter(id: id, title: title, columnMap: [
            "name": ["name"], "login": ["username"], "password": ["password"],
            "url": ["url"], "notes": ["note", "notes"],
        ])
        return try imp.parse(text, into: &db, now: now)
    }
}

struct ProtonPassFormat: ImportFormat {
    let id = "protonpass"
    let title = "Proton Pass"
    let fileExtension = "csv"
    func canParse(_ text: String) -> Bool { text.lowercased().contains("username") || text.lowercased().contains("email") }
    func parse(_ text: String, into db: inout PasswordDatabase, now: Date) throws -> Int {
        let imp = CSVImporter(id: id, title: title, columnMap: [
            "name": ["name", "title"], "login": ["username", "email"], "password": ["password"],
            "url": ["url"], "notes": ["note", "notes"],
        ])
        return try imp.parse(text, into: &db, now: now)
    }
}

struct KeePassFormat: ImportFormat {
    let id = "keepass"
    let title = "KeePass / KeePassXC"
    let fileExtension = "csv"
    func canParse(_ text: String) -> Bool { text.lowercased().contains("password") }
    func parse(_ text: String, into db: inout PasswordDatabase, now: Date) throws -> Int {
        let imp = CSVImporter(id: id, title: title, columnMap: [
            "name": ["title", "account", "name"], "login": ["login", "username"],
            "password": ["password"], "url": ["url"], "notes": ["notes"],
        ])
        return try imp.parse(text, into: &db, now: now)
    }
}

struct KeeperFormat: ImportFormat {
    let id = "keeper"
    let title = "Keeper"
    let fileExtension = "csv"
    func canParse(_ text: String) -> Bool { text.lowercased().contains("login") }
    func parse(_ text: String, into db: inout PasswordDatabase, now: Date) throws -> Int {
        let imp = CSVImporter(id: id, title: title, columnMap: [
            "name": ["title", "record_type"], "login": ["login"], "password": ["password"],
            "url": ["url"], "notes": ["notes"],
        ])
        return try imp.parse(text, into: &db, now: now)
    }
}

struct RoboFormFormat: ImportFormat {
    let id = "roboform"
    let title = "RoboForm"
    let fileExtension = "csv"
    func canParse(_ text: String) -> Bool { text.lowercased().contains("login") || text.lowercased().contains("pwd") }
    func parse(_ text: String, into db: inout PasswordDatabase, now: Date) throws -> Int {
        let imp = CSVImporter(id: id, title: title, columnMap: [
            "name": ["name"], "login": ["login"], "password": ["pwd", "password"],
            "url": ["url"], "notes": ["note", "notes"],
        ])
        return try imp.parse(text, into: &db, now: now)
    }
}

/// CommonCsvFormat — best-effort generic CSV with header detection.
struct CommonCsvFormat: ImportFormat {
    let id = "csv"
    let title = "CSV"
    let fileExtension = "csv"
    func canParse(_ text: String) -> Bool { text.contains(",") && text.contains("\n") }
    func parse(_ text: String, into db: inout PasswordDatabase, now: Date) throws -> Int {
        let imp = CSVImporter(id: id, title: title, columnMap: [
            "name": ["name", "title", "account"],
            "login": ["login", "username", "user", "email"],
            "password": ["password", "pass", "pwd"],
            "url": ["url", "website", "site", "uri"],
            "notes": ["note", "notes", "comment"],
        ])
        return try imp.parse(text, into: &db, now: now)
    }
}

// MARK: - Export (ExportCardsTask / ExportAsSheetController)

enum ExportFormat: String, CaseIterable, Identifiable {
    case xml, csv, txt
    var id: String { rawValue }
    var name: String { L10n.t("\(rawValue)_format_text") }
}

enum ExportCardsTask {
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
