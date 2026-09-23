import Foundation

// MARK: - Concrete formats (ImportFormatFactory)

/// 导入源目录(ImportSourceViewController 数据),顺序即弹窗展示顺序。
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

    /// - Returns: 目录中 id 匹配的导入器,无匹配返回 nil
    static func format(id: String) -> (any ImportFormat)? { all.first { $0.id == id } }
}

/// SafeInCloud XML (XmlFormat.h) — accepts full `<database>` docs or a bare
/// list of `<card>` elements. 同名卡与模板不重复导入,id 冲突时改派新 id。
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

/// Chrome/Brave/Edge/Opera/Firefox 导出的 CSV(列名基本一致,仅品牌名不同)。
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

/// LastPass 导出的 CSV(extra 列映射到笔记)。
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

/// Bitwarden 导出的 CSV:folder 列映射为标签(不存在则创建)。
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
            card.symbol = "key"
            card.color = "gray"
            card.created = now.millis
            card.modified = now.millis
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

    /// 取同名标签,不存在则创建;folder/folderId → 标签的共用映射。
    /// - Returns: 标签 id
    static func ensureLabel(named name: String, in db: inout PasswordDatabase, now: Date) -> Int {
        if let l = db.labels.first(where: { $0.name == name }) { return l.id }
        let id = db.nextItemId()
        db.labels.append(CardLabel(id: id, name: name, timeStamp: now.millis))
        return id
    }
}

/// Bitwarden 导出的 JSON:兼容未加密导出的 `items` 与 `vault.items` 两种形状,
/// folderId 经 folders 表映射为标签,totp 列映射为一次性验证码字段。
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
            card.symbol = "key"
            card.color = "gray"
            card.created = now.millis
            card.modified = now.millis
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

/// Dashlane 导出的 CSV(login 列可兼容 username/email)。
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

/// 1Password 导出的 CSV。
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

/// Safari/Passwords.app 导出的 CSV。
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

/// NordPass 导出的 CSV。
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

/// Proton Pass 导出的 CSV(username/email 双列名兼容)。
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

/// KeePass/KeePassXC 导出的 CSV(title/account 双列名兼容)。
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

/// Keeper 导出的 CSV。
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

/// RoboForm 导出的 CSV(密码列名为 pwd)。
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
