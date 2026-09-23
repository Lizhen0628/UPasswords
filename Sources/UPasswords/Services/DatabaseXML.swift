import Foundation

/// The decrypted database: mirrors `XDatabase` (Models/XDatabase.h) plus
/// `DatabaseAdapter`'s item indexes. XML element/attribute names are identical
/// to the original `database.xml` format documented in the reverse notes:
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
///   </card>
///   <ghost id time/>
/// </database>
/// ```
struct PasswordDatabase: Codable, Equatable {
    var labels: [CardLabel] = []
    var cards: [Card] = []
    var ghosts: [Ghost] = []

    // MARK: - Adapter accessors (DatabaseAdapter.h)

    func card(id: Int) -> Card? { cards.first { $0.id == id } }
    func label(id: Int) -> CardLabel? { labels.first { $0.id == id } }

    var activeCards: [Card] { cards.filter { !$0.template && !$0.trashed } }
    var templateCards: [Card] { cards.filter { $0.template } }

    func isUsedItemId(_ id: Int) -> Bool {
        cards.contains { $0.id == id } || labels.contains { $0.id == id } || ghosts.contains { $0.id == id }
    }

    /// DatabaseAdapter fresh item id (max + 1, skipping used ids).
    mutating func nextItemId() -> Int {
        var id = 1
        while isUsedItemId(id) { id += 1 }
        return id
    }

    // MARK: - Factory

    /// New database with the original's default labels and 15 built-in templates.
    static func createDefault(now: Date = Date()) -> PasswordDatabase {
        var db = PasswordDatabase()
        for (key, id, type) in Templates.defaultLabelKeys {
            var l = CardLabel(id: id, name: L10n.db(key))
            l.type = type
            l.timeStamp = now.millis
            db.labels.append(l)
        }
        db.cards = Templates.all.map(Templates.makeTemplateCard)
        return db
    }

    // MARK: - Merge (XDatabase.mergeWithDatabase:)

    /// Item-level merge for sync convergence: newest `modified` wins; tombstone
    /// (ghost) suppresses resurrection of items deleted on the other peer.
    mutating func merge(with other: PasswordDatabase) {
        let ghostIds = Set(other.ghosts.map(\.id)).union(ghosts.map(\.id))

        var byLabel = Dictionary(uniqueKeysWithValues: labels.map { ($0.id, $0) })
        for l in other.labels where !ghostIds.contains(l.id) {
            if let mine = byLabel[l.id], mine.timeStamp >= l.timeStamp { continue }
            byLabel[l.id] = l
        }
        labels = byLabel.values.sorted { $0.id < $1.id }

        var byCard = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })
        for c in other.cards where !ghostIds.contains(c.id) {
            if let mine = byCard[c.id], mine.modified >= c.modified { continue }
            byCard[c.id] = c
        }
        cards = byCard.values.sorted { $0.id < $1.id }

        var byGhost = Dictionary(uniqueKeysWithValues: ghosts.map { ($0.id, $0) })
        for g in other.ghosts { byGhost[g.id] = g }
        ghosts = byGhost.values.sorted { $0.id < $1.id }
    }

    /// Registers a tombstone and removes the item (deleteCardWithId:).
    mutating func deleteCardPermanently(id: Int, now: Date = Date()) {
        cards.removeAll { $0.id == id }
        var g = byIdGhost(id) ?? Ghost(id: id, time: now.millis)
        g.time = now.millis
        upsertGhost(g)
    }

    private func byIdGhost(_ id: Int) -> Ghost? { ghosts.first { $0.id == id } }
    private mutating func upsertGhost(_ g: Ghost) {
        if let i = ghosts.firstIndex(where: { $0.id == g.id }) { ghosts[i] = g } else { ghosts.append(g) }
    }
}

// MARK: - XML serialization (XDatabase.data)

extension PasswordDatabase {
    func xmlData() -> Data {
        var s = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<database>\n"
        for l in labels {
            s += "    <label name=\"\(XMLEscape(l.name))\" id=\"\(l.id)\""
            if let t = l.type, !t.isEmpty { s += " type=\"\(XMLEscape(t))\"" }
            if let c = l.color { s += " color=\"\(XMLEscape(c))\"" }
            if l.pinToTop { s += " pin_to_top=\"true\"" }
            s += " />\n"
        }
        for c in cards {
            s += "    <card title=\"\(XMLEscape(c.title))\" id=\"\(c.id)\""
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
                if let l = label(id: lid) {
                    s += "        <label name=\"\(XMLEscape(l.name))\" id=\"\(l.id)\" />\n"
                }
            }
            for img in c.images {
                s += "        <image name=\"\(XMLEscape(img.name))\">\(img.data.base64EncodedString())</image>\n"
            }
            for file in c.files {
                s += "        <file name=\"\(XMLEscape(file.name))\">\(file.data.base64EncodedString())</file>\n"
            }
            s += "    </card>\n"
        }
        for g in ghosts {
            s += "    <ghost id=\"\(g.id)\" time=\"\(Int(g.time))\" />\n"
        }
        s += "</database>\n"
        return Data(s.utf8)
    }

    static func historyJSON(_ entries: [HistoryEntry]) -> String {
        let arr: [[String: Any]] = entries.map { ["v": $0.value, "t": Int64($0.time)] }
        guard let data = try? JSONSerialization.data(withJSONObject: arr),
              let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }

    static func history(fromJSON raw: String?) -> [HistoryEntry] {
        guard let raw, let data = raw.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr.compactMap { obj in
            guard let v = obj["v"] as? String else { return nil }
            let t = (obj["t"] as? NSNumber)?.doubleValue ?? 0
            return HistoryEntry(value: v, time: t)
        }
    }
}

// MARK: - XML parsing (XDatabase.parseData:)

enum DatabaseXMLError: LocalizedError {
    case malformed
    var errorDescription: String? { L10n.t("wrong_database_format_error") }
}

extension PasswordDatabase {
    /// Parses the original SafeInCloud XML exchange format (also used for the
    /// encrypted payload inside the database container).
    static func parse(_ data: Data) throws -> PasswordDatabase {
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
        db.ghosts = parser.ghosts
        return db
    }
}

private let knownFieldTypes = Set(FieldType.allCases.map(\.rawValue))
private let knownAutofills = Set(Autofill.allCases.map(\.rawValue))

private final class DBXMLParser: NSObject, XMLParserDelegate {
    var labels: [CardLabel] = []
    var cards: [Card] = []
    var ghosts: [Ghost] = []
    var failed = false

    private var currentCard: Card? = nil
    private var currentField: Field? = nil
    private var textBuf = ""
    private var currentElement = ""

    func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes attrs: [String: String] = [:]) {
        currentElement = name
        textBuf = ""
        switch name {
        case "label":
            if currentCard != nil {
                // card-level label reference
                if let idStr = attrs["id"], let id = Int(idStr) {
                    currentCard?.labelIds.append(id)
                }
            } else if let idStr = attrs["id"], let id = Int(idStr), let n = attrs["name"] {
                var l = CardLabel(id: id, name: L10n.resolve(n))
                l.type = attrs["type"].flatMap { $0.isEmpty ? nil : $0 }
                l.color = attrs["color"]
                l.pinToTop = attrs["pin_to_top"] == "true"
                l.timeStamp = TimeInterval(attrs["time"].flatMap(Double.init) ?? 0)
                labels.append(l)
            }
        case "card":
            var c = Card(id: Int(attrs["id"] ?? "") ?? 0)
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
        case "field":
            var f = Field(name: L10n.resolve(attrs["name"] ?? ""))
            if let t = attrs["type"], knownFieldTypes.contains(t) {
                f.type = FieldType(rawValue: t) ?? .text
            } else {
                f.type = .text // XSanitizer: unknown types degrade to text
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
        case "ghost":
            if let idStr = attrs["id"], let id = Int(idStr) {
                ghosts.append(Ghost(id: id, time: TimeInterval(attrs["time"].flatMap(Double.init) ?? 0)))
            }
        default:
            break
        }
    }

    func parser(_ p: XMLParser, foundCharacters string: String) {
        textBuf += string
    }

    private enum AttachmentKind { case image, file }
    private var pendingAttachmentName: String? = nil
    private var pendingAttachmentKind: AttachmentKind? = nil

    func parser(_ p: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "field":
            currentField?.value = textBuf
            if let f = currentField { currentCard?.fields.append(f) }
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
        case "card":
            if let c = currentCard { cards.append(c) }
            currentCard = nil
        default:
            break
        }
        pendingAttachmentName = nil
        pendingAttachmentKind = nil
        currentElement = ""
    }

    func parser(_ p: XMLParser, parseErrorOccurred error: Error) {
        failed = true
    }
}

func XMLEscape(_ s: String) -> String {
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
