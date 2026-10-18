import XCTest
@testable import UPasswordsCore

/// 回收站两段式 + 无墓碑删除语义锁定(见 Cloud/DESIGN.md §6.6):
/// 从回收站删除 = 本地直接移除,不留任何标记;删除事实由服务端条目表
/// 缺席承载(行库即权威),本地无需也不能保留墓碑。
final class TrashPurgeTests: XCTestCase {

    func testTrashDeleteRemovesEntirelyWithoutMarker() {
        var db = PasswordDatabase()
        var card = Card()
        card.title = "Secret"
        card.trashed = true
        db.cards.append(card)
        let id = card.id

        db.deleteCardPermanently(id: id)

        XCTAssertTrue(db.cards.isEmpty, "content must be purged immediately")
        XCTAssertNil(db.card(id: id), "deleted item invisible to all lookups")
    }

    func testLabelDeletionRemovesAndStripsReferences() {
        var db = PasswordDatabase()
        let label = CardLabel(name: "Work")
        db.labels.append(label)
        var card = Card()
        card.labelIds = [label.id]
        db.cards.append(card)

        db.deleteLabelPermanently(id: label.id)

        XCTAssertTrue(db.labels.isEmpty)
        XCTAssertTrue(db.cards[0].labelIds.isEmpty, "条目上的标签引用必须一并清除")
    }

    /// 时间戳由系统维护、XML 往返无损(用户不可手改的基线保证)。
    func testTimestampsRoundTripExact() throws {
        var db = PasswordDatabase()
        var card = Card()
        card.created = 1_700_000_000
        card.modified = 1_700_000_123
        db.cards.append(card)
        let id = card.id

        let parsed = try PasswordDatabase.parse(db.xmlData())

        XCTAssertEqual(parsed.card(id: id)?.created, 1_700_000_000)
        XCTAssertEqual(parsed.card(id: id)?.modified, 1_700_000_123)
    }

    /// 逐条冲突裁决:新者胜,平局保留本地(不刷新 nonce 防对端误判)。
    func testItemCodecResolveNewestWins() {
        var older = Card(); older.title = "old"; older.modified = 100
        var newer = older; newer.title = "new"; newer.modified = 200
        XCTAssertEqual(DatabaseItemCodec.resolve(local: .card(older), remote: .card(newer)).uuid, newer.id)
        XCTAssertEqual(DatabaseItemCodec.resolve(local: .card(newer), remote: .card(older)).uuid, newer.id)
        // 平局保留本地
        var tie = older; tie.title = "local-tie"
        XCTAssertEqual(DatabaseItemCodec.resolve(local: .card(tie), remote: .card(older)).uuid, tie.id)

        let labelOld = CardLabel(name: "a", timeStamp: 10)
        let labelNew = CardLabel(name: "b", timeStamp: 20)
        XCTAssertEqual(DatabaseItemCodec.resolve(local: .label(labelOld), remote: .label(labelNew)).uuid, labelNew.id)
    }

    /// 条目级编解码往返:单元素字节 ↔ Card/Label,uuid 必须吻合。
    func testItemCodecRoundTrip() throws {
        var card = Card()
        card.title = "Codec 卡"
        card.fields = [Field(name: "密码", type: .password, value: "p@ss")]
        card.notes = "备注"
        card.modified = 1_700_000_000_123
        let data = DatabaseItemCodec.xmlData(.card(card))
        let item = try XCTUnwrap(DatabaseItemCodec.parse(kind: 1, uuid: card.id, data: data))
        guard case .card(let decoded) = item else { return XCTFail("expected card") }
        // Field.id 不随 XML 持久化(解析时重新生成),语义字段逐一比对
        XCTAssertEqual(decoded.id, card.id)
        XCTAssertEqual(decoded.title, card.title)
        XCTAssertEqual(decoded.notes, card.notes)
        XCTAssertEqual(decoded.modified, card.modified)
        XCTAssertEqual(decoded.fields.map(\.name), card.fields.map(\.name))
        XCTAssertEqual(decoded.fields.map(\.value), card.fields.map(\.value))

        let label = CardLabel(name: "工作", timeStamp: 1_700_000_000_456)
        let labelData = DatabaseItemCodec.xmlData(.label(label))
        let labelItem = try XCTUnwrap(DatabaseItemCodec.parse(kind: 2, uuid: label.id, data: labelData))
        guard case .label(let decodedLabel) = labelItem else { return XCTFail("expected label") }
        XCTAssertEqual(decodedLabel, label)

        // uuid 不匹配(搬运防护)与损坏数据都拒绝
        XCTAssertNil(DatabaseItemCodec.parse(kind: 1, uuid: UUID(), data: data))
        XCTAssertNil(DatabaseItemCodec.parse(kind: 1, uuid: card.id, data: Data("junk".utf8)))
    }
}
