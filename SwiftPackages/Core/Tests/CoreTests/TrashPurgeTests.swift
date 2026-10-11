import XCTest
@testable import UPasswordsCore

/// 回收站两段式语义锁定(见 Cloud/DESIGN.md §4.4):
/// 从回收站删除 → 内容即刻硬清除,仅保留 (id, time) 墓碑标记且前端不可感知;
/// 标记长期保留,抑制长期离线设备合并时复活已删项。
final class TrashPurgeTests: XCTestCase {

    func testTrashDeleteStripsContentAndRegistersMarker() {
        var db = PasswordDatabase()
        var card = Card(id: 1)
        card.title = "Secret"
        card.trashed = true
        db.cards.append(card)

        db.deleteCardPermanently(id: 1)

        // 内容即刻清除(密码数据不存在了),仅剩几字节墓碑标记
        XCTAssertTrue(db.cards.isEmpty, "content must be purged immediately")
        XCTAssertEqual(db.ghosts.map(\.id), [1], "minimal (id,time) marker must remain")
        XCTAssertNil(db.card(id: 1), "deleted item invisible to all lookups")
    }

    func testMarkerSuppressesResurrectionFromOfflinePeer() {
        var local = PasswordDatabase()
        local.deleteCardPermanently(id: 7, now: Date())

        // 对端(离线超过一年,从未见过删除)仍持有该条目的活动副本
        var peer = PasswordDatabase()
        var stale = Card(id: 7)
        stale.title = "Old copy"
        peer.cards.append(stale)

        local.merge(with: peer)

        XCTAssertNil(local.card(id: 7), "tombstone must suppress resurrection")
        XCTAssertNotNil(local.ghosts.first { $0.id == 7 }, "marker must survive the merge")
    }

    func testMarkersAccumulateAcrossMerges() {
        var a = PasswordDatabase()
        a.deleteCardPermanently(id: 3, now: Date())
        var b = PasswordDatabase()
        b.deleteCardPermanently(id: 4, now: Date())

        a.merge(with: b)

        XCTAssertEqual(a.ghosts.map(\.id).sorted(), [3, 4], "markers are union-merged")
    }

    func testLabelDeletionRegistersMarker() {
        var db = PasswordDatabase()
        db.labels.append(CardLabel(id: 11, name: "Work"))

        db.deleteLabelPermanently(id: 11)

        XCTAssertTrue(db.labels.isEmpty)
        XCTAssertEqual(db.ghosts.map(\.id), [11])
    }

    /// 时间戳由系统维护、秒级精度、XML 往返无损(用户不可手改的基线保证)。
    func testTimestampsRoundTripExact() throws {
        var db = PasswordDatabase()
        var card = Card(id: 9)
        card.created = 1_700_000_000
        card.modified = 1_700_000_123
        db.cards.append(card)

        let parsed = try PasswordDatabase.parse(db.xmlData())

        XCTAssertEqual(parsed.card(id: 9)?.created, 1_700_000_000)
        XCTAssertEqual(parsed.card(id: 9)?.modified, 1_700_000_123)
    }
}
