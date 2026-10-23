import XCTest
@testable import UPasswordsCore

final class DatabaseXMLTests: XCTestCase {
    private func sampleDB() -> PasswordDatabase {
        var db = PasswordDatabase()
        let l1 = CardLabel(name: "商务", timeStamp: 1000)
        let l2 = CardLabel(name: "Private", color: "blue", timeStamp: 1001)
        db.labels = [l1, l2]
        var card = Card()
        card.title = "Example Site"
        card.symbol = "web_site"
        card.color = "green"
        card.autofillEnabled = true
        card.favorite = true
        card.archived = false
        card.trashed = false
        card.expiration = 4102444800000
        card.created = 1690000000000
        card.modified = 1690000100000
        card.fields = [
            Field(name: "登录", type: .login, value: "user@example.com", autofill: .username),
            Field(name: "密码", type: .password, value: "hunter2", autofill: .currentPassword,
                  history: [HistoryEntry(value: "old1", time: 1680000000000)]),
            Field(name: "一次性代码", type: .oneTimePassword, value: "JBSWY3DPEHPK3PXP", autofill: .oneTimeCode),
        ]
        card.notes = "多行\n笔记"
        card.labelIds = [l1.id, l2.id]
        card.images = [Attachment(name: "shot.png", data: Data([0x89, 0x50, 0x4E, 0x47]))]
        card.files = [Attachment(name: "key.txt", data: Data("secret file".utf8))]
        db.cards = [card]
        return db
    }

    func testRoundTrip() throws {
        let db = sampleDB()
        let xml = db.xmlData()
        let parsed = try PasswordDatabase.parse(xml)
        XCTAssertEqual(parsed.labels, db.labels)
        XCTAssertEqual(parsed.cards.count, 1)
        let c = parsed.cards[0]
        XCTAssertEqual(c.title, "Example Site")
        XCTAssertEqual(c.symbol, "web_site")
        XCTAssertEqual(c.favorite, true)
        XCTAssertEqual(c.autofillEnabled, true)
        XCTAssertEqual(c.expiration, 4102444800000)
        XCTAssertEqual(c.fields.count, 3)
        XCTAssertEqual(c.fields[1].value, "hunter2")
        XCTAssertEqual(c.fields[1].history.first?.value, "old1")
        XCTAssertEqual(c.fields[2].type, .oneTimePassword)
        XCTAssertEqual(c.notes, "多行\n笔记")
        XCTAssertEqual(c.labelIds, db.cards[0].labelIds)
        XCTAssertEqual(c.images.first?.data, Data([0x89, 0x50, 0x4E, 0x47]))
        XCTAssertEqual(c.files.first?.name, "key.txt")
    }

    func testParseTemplateFormat() throws {
        // Template card shape: label + template card with typed, autofill-mapped fields.
        let uuid = UUID()
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <database>
            <label name="Business" id="\(UUID().uuidString)" />
            <card title="Credit card" id="\(uuid.uuidString)" symbol="credit_card" color="gray" template="true" autofill="on">
                <field name="Number" type="number" autofill="cc-number"/>
                <field name="CVV" type="pin" autofill="cc-csc"/>
            </card>
        </database>
        """
        let db = try PasswordDatabase.parse(Data(xml.utf8))
        XCTAssertEqual(db.labels.first?.name, "Business")
        let t = db.cards.first
        XCTAssertEqual(t?.id, uuid)
        XCTAssertEqual(t?.isTemplate, true)
        XCTAssertEqual(t?.fields.map(\.type), [.number, .pin])
        XCTAssertEqual(t?.fields.map(\.autofill), [.ccNumber, .ccCsc])
    }

    func testUnknownFieldTypeSanitizedToText() throws {
        let xml = """
        <database><card title="x" id="\(UUID().uuidString)"><field name="a" type="hyperdrive" autofill="off">v</field></card></database>
        """
        let db = try PasswordDatabase.parse(Data(xml.utf8))
        XCTAssertEqual(db.cards[0].fields[0].type, .text)
    }

    func testXMLEscaping() throws {
        var db = PasswordDatabase()
        var c = Card()
        c.title = "a<b>&\"'\">"
        db.cards = [c]
        let parsed = try PasswordDatabase.parse(db.xmlData())
        XCTAssertEqual(parsed.cards[0].title, "a<b>&\"'\">")
    }

    func testMalformedThrows() {
        XCTAssertThrowsError(try PasswordDatabase.parse(Data("<not-xml".utf8)))
    }

    func testMergeNewestWins() {
        let shared = UUID()
        var a = PasswordDatabase()
        var c1 = Card(id: shared); c1.title = "old"; c1.modified = 100
        a.cards = [c1]
        var b = PasswordDatabase()
        var c2 = Card(id: shared); c2.title = "new"; c2.modified = 200
        var c3 = Card(); c3.title = "added remotely"; c3.modified = 300
        b.cards = [c2, c3]
        a.merge(with: b)
        XCTAssertEqual(a.cards.count, 2)
        XCTAssertEqual(a.card(id: shared)?.title, "new")
        XCTAssertEqual(a.card(id: c3.id)?.title, "added remotely")
    }

    /// 无墓碑:被删条目不会从对端整库合并中复活——删除侧本地已移除,
    /// 合并只会采纳对端仍持有的副本(缺席即删除的收敛由服务端行库保证,
    /// 本地整库合并只用于导入/恢复场景)。
    func testMergeDoesNotResurrectLocallyDeletedWhenRemoteLacksIt() {
        var a = PasswordDatabase()
        var gone = Card()
        gone.title = "deleted"
        a.cards = [gone]
        a.deleteCardPermanently(id: gone.id)
        a.merge(with: PasswordDatabase())
        XCTAssertNil(a.card(id: gone.id))
    }

    func testDefaultDatabaseContents() {
        let db = PasswordDatabase.createDefault(now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(db.labels.count, 3, "商务/私人/网络账号")
        XCTAssertEqual(db.templateCards.count, 16, "15 named templates + custom")
        let loginSpec = Templates.spec(id: 102)!
        XCTAssertEqual(db.templateCards.first { $0.title == L10n.db(loginSpec.titleKey) }?.fields.count, 4)
        // 标签 id 为 UUID 且互不相同
        XCTAssertEqual(Set(db.labels.map(\.id)).count, db.labels.count)
    }

    /// 标签时间戳必须随 XML 往返存活(否则 merge LWW 退化为本地恒胜,
    /// 标签改名永远无法同步到对端)。
    func testLabelTimestampRoundTripAndByteStability() throws {
        var db = PasswordDatabase()
        var edited = CardLabel(name: "Work", timeStamp: 1_700_000_123_456)
        edited.color = "#FF0000"
        db.labels = [edited, CardLabel(name: "Legacy", timeStamp: 0)]

        let xml = String(data: db.xmlData(), encoding: .utf8) ?? ""
        XCTAssertTrue(xml.contains("time=\"1700000123456\""), "编辑过的标签必须落盘 time 属性")
        XCTAssertFalse(xml.contains("Legacy\" color"), "时间戳为 0(存量未编辑)不写属性,XML 字节与历史版本一致")

        let parsed = try PasswordDatabase.parse(db.xmlData())
        XCTAssertEqual(parsed.label(id: edited.id)?.timeStamp, 1_700_000_123_456, "往返无损")
        XCTAssertEqual(parsed.label(id: db.labels[1].id)?.timeStamp, 0, "缺属性归 0")
    }

    /// 标签合并 LWW:对端时间戳更新则采纳,平局保留本地。
    func testLabelMergeConvergenceByTimestamp() {
        let shared = UUID()
        var local = PasswordDatabase()
        local.labels = [CardLabel(id: shared, name: "Old", timeStamp: 1_000)]

        var remoteNewer = PasswordDatabase()
        remoteNewer.labels = [CardLabel(id: shared, name: "Renamed", timeStamp: 2_000)]
        local.merge(with: remoteNewer)
        XCTAssertEqual(local.label(id: shared)?.name, "Renamed", "对端更新的改名必须收敛进来")

        var remoteOlder = PasswordDatabase()
        remoteOlder.labels = [CardLabel(id: shared, name: "Stale", timeStamp: 500)]
        local.merge(with: remoteOlder)
        XCTAssertEqual(local.label(id: shared)?.name, "Renamed", "对端更旧不得回退")

        var remoteTie = PasswordDatabase()
        remoteTie.labels = [CardLabel(id: shared, name: "Tie", timeStamp: 2_000)]
        local.merge(with: remoteTie)
        XCTAssertEqual(local.label(id: shared)?.name, "Renamed", "平局保留本地")
    }
}
