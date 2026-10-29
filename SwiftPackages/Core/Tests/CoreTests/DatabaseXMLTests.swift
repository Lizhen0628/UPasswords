import XCTest
@testable import UPasswordsCore

final class DatabaseXMLTests: XCTestCase {
    func testParserAcceptsExtensionSnapshotDatabaseRoot() throws {
        let xml = Data("<database><card id=\"B71309E6-C0E1-4BF4-91B2-E5995DDA1E15\" title=\"Browser copy\" /></database>".utf8)

        let database = try PasswordDatabase.parse(xml)

        XCTAssertEqual(database.cards.count, 1)
        XCTAssertEqual(database.cards.first?.title, "Browser copy")
    }

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
        XCTAssertEqual(c.fields.map(\.id), db.cards[0].fields.map(\.id))
        XCTAssertTrue(c.fields.allSatisfy(\.hasPersistentID))
        XCTAssertEqual(c.fields[1].value, "hunter2")
        XCTAssertEqual(c.fields[1].history.first?.value, "old1")
        XCTAssertEqual(c.fields[2].type, .oneTimePassword)
        XCTAssertEqual(c.notes, "多行\n笔记")
        XCTAssertEqual(c.labelIds, db.cards[0].labelIds)
        XCTAssertEqual(c.images.first?.data, Data([0x89, 0x50, 0x4E, 0x47]))
        XCTAssertEqual(c.images.first?.id, db.cards[0].images.first?.id)
        XCTAssertEqual(c.images.first?.contentVersion, db.cards[0].images.first?.contentVersion)
        XCTAssertTrue(c.images.first?.hasPersistentContentVersion == true)
        XCTAssertEqual(c.files.first?.name, "key.txt")
        XCTAssertEqual(c.files.first?.id, db.cards[0].files.first?.id)
        XCTAssertEqual(c.files.first?.contentVersion, db.cards[0].files.first?.contentVersion)
    }

    func testLegacyChildIDsRemainUntrustedAndAreNotInventedOnSerialization() throws {
        let cardID = UUID()
        let profileID = UUID()
        let xml = """
        <database>
            <card id="\(cardID.uuidString)">
                <field name="legacy">value</field>
                <image name="old.png">AQID</image>
                <file name="old.txt">BAUG</file>
            </card>
            <user_profile id="\(profileID.uuidString)">
                <field name="legacy profile">profile value</field>
            </user_profile>
        </database>
        """

        let database = try PasswordDatabase.parse(Data(xml.utf8))
        let card = try XCTUnwrap(database.cards.first)
        let profile = try XCTUnwrap(database.userProfiles.first)
        XCTAssertFalse(card.fields[0].hasPersistentID)
        XCTAssertFalse(card.images[0].hasPersistentID)
        XCTAssertFalse(card.files[0].hasPersistentID)
        XCTAssertFalse(card.images[0].hasPersistentContentVersion)
        XCTAssertFalse(card.files[0].hasPersistentContentVersion)
        XCTAssertFalse(profile.fields[0].hasPersistentID)

        let serialized = String(decoding: database.xmlData(), as: UTF8.self)
        XCTAssertFalse(serialized.contains("id=\"\(card.fields[0].id.uuidString)\""))
        XCTAssertFalse(serialized.contains("id=\"\(card.images[0].id.uuidString)\""))
        XCTAssertFalse(serialized.contains("id=\"\(card.files[0].id.uuidString)\""))
        XCTAssertFalse(serialized.contains("version=\"\(card.images[0].contentVersion.uuidString)\""))
        XCTAssertFalse(serialized.contains("version=\"\(card.files[0].contentVersion.uuidString)\""))
        XCTAssertFalse(serialized.contains("id=\"\(profile.fields[0].id.uuidString)\""))

        let decodedAgain = try PasswordDatabase.parse(Data(serialized.utf8))
        XCTAssertFalse(decodedAgain.cards[0].fields[0].hasPersistentID)
        XCTAssertFalse(decodedAgain.userProfiles[0].fields[0].hasPersistentID)
        XCTAssertNotEqual(decodedAgain.cards[0].fields[0].id, card.fields[0].id)
    }

    func testAttachmentContentChangesVersionButMetadataChangesDoNot() throws {
        var attachment = Attachment(name: "old.txt", data: Data("old".utf8))
        let originalVersion = attachment.contentVersion
        attachment.name = "renamed.txt"
        XCTAssertEqual(attachment.contentVersion, originalVersion)

        attachment.data = Data("new".utf8)
        XCTAssertNotEqual(attachment.contentVersion, originalVersion)
        XCTAssertTrue(attachment.hasPersistentContentVersion)
    }

    func testUnavailableAndEmptyAttachmentContentsRoundTripSeparately() throws {
        let missingID = UUID()
        let missingVersion = UUID()
        var card = Card(title: "Account")
        card.images = [Attachment(
            id: missingID, contentVersion: missingVersion, name: "remote.png", data: nil)]
        card.files = [Attachment(name: "empty.txt", data: Data())]
        var database = PasswordDatabase()
        database.cards = [card]

        let xml = String(decoding: database.xmlData(), as: UTF8.self)
        XCTAssertTrue(xml.contains("missing=\"true\""))
        XCTAssertTrue(xml.contains("empty=\"true\""))
        let decoded = try PasswordDatabase.parse(Data(xml.utf8))

        let missing = try XCTUnwrap(decoded.cards.first?.images.first)
        XCTAssertNil(missing.data)
        XCTAssertEqual(missing.id, missingID)
        XCTAssertEqual(missing.contentVersion, missingVersion)
        XCTAssertTrue(missing.hasPersistentID)
        XCTAssertTrue(missing.hasPersistentContentVersion)
        let empty = try XCTUnwrap(decoded.cards.first?.files.first)
        XCTAssertEqual(empty.data, Data())
        XCTAssertTrue(empty.hasContent)
    }

    func testAttachmentCodableOmitsUnavailableBytesAndReadsLegacyData() throws {
        let reference = Attachment(name: "remote.bin", data: nil)
        let encodedReference = try JSONEncoder().encode(reference)
        let referenceObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encodedReference) as? [String: Any])
        XCTAssertNil(referenceObject["data"])
        let decodedReference = try JSONDecoder().decode(Attachment.self, from: encodedReference)
        XCTAssertNil(decodedReference.data)
        XCTAssertEqual(decodedReference.contentVersion, reference.contentVersion)

        let legacy = Data(#"{"name":"legacy.txt","data":"AQID"}"#.utf8)
        let decodedLegacy = try JSONDecoder().decode(Attachment.self, from: legacy)
        XCTAssertEqual(decodedLegacy.data, Data([1, 2, 3]))
        XCTAssertFalse(decodedLegacy.hasPersistentID)
        XCTAssertFalse(decodedLegacy.hasPersistentContentVersion)

        let invalidReference = Data(#"{"name":"remote.bin","data":null}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(Attachment.self, from: invalidReference))
    }

    func testDownloadedContentAndCacheEvictionPreserveVersion() throws {
        let version = UUID()
        var attachment = Attachment(
            contentVersion: version, name: "remote.txt", data: nil)

        XCTAssertTrue(attachment.installDownloadedContent(Data("bytes".utf8), for: version))
        XCTAssertEqual(attachment.data, Data("bytes".utf8))
        XCTAssertEqual(attachment.contentVersion, version)

        attachment.discardLocalContent()
        XCTAssertNil(attachment.data)
        XCTAssertEqual(attachment.contentVersion, version)
        XCTAssertFalse(attachment.installDownloadedContent(Data(), for: UUID()))

        attachment.data = Data("replacement".utf8)
        XCTAssertNotEqual(attachment.contentVersion, version)
    }

    func testInvalidNonemptyAttachmentBase64IsRejected() {
        let xml = """
        <database><card id="\(UUID().uuidString)">
            <file name="broken.txt">not-base64!</file>
        </card></database>
        """
        XCTAssertThrowsError(try PasswordDatabase.parse(Data(xml.utf8)))
    }

    func testMetadataOnlyAttachmentRequiresStableIdentityAndVersion() {
        let xml = """
        <database><card id="\(UUID().uuidString)">
            <file name="remote.txt" missing="true" />
        </card></database>
        """
        XCTAssertThrowsError(try PasswordDatabase.parse(Data(xml.utf8)))
    }

    func testMalformedAttachmentContentVersionIsRejected() {
        let xml = """
        <database><card id="\(UUID().uuidString)">
            <file id="\(UUID().uuidString)" version="not-a-uuid" name="x">AQID</file>
        </card></database>
        """
        XCTAssertThrowsError(try PasswordDatabase.parse(Data(xml.utf8)))
    }

    func testChildIDsMustBeValidAndUniqueWithinTheirParent() {
        let itemID = UUID()
        let childID = UUID()
        let malformed = """
        <database><card id="\(itemID.uuidString)">
            <field id="not-a-uuid" name="x">value</field>
        </card></database>
        """
        XCTAssertThrowsError(try PasswordDatabase.parse(Data(malformed.utf8)))

        let duplicate = """
        <database><card id="\(itemID.uuidString)">
            <field id="\(childID.uuidString)" name="x">one</field>
            <field id="\(childID.uuidString)" name="y">two</field>
        </card></database>
        """
        XCTAssertThrowsError(try PasswordDatabase.parse(Data(duplicate.utf8)))

        let duplicateAttachment = """
        <database><card id="\(itemID.uuidString)">
            <image id="\(childID.uuidString)" name="image.png">AQID</image>
            <file id="\(childID.uuidString)" name="file.bin">BAUG</file>
        </card></database>
        """
        XCTAssertThrowsError(try PasswordDatabase.parse(Data(duplicateAttachment.utf8)))

        let nonCanonical = """
        <database><card id="\(itemID.uuidString)">
            <field id="{\(childID.uuidString)}" name="x">value</field>
        </card></database>
        """
        XCTAssertThrowsError(try PasswordDatabase.parse(Data(nonCanonical.utf8)))
    }

    func testUserProfileFieldIDsRoundTrip() throws {
        let field = Field(name: "Email", type: .email, value: "person@example.com")
        var profile = UserProfile()
        profile.fields = [field]
        var database = PasswordDatabase()
        database.userProfiles = [profile]

        let decoded = try PasswordDatabase.parse(database.xmlData())
        XCTAssertEqual(decoded.userProfiles.first?.fields.first?.id, field.id)
        XCTAssertEqual(decoded.userProfiles.first?.fields.first?.hasPersistentID, true)
    }

    func testCodablePreservesLegacyIdentityAbsence() throws {
        let xml = """
        <database><card id="\(UUID().uuidString)"><field name="legacy">value</field></card></database>
        """
        let field = try XCTUnwrap(PasswordDatabase.parse(Data(xml.utf8)).cards.first?.fields.first)
        let encoded = try JSONEncoder().encode(field)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(json["id"])

        let decoded = try JSONDecoder().decode(Field.self, from: encoded)
        XCTAssertFalse(decoded.hasPersistentID)
        XCTAssertNotEqual(decoded.id, field.id)
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
