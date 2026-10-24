import Foundation

/// The decrypted database model plus item indexes. XML element/attribute
/// layout of the exchange format:
///
/// ```
/// <database>
///   <label name id type color pin_to_top/>
///   <card title id symbol color template autofill favorite archived trashed
///         expiration reminder created modified>
///     <field name type autofill history>value</field>
///     <note>…</note>
///     <label name id/>
///     <image name>base64</image>
///     <file name>base64</file>
///     <icon source>base64</icon>        ← 本项目扩展:卡片图标(website/custom/url/builtin)
///   </card>
/// </database>
/// ```
///
/// `id` 属性为 UUID 字符串(客户端生成,行级同步条目身份);
/// 无 `<ghost>` 元素——本地删除即移除,删除事实由服务端条目表缺席承载
/// (Cloud/DATABASE.md)。
public struct PasswordDatabase: Codable, Equatable {
    /// 创建不含模板、卡片、标签或个人资料的空数据库值。
    public init() {}

    /// 当前库中的标签值集合。
    public var labels: [CardLabel] = []
    /// 当前库中的卡片值集合，包含模板、归档与回收站项。
    public var cards: [Card] = []
    /// 独立于密码卡片保存的个人资料集合。
    public var userProfiles: [UserProfile] = []

    private enum CodingKeys: String, CodingKey {
        case labels, cards, userProfiles
    }

    /// Decodes older JSON backups that predate the independent profile collection.
    /// - Parameter decoder: Database decoder.
    /// - Throws: A decoding error when a present collection is invalid.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        labels = try container.decodeIfPresent([CardLabel].self, forKey: .labels) ?? []
        cards = try container.decodeIfPresent([Card].self, forKey: .cards) ?? []
        userProfiles = try container.decodeIfPresent([UserProfile].self, forKey: .userProfiles) ?? []
    }

    // MARK: - Item accessors

    /// 按稳定 UUID 查找首个卡片。
    ///
    /// - Parameter id: 目标卡片身份。
    /// - Returns: 对应卡片的值副本；不存在时为 nil。
    /// - Complexity: O(n)，n 为卡片数。
    public func card(id: UUID) -> Card? { cards.first { $0.id == id } }
    /// 按稳定 UUID 查找首个标签。
    ///
    /// - Parameter id: 目标标签身份。
    /// - Returns: 对应标签的值副本；不存在时为 nil。
    /// - Complexity: O(n)，n 为标签数。
    public func label(id: UUID) -> CardLabel? { labels.first { $0.id == id } }

    /// 排除模板和回收站项后的卡片；归档项仍包含在结果中。
    ///
    /// - Complexity: O(n)，n 为全部卡片数。
    public var activeCards: [Card] { cards.filter { !$0.template && !$0.trashed } }
    /// 按原始顺序保留的模板卡片。
    ///
    /// - Complexity: O(n)，n 为全部卡片数。
    public var templateCards: [Card] { cards.filter { $0.template } }

    // MARK: - Factory

    /// New database with the default labels and 15 built-in templates.
    public static func createDefault(now: Date = Date()) -> PasswordDatabase {
        var db = PasswordDatabase()
        for (key, type) in Templates.defaultLabelKeys {
            var l = CardLabel(name: L10n.db(key))
            l.type = type
            l.timeStamp = now.millis
            db.labels.append(l)
        }
        db.cards = Templates.all.map(Templates.makeTemplateCard)
        return db
    }

    // MARK: - Merge(整库 LWW 合并:导入恢复等场景;同步收敛走 DatabaseItemCodec 逐条裁决)

    /// Item-level merge: newest `modified`/`timeStamp` wins(本地不早于对端则保留本地)。
    public mutating func merge(with other: PasswordDatabase) {
        var byLabel = Dictionary(uniqueKeysWithValues: labels.map { ($0.id, $0) })
        for l in other.labels {
            if let mine = byLabel[l.id], mine.timeStamp >= l.timeStamp { continue }
            byLabel[l.id] = l
        }
        labels = byLabel.values.sorted { $0.id.uuidString < $1.id.uuidString }

        var byCard = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })
        for c in other.cards {
            if let mine = byCard[c.id], mine.modified >= c.modified { continue }
            byCard[c.id] = c
        }
        cards = byCard.values.sorted { $0.id.uuidString < $1.id.uuidString }
        var byProfile = Dictionary(uniqueKeysWithValues: userProfiles.map { ($0.id, $0) })
        for profile in other.userProfiles {
            if let mine = byProfile[profile.id], mine.modified >= profile.modified { continue }
            byProfile[profile.id] = profile
        }
        userProfiles = byProfile.values.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    /// 永久删除条目(回收站二段式的第二段):本地直接移除,不留标记;
    /// 行级同步的删除事实由服务端条目表缺席承载(§6.6)。
    public mutating func deleteCardPermanently(id: UUID) {
        cards.removeAll { $0.id == id }
    }

    /// 永久删除标签(同上,无墓碑)。
    public mutating func deleteLabelPermanently(id: UUID) {
        labels.removeAll { $0.id == id }
        for i in cards.indices {
            cards[i].labelIds.removeAll { $0 == id }
        }
    }
}

// MARK: - XML 序列化

extension PasswordDatabase {
    /// 序列化全部标签、卡片和个人资料为 UTF-8 XML 明文。
    ///
    /// - Returns: 尚未加密的数据库字节；写入库文件前必须交给 DatabaseCipher。
    public func xmlData() -> Data {
        var s = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<database>\n"
        for l in labels {
            s += Self.labelElement(l) + "\n"
        }
        let labelNames = Dictionary(uniqueKeysWithValues: labels.map { ($0.id, $0.name) })
        for c in cards {
            s += Self.cardElement(c, labelNames: labelNames) + "\n"
        }
        for profile in userProfiles {
            s += Self.userProfileElement(profile) + "\n"
        }
        s += "</database>\n"
        return Data(s.utf8)
    }

    /// 单个标签的 XML 元素行(条目级编解码与整库序列化共用)。
    public static func labelElement(_ l: CardLabel) -> String {
        var s = "    <label name=\"\(XMLEscape(l.name))\" id=\"\(l.id.uuidString)\""
        if let t = l.type, !t.isEmpty { s += " type=\"\(XMLEscape(t))\"" }
        if let c = l.color { s += " color=\"\(XMLEscape(c))\"" }
        if l.pinToTop { s += " pin_to_top=\"true\"" }
        // 条件落盘 time(毫秒):0(存量库未编辑过)不写属性;>0(编辑/新建)才写,
        // 令对端 LWW 判定有真实时间可比。毫秒按 Int64 整数输出:
        // Double 直接插值大数会变科学计数法(1.7e+12)
        if l.timeStamp > 0 { s += " time=\"\(Int64(l.timeStamp))\"" }
        return s + " />"
    }

    /// 单个卡片的完整 XML 元素(多行,条目级编解码与整库序列化共用)。
    /// `labelNames` 供卡内标签引用写出名称(名称仅展示用,同步按 id)。
    public static func cardElement(_ c: Card, labelNames: [UUID: String] = [:]) -> String {
        var s = "    <card title=\"\(XMLEscape(c.title))\" id=\"\(c.id.uuidString)\""
        if let sym = c.symbol, !sym.isEmpty { s += " symbol=\"\(XMLEscape(sym))\"" }
        if let col = c.color { s += " color=\"\(XMLEscape(col))\"" }
        if c.template { s += " template=\"true\"" }
        s += " autofill=\"\(c.autofillEnabled ? "on" : "off")\""
        if c.favorite { s += " favorite=\"true\"" }
        if c.archived { s += " archived=\"true\"" }
        if c.trashed { s += " trashed=\"true\"" }
        if let e = c.expiration { s += " expiration=\"\(Int(e))\"" }
        if let r = c.reminder { s += " reminder=\"\(Int(r))\"" }
        s += " created=\"\(Int(c.created))\" modified=\"\(Int(c.modified))\">\n"
        for f in c.fields {
            s += "        <field name=\"\(XMLEscape(f.name))\" type=\"\(f.type.rawValue)\" autofill=\"\(f.autofill.rawValue)\""
            if !f.history.isEmpty {
                let json = Self.historyJSON(f.history)
                s += " history=\"\(XMLEscape(json))\""
            }
            s += ">\(XMLEscape(f.value))</field>\n"
        }
        if !c.notes.isEmpty {
            s += "        <note>\(XMLEscape(c.notes))</note>\n"
        }
        for lid in c.labelIds {
            let name = labelNames[lid] ?? ""
            s += "        <label name=\"\(XMLEscape(name))\" id=\"\(lid.uuidString)\" />\n"
        }
        for img in c.images {
            s += "        <image name=\"\(XMLEscape(img.name))\">\(img.data.base64EncodedString())</image>\n"
        }
        for file in c.files {
            s += "        <file name=\"\(XMLEscape(file.name))\">\(file.data.base64EncodedString())</file>\n"
        }
        if let src = c.iconSource, !src.isEmpty {
            if let d = c.iconData, !d.isEmpty {
                s += "        <icon source=\"\(XMLEscape(src))\">\(d.base64EncodedString())</icon>\n"
            } else {
                s += "        <icon source=\"\(XMLEscape(src))\" />\n"
            }
        }
        return s + "    </card>"
    }

    /// Encodes a personal information record separately from card elements.
    /// - Parameter profile: Decrypted profile to serialize before vault encryption.
    /// - Returns: One user_profile XML element.
    public static func userProfileElement(_ profile: UserProfile) -> String {
        var s = "    <user_profile id=\"\(profile.id.uuidString)\""
        s += " autofill=\"\(profile.registrationAutofillEnabled ? "on" : "off")\""
        s += " created=\"\(Int64(profile.created))\" modified=\"\(Int64(profile.modified))\">\n"
        for field in profile.fields {
            s += "        <field name=\"\(XMLEscape(field.name))\""
            s += " type=\"\(field.type.rawValue)\" autofill=\"\(field.autofill.rawValue)\""
            if !field.history.isEmpty {
                s += " history=\"\(XMLEscape(Self.historyJSON(field.history)))\""
            }
            s += ">\(XMLEscape(field.value))</field>\n"
        }
        return s + "    </user_profile>"
    }

    /// 将字段历史序列化为 XML 属性中使用的 JSON 文本。
    ///
    /// - Parameter entries: 含历史明文和毫秒时间戳的记录。
    /// - Returns: JSON 数组文本；编码失败时为空数组文本。
    public static func historyJSON(_ entries: [HistoryEntry]) -> String {
        let arr: [[String: Any]] = entries.map { ["v": $0.value, "t": Int64($0.time)] }
        guard let data = try? JSONSerialization.data(withJSONObject: arr),
              let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }

    /// 容错读取字段历史属性，忽略没有字符串值的条目。
    ///
    /// - Parameter raw: 可选的历史 JSON 文本。
    /// - Returns: 有效记录数组；缺失或格式错误时返回空数组。
    public static func history(fromJSON raw: String?) -> [HistoryEntry] {
        guard let raw, let data = raw.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr.compactMap { obj in
            guard let v = obj["v"] as? String else { return nil }
            let t = (obj["t"] as? NSNumber)?.doubleValue ?? 0
            return HistoryEntry(value: v, time: t)
        }
    }
}

// MARK: - XML 解析

/// 数据库 XML 语法或结构校验失败的错误域。
public enum DatabaseXMLError: LocalizedError {
    case malformed
    /// 供用户界面展示的本地化 XML 格式错误。
    public var errorDescription: String? { L10n.t("wrong_database_format_error") }
}

extension PasswordDatabase {
    /// Parses the XML exchange format (also used for the encrypted payload
    /// inside the database container); also accepts SafeInCloud XML for import。
    public static func parse(_ data: Data) throws -> PasswordDatabase {
        let parser = DBXMLParser()
        let pp = XMLParser(data: data)
        pp.delegate = parser
        pp.shouldResolveExternalEntities = false
        guard pp.parse(), !parser.failed else {
            throw DatabaseXMLError.malformed
        }
        var db = PasswordDatabase()
        db.labels = parser.labels
        db.cards = parser.cards
        db.userProfiles = parser.userProfiles
        return db
    }
}

private let knownFieldTypes = Set(FieldType.allCases.map(\.rawValue))
private let knownAutofills = Set(Autofill.allCases.map(\.rawValue))

/// 单次 XML 解析使用的有状态代理，累计卡片、标签及资料记录。
///
/// 每次解析必须创建新实例；同一实例不得跨任务并发复用。
final class DBXMLParser: NSObject, XMLParserDelegate {
    /// 当前库中的标签值集合。
    public var labels: [CardLabel] = []
    /// 当前库中的卡片值集合，包含模板、归档与回收站项。
    public var cards: [Card] = []
    /// 独立于密码卡片保存的个人资料集合。
    public var userProfiles: [UserProfile] = []
    /// XML 语法或必需身份字段校验是否失败。
    public var failed = false

    private var currentProfile: UserProfile?
    private var currentCard: Card? = nil
    private var currentField: Field? = nil
    private var textBuf = ""
    private var currentElement = ""

    /// 接收元素开始事件，创建当前记录并读取已知属性。
    public func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes attrs: [String: String] = [:]) {
        currentElement = name
        textBuf = ""
        switch name {
        case "label":
            if currentCard != nil {
                // card-level label reference
                if let idStr = attrs["id"], let id = UUID(uuidString: idStr) {
                    currentCard?.labelIds.append(id)
                }
            } else if let idStr = attrs["id"], let id = UUID(uuidString: idStr), let n = attrs["name"] {
                var l = CardLabel(id: id, name: L10n.resolve(n))
                l.type = attrs["type"].flatMap { $0.isEmpty ? nil : $0 }
                l.color = attrs["color"]
                l.pinToTop = attrs["pin_to_top"] == "true"
                l.timeStamp = TimeInterval(attrs["time"].flatMap(Double.init) ?? 0)
                labels.append(l)
            }
        case "card":
            var c = Card(id: UUID(uuidString: attrs["id"] ?? "") ?? UUID())
            c.title = L10n.resolve(attrs["title"] ?? "")
            c.symbol = attrs["symbol"]
            c.color = attrs["color"]
            c.customIconName = attrs["custom_icon"]
            c.template = attrs["template"] == "true"
            c.autofillEnabled = attrs["autofill"] != "off"
            c.favorite = attrs["favorite"] == "true"
            c.archived = attrs["archived"] == "true"
            c.trashed = attrs["trashed"] == "true"
            c.expiration = attrs["expiration"].flatMap(Double.init)
            c.reminder = attrs["reminder"].flatMap(Double.init)
            c.created = attrs["created"].flatMap(Double.init) ?? 0
            c.modified = attrs["modified"].flatMap(Double.init) ?? 0
            c.useWebsiteIcon = attrs["use_website_icon"] == "true"
            c.watch = attrs["watch"] == "true"
            currentCard = c
        case "user_profile":
            guard let rawID = attrs["id"], let id = UUID(uuidString: rawID) else {
                failed = true
                return
            }
            var profile = UserProfile(id: id)
            profile.registrationAutofillEnabled = attrs["autofill"] != "off"
            profile.created = attrs["created"].flatMap(Double.init) ?? 0
            profile.modified = attrs["modified"].flatMap(Double.init) ?? 0
            currentProfile = profile
        case "field":
            var f = Field(name: L10n.resolve(attrs["name"] ?? ""))
            if let t = attrs["type"], knownFieldTypes.contains(t) {
                f.type = FieldType(rawValue: t) ?? .text
            } else {
                f.type = .text // 未知字段类型降级为普通文本
            }
            if let a = attrs["autofill"], knownAutofills.contains(a) {
                f.autofill = Autofill(rawValue: a) ?? .off
            } else {
                f.autofill = .off
            }
            f.history = PasswordDatabase.history(fromJSON: attrs["history"])
            currentField = f
        case "image":
            pendingAttachmentName = attrs["name"] ?? ""
            pendingAttachmentKind = .image
        case "file":
            pendingAttachmentName = attrs["name"] ?? ""
            pendingAttachmentKind = .file
        case "icon":
            pendingIconSource = attrs["source"] ?? ""
        default:
            break
        }
    }

    /// 累计本次元素文本；XMLParser 可能将一段文本分多次回调。
    public func parser(_ p: XMLParser, foundCharacters string: String) {
        textBuf += string
    }

    private enum AttachmentKind { case image, file }
    private var pendingAttachmentName: String? = nil
    private var pendingAttachmentKind: AttachmentKind? = nil
    private var pendingIconSource: String? = nil

    /// 在元素结束时将文本写入当前值并收集完成的记录。
    public func parser(_ p: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "field":
            currentField?.value = textBuf
            if let f = currentField {
                if currentProfile != nil {
                    currentProfile?.fields.append(f)
                } else {
                    currentCard?.fields.append(f)
                }
            }
            currentField = nil
        case "note":
            currentCard?.notes = textBuf
        case "image", "file":
            let trimmed = textBuf.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, let kind = pendingAttachmentKind,
               let attachName = pendingAttachmentName,
               let d = Data(base64Encoded: trimmed) {
                let att = Attachment(name: attachName, data: d)
                if kind == .image { currentCard?.images.append(att) } else { currentCard?.files.append(att) }
            }
        case "icon":
            if currentCard != nil, let src = pendingIconSource, !src.isEmpty {
                let trimmed = textBuf.trimmingCharacters(in: .whitespacesAndNewlines)
                currentCard?.iconSource = src
                currentCard?.iconData = trimmed.isEmpty ? nil : Data(base64Encoded: trimmed)
            }
        case "user_profile":
            if let profile = currentProfile { userProfiles.append(profile) }
            currentProfile = nil
        case "card":
            if let c = currentCard { cards.append(c) }
            currentCard = nil
        default:
            break
        }
        pendingAttachmentName = nil
        pendingAttachmentKind = nil
        pendingIconSource = nil
        currentElement = ""
    }

    /// 标记本次解析失败；上层 parse 统一转为数据库格式错误。
    public func parser(_ p: XMLParser, parseErrorOccurred error: Error) {
        failed = true
    }
}

/// 转义 XML 文本及双引号属性值中的五种保留字符。
///
/// - Parameter s: 未转义的明文。
/// - Returns: 可写入 XML 的文本；不进行 XML 非法控制字符过滤。
public func XMLEscape(_ s: String) -> String {
    var out = ""
    for ch in s {
        switch ch {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "\"": out += "&quot;"
        case "'": out += "&apos;"
        default: out.append(ch)
        }
    }
    return out
}
