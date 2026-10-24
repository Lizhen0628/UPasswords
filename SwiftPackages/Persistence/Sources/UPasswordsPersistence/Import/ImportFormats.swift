import Foundation
import UPasswordsCore

// MARK: - Concrete formats (ImportFormatFactory)

/// 导入源目录,顺序即弹窗展示顺序。
public enum ImportFormatFactory {
    /// The import source catalog shown by the import sheet.
    public static let all: [any ImportFormat] = [
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
    public static func format(id: String) -> (any ImportFormat)? { all.first { $0.id == id } }
}

/// SafeInCloud XML — accepts full `<database>` docs or a bare
/// list of `<card>` elements. 同名卡与模板不重复导入,id 冲突时改派新 id。
public struct SafeInCloudXMLFormat: ImportFormat {
    /// 此导入源的稳定格式标识。
    public let id = "safeincloud-xml"
    /// 此导入源在格式选择器中的展示名称。
    public let title = "XML (SafeInCloud)"
    /// 此导入器建议的文件扩展名。
    public let fileExtension = "xml"

    /// 通过此格式的表头或结构特征进行快速探测，完整错误由 parse 报告。
    public func canParse(_ text: String) -> Bool {
        text.contains("<database") || text.contains("<card")
    }

    /// 按此格式的字段映射将记录导入工作副本；参数与错误约定见 ImportFormat。
    public func parse(_ text: String, into db: inout PasswordDatabase, now: Date) throws -> Int {
        let parsed = try PasswordDatabase.parse(Data(text.utf8))
        let existingIds = Set(db.cards.map(\.id))
        let existingTitles = Set(db.cards.filter { !$0.template }.map(\.title))
        var count = 0
        for c in parsed.cards where !c.template && !existingTitles.contains(c.title) {
            var card = c
            if existingIds.contains(card.id) { card.id = UUID() }
            db.cards.append(card)
            count += 1
        }
        return count
    }
}

/// Chrome/Brave/Edge/Opera/Firefox 导出的 CSV(列名基本一致,仅品牌名不同)。
public struct ChromeFormat: ImportFormat {
    /// 浏览器展示名，用于派生格式标识与标题。
    public let browser: String
    /// 此导入源的稳定格式标识。
    public var id: String { "chrome-\(browser.lowercased())" }
    /// 此导入源在格式选择器中的展示名称。
    public var title: String { browser }
    /// 此导入器建议的文件扩展名。
    public let fileExtension = "csv"

    /// 通过此格式的表头或结构特征进行快速探测，完整错误由 parse 报告。
    public func canParse(_ text: String) -> Bool {
        text.lowercased().contains("name") && text.lowercased().contains("username")
    }

    /// 按此格式的字段映射将记录导入工作副本；参数与错误约定见 ImportFormat。
    public func parse(_ text: String, into db: inout PasswordDatabase, now: Date) throws -> Int {
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
public struct LastPassFormat: ImportFormat {
    /// 此导入源的稳定格式标识。
    public let id = "lastpass"
    /// 此导入源在格式选择器中的展示名称。
    public let title = "LastPass"
    /// 此导入器建议的文件扩展名。
    public let fileExtension = "csv"
    /// 通过此格式的表头或结构特征进行快速探测，完整错误由 parse 报告。
    public func canParse(_ text: String) -> Bool { text.lowercased().contains("url") && text.lowercased().contains("username") }
    /// 按此格式的字段映射将记录导入工作副本；参数与错误约定见 ImportFormat。
    public func parse(_ text: String, into db: inout PasswordDatabase, now: Date) throws -> Int {
        let imp = CSVImporter(id: id, title: title, columnMap: [
            "name": ["name"], "login": ["username"], "password": ["password"],
            "url": ["url"], "notes": ["extra", "notes"],
        ])
        return try imp.parse(text, into: &db, now: now)
    }
}

/// Bitwarden 导出的 CSV:folder 列映射为标签(不存在则创建)。
public struct BitwardenCsvFormat: ImportFormat {
    /// 此导入源的稳定格式标识。
    public let id = "bitwarden-csv"
    /// 此导入源在格式选择器中的展示名称。
    public let title = "Bitwarden (CSV)"
    /// 此导入器建议的文件扩展名。
    public let fileExtension = "csv"
    /// 通过此格式的表头或结构特征进行快速探测，完整错误由 parse 报告。
    public func canParse(_ text: String) -> Bool { text.lowercased().contains("login_uri") || text.lowercased().contains("folder") }
    /// 按此格式的字段映射将记录导入工作副本；参数与错误约定见 ImportFormat。
    public func parse(_ text: String, into db: inout PasswordDatabase, now: Date) throws -> Int {
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
            var card = Card()
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
    public static func ensureLabel(named name: String, in db: inout PasswordDatabase, now: Date) -> UUID {
        if let l = db.labels.first(where: { $0.name == name }) { return l.id }
        let label = CardLabel(name: name, timeStamp: now.millis)
        db.labels.append(label)
        return label.id
    }
}

/// Bitwarden 导出的 JSON:兼容未加密导出的 `items` 与 `vault.items` 两种形状,
/// folderId 经 folders 表映射为标签,totp 列映射为一次性验证码字段。
public struct BitwardenJsonFormat: ImportFormat {
    /// 此导入源的稳定格式标识。
    public let id = "bitwarden-json"
    /// 此导入源在格式选择器中的展示名称。
    public let title = "Bitwarden (JSON)"
    /// 此导入器建议的文件扩展名。
    public let fileExtension = "json"
    /// 通过此格式的表头或结构特征进行快速探测，完整错误由 parse 报告。
    public func canParse(_ text: String) -> Bool { text.contains("\"items\"") || text.contains("\"vault\"") }
    /// 按此格式的字段映射将记录导入工作副本；参数与错误约定见 ImportFormat。
    public func parse(_ text: String, into db: inout PasswordDatabase, now: Date) throws -> Int {
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
            var card = Card()
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
public struct DashlaneCsvFormat: ImportFormat {
    /// 此导入源的稳定格式标识。
    public let id = "dashlane-csv"
    /// 此导入源在格式选择器中的展示名称。
    public let title = "Dashlane (CSV)"
    /// 此导入器建议的文件扩展名。
    public let fileExtension = "csv"
    /// 通过此格式的表头或结构特征进行快速探测，完整错误由 parse 报告。
    public func canParse(_ text: String) -> Bool { text.lowercased().contains("login") && text.lowercased().contains("password") }
    /// 按此格式的字段映射将记录导入工作副本；参数与错误约定见 ImportFormat。
    public func parse(_ text: String, into db: inout PasswordDatabase, now: Date) throws -> Int {
        let imp = CSVImporter(id: id, title: title, columnMap: [
            "name": ["title", "name"], "login": ["login", "username", "email"],
            "password": ["password"], "url": ["url", "website"], "notes": ["note", "notes"],
        ])
        return try imp.parse(text, into: &db, now: now)
    }
}

/// 1Password 导出的 CSV。
public struct OnePasswordCsvFormat: ImportFormat {
    /// 此导入源的稳定格式标识。
    public let id = "1password-csv"
    /// 此导入源在格式选择器中的展示名称。
    public let title = "1Password (CSV)"
    /// 此导入器建议的文件扩展名。
    public let fileExtension = "csv"
    /// 通过此格式的表头或结构特征进行快速探测，完整错误由 parse 报告。
    public func canParse(_ text: String) -> Bool { text.lowercased().contains("username") && text.lowercased().contains("password") }
    /// 按此格式的字段映射将记录导入工作副本；参数与错误约定见 ImportFormat。
    public func parse(_ text: String, into db: inout PasswordDatabase, now: Date) throws -> Int {
        let imp = CSVImporter(id: id, title: title, columnMap: [
            "name": ["title", "name"], "login": ["username"], "password": ["password"],
            "url": ["url"], "notes": ["notes"],
        ])
        return try imp.parse(text, into: &db, now: now)
    }
}

/// Safari/Passwords.app 导出的 CSV。
public struct ApplePasswordsFormat: ImportFormat {
    /// 此导入源的稳定格式标识。
    public let id = "apple-passwords"
    /// 此导入源在格式选择器中的展示名称。
    public let title = "Safari / Apple Passwords"
    /// 此导入器建议的文件扩展名。
    public let fileExtension = "csv"
    /// 通过此格式的表头或结构特征进行快速探测，完整错误由 parse 报告。
    public func canParse(_ text: String) -> Bool { text.lowercased().contains("username") }
    /// 按此格式的字段映射将记录导入工作副本；参数与错误约定见 ImportFormat。
    public func parse(_ text: String, into db: inout PasswordDatabase, now: Date) throws -> Int {
        let imp = CSVImporter(id: id, title: title, columnMap: [
            "name": ["title"], "login": ["username"], "password": ["password"],
            "url": ["url"], "notes": ["notes"],
        ])
        return try imp.parse(text, into: &db, now: now)
    }
}

/// NordPass 导出的 CSV。
public struct NordPassFormat: ImportFormat {
    /// 此导入源的稳定格式标识。
    public let id = "nordpass"
    /// 此导入源在格式选择器中的展示名称。
    public let title = "NordPass"
    /// 此导入器建议的文件扩展名。
    public let fileExtension = "csv"
    /// 通过此格式的表头或结构特征进行快速探测，完整错误由 parse 报告。
    public func canParse(_ text: String) -> Bool { text.lowercased().contains("username") }
    /// 按此格式的字段映射将记录导入工作副本；参数与错误约定见 ImportFormat。
    public func parse(_ text: String, into db: inout PasswordDatabase, now: Date) throws -> Int {
        let imp = CSVImporter(id: id, title: title, columnMap: [
            "name": ["name"], "login": ["username"], "password": ["password"],
            "url": ["url"], "notes": ["note", "notes"],
        ])
        return try imp.parse(text, into: &db, now: now)
    }
}

/// Proton Pass 导出的 CSV(username/email 双列名兼容)。
public struct ProtonPassFormat: ImportFormat {
    /// 此导入源的稳定格式标识。
    public let id = "protonpass"
    /// 此导入源在格式选择器中的展示名称。
    public let title = "Proton Pass"
    /// 此导入器建议的文件扩展名。
    public let fileExtension = "csv"
    /// 通过此格式的表头或结构特征进行快速探测，完整错误由 parse 报告。
    public func canParse(_ text: String) -> Bool { text.lowercased().contains("username") || text.lowercased().contains("email") }
    /// 按此格式的字段映射将记录导入工作副本；参数与错误约定见 ImportFormat。
    public func parse(_ text: String, into db: inout PasswordDatabase, now: Date) throws -> Int {
        let imp = CSVImporter(id: id, title: title, columnMap: [
            "name": ["name", "title"], "login": ["username", "email"], "password": ["password"],
            "url": ["url"], "notes": ["note", "notes"],
        ])
        return try imp.parse(text, into: &db, now: now)
    }
}

/// KeePass/KeePassXC 导出的 CSV(title/account 双列名兼容)。
public struct KeePassFormat: ImportFormat {
    /// 此导入源的稳定格式标识。
    public let id = "keepass"
    /// 此导入源在格式选择器中的展示名称。
    public let title = "KeePass / KeePassXC"
    /// 此导入器建议的文件扩展名。
    public let fileExtension = "csv"
    /// 通过此格式的表头或结构特征进行快速探测，完整错误由 parse 报告。
    public func canParse(_ text: String) -> Bool { text.lowercased().contains("password") }
    /// 按此格式的字段映射将记录导入工作副本；参数与错误约定见 ImportFormat。
    public func parse(_ text: String, into db: inout PasswordDatabase, now: Date) throws -> Int {
        let imp = CSVImporter(id: id, title: title, columnMap: [
            "name": ["title", "account", "name"], "login": ["login", "username"],
            "password": ["password"], "url": ["url"], "notes": ["notes"],
        ])
        return try imp.parse(text, into: &db, now: now)
    }
}

/// Keeper 导出的 CSV。
public struct KeeperFormat: ImportFormat {
    /// 此导入源的稳定格式标识。
    public let id = "keeper"
    /// 此导入源在格式选择器中的展示名称。
    public let title = "Keeper"
    /// 此导入器建议的文件扩展名。
    public let fileExtension = "csv"
    /// 通过此格式的表头或结构特征进行快速探测，完整错误由 parse 报告。
    public func canParse(_ text: String) -> Bool { text.lowercased().contains("login") }
    /// 按此格式的字段映射将记录导入工作副本；参数与错误约定见 ImportFormat。
    public func parse(_ text: String, into db: inout PasswordDatabase, now: Date) throws -> Int {
        let imp = CSVImporter(id: id, title: title, columnMap: [
            "name": ["title", "record_type"], "login": ["login"], "password": ["password"],
            "url": ["url"], "notes": ["notes"],
        ])
        return try imp.parse(text, into: &db, now: now)
    }
}

/// RoboForm 导出的 CSV(密码列名为 pwd)。
public struct RoboFormFormat: ImportFormat {
    /// 此导入源的稳定格式标识。
    public let id = "roboform"
    /// 此导入源在格式选择器中的展示名称。
    public let title = "RoboForm"
    /// 此导入器建议的文件扩展名。
    public let fileExtension = "csv"
    /// 通过此格式的表头或结构特征进行快速探测，完整错误由 parse 报告。
    public func canParse(_ text: String) -> Bool { text.lowercased().contains("login") || text.lowercased().contains("pwd") }
    /// 按此格式的字段映射将记录导入工作副本；参数与错误约定见 ImportFormat。
    public func parse(_ text: String, into db: inout PasswordDatabase, now: Date) throws -> Int {
        let imp = CSVImporter(id: id, title: title, columnMap: [
            "name": ["name"], "login": ["login"], "password": ["pwd", "password"],
            "url": ["url"], "notes": ["note", "notes"],
        ])
        return try imp.parse(text, into: &db, now: now)
    }
}

/// CommonCsvFormat — best-effort generic CSV with header detection.
public struct CommonCsvFormat: ImportFormat {
    /// 此导入源的稳定格式标识。
    public let id = "csv"
    /// 此导入源在格式选择器中的展示名称。
    public let title = "CSV"
    /// 此导入器建议的文件扩展名。
    public let fileExtension = "csv"
    /// 通过此格式的表头或结构特征进行快速探测，完整错误由 parse 报告。
    public func canParse(_ text: String) -> Bool { text.contains(",") && text.contains("\n") }
    /// 按此格式的字段映射将记录导入工作副本；参数与错误约定见 ImportFormat。
    public func parse(_ text: String, into db: inout PasswordDatabase, now: Date) throws -> Int {
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
