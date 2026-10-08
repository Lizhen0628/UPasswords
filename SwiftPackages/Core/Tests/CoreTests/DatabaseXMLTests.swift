import XCTest
@testable import UPasswordsCore

final class DatabaseXMLTests: XCTestCase {
    private func sampleDB() -> PasswordDatabase {
        var db = PasswordDatabase()
        db.labels = [
            CardLabel(id: 1, name: "商务", timeStamp: 1000),
            CardLabel(id: 2, name: "Private", color: "blue", timeStamp: 1001),
        ]
        var card = Card(id: 10)
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
        card.labelIds = [1, 2]
        card.images = [Attachment(name: "shot.png", data: Data([0x89, 0x50, 0x4E, 0x47]))]
        card.files = [Attachment(name: "key.txt", data: Data("secret file".utf8))]
        db.cards = [card]
        db.ghosts = [Ghost(id: 99, time: 1690000000000)]
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
        XCTAssertEqual(c.labelIds, [1, 2])
        XCTAssertEqual(c.images.first?.data, Data([0x89, 0x50, 0x4E, 0x47]))
        XCTAssertEqual(c.files.first?.name, "key.txt")
        XCTAssertEqual(parsed.ghosts, [Ghost(id: 99, time: 1690000000000)])
    }

    func testParseTemplateFormat() throws {
        // Template card shape: label + template card with typed, autofill-mapped fields.
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <database>
            <label name="Business" id="1" />
            <card title="Credit card" id="101" symbol="credit_card" color="gray" template="true" autofill="on">
                <field name="Number" type="number" autofill="cc-number"/>
                <field name="CVV" type="pin" autofill="cc-csc"/>
            </card>
        </database>
        """
        let db = try PasswordDatabase.parse(Data(xml.utf8))
        XCTAssertEqual(db.labels.first?.name, "Business")
        let t = db.cards.first
        XCTAssertEqual(t?.isTemplate, true)
        XCTAssertEqual(t?.fields.map(\.type), [.number, .pin])
        XCTAssertEqual(t?.fields.map(\.autofill), [.ccNumber, .ccCsc])
    }

    func testUnknownFieldTypeSanitizedToText() throws {
        let xml = """
        <database><card title="x" id="1"><field name="a" type="hyperdrive" autofill="off">v</field></card></database>
        """
        let db = try PasswordDatabase.parse(Data(xml.utf8))
        XCTAssertEqual(db.cards[0].fields[0].type, .text)
    }

    func testXMLEscaping() throws {
        var db = PasswordDatabase()
        var c = Card(id: 1)
        c.title = "a<b>&\"'\">"
        db.cards = [c]
        let parsed = try PasswordDatabase.parse(db.xmlData())
        XCTAssertEqual(parsed.cards[0].title, "a<b>&\"'\">")
    }

    func testMalformedThrows() {
        XCTAssertThrowsError(try PasswordDatabase.parse(Data("<not-xml".utf8)))
    }

    func testMergeNewestWins() {
        var a = PasswordDatabase()
        var c1 = Card(id: 5); c1.title = "old"; c1.modified = 100
        a.cards = [c1]
        var b = PasswordDatabase()
        var c2 = Card(id: 5); c2.title = "new"; c2.modified = 200
        var c3 = Card(id: 6); c3.title = "added remotely"; c3.modified = 300
        b.cards = [c2, c3]
        a.merge(with: b)
        XCTAssertEqual(a.cards.count, 2)
        XCTAssertEqual(a.card(id: 5)?.title, "new")
        XCTAssertEqual(a.card(id: 6)?.title, "added remotely")
    }

    func testMergeGhostSuppressesResurrection() {
        var a = PasswordDatabase()
        a.ghosts = [Ghost(id: 7, time: 500)]
        var b = PasswordDatabase()
        var c = Card(id: 7); c.title = "zombie"; c.modified = 100
        b.cards = [c]
        a.merge(with: b)
        XCTAssertNil(a.card(id: 7))
    }

    /// 标签删除必须登记墓碑:否则合并时会被仍持有该标签的远端副本复活
    /// ("删掉的标签每次同步/重启后又回来"的回归)。
    func testMergeGhostSuppressesLabelResurrection() {
        var a = PasswordDatabase()
        a.deleteLabelPermanently(id: 777)
        XCTAssertTrue(a.ghosts.contains { $0.id == 777 }, "删除标签必须登记墓碑")
        var b = PasswordDatabase()
        b.labels = [CardLabel(id: 777, name: "xx")]
        a.merge(with: b)
        XCTAssertFalse(a.labels.contains { $0.id == 777 }, "墓碑必须抑制标签复活")
        b.labels.append(CardLabel(id: 778, name: "kept"))
        a.merge(with: b)
        XCTAssertTrue(a.labels.contains { $0.id == 778 }, "未删除的标签照常合并")
    }

    func testDefaultDatabaseContents() {
        var db = PasswordDatabase.createDefault(now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(db.labels.count, 3, "商务/私人/网络账号")
        XCTAssertEqual(db.templateCards.count, 16, "15 named templates + custom")
        XCTAssertEqual(db.templateCards.first { $0.id == 102 }?.fields.count, 4)
        let nid = db.nextItemId()
        XCTAssertFalse(db.isUsedItemId(nid), "ids must skip used ids")
        XCTAssertTrue(![1, 2, 4].contains(nid), "label ids are taken")
    }
}
