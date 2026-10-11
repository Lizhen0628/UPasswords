import XCTest
import UPasswordsCore
@testable import UPasswordsPersistence

/// SyncConflict 冲突判定:本地与云端以上次成功同步的基线哈希为参照,
/// **双方都变化**才判冲突(交由用户决定覆盖方向);单侧变化、首次同步
/// (无基线)、云端无文件均沿用条目级合并。
final class SyncConflictTests: XCTestCase {

    private let baseline = SyncConflict.Baselines(localXMLHash: "base-local", remoteXMLHash: "base-remote")

    /// 双方都有修改 → 冲突,交由用户决定覆盖方向。
    func testBothChangedSinceBaselineIsConflict() {
        let verdict = SyncConflict.evaluate(
            localXMLHash: "new-local",
            remoteXMLHash: "new-remote",
            baselines: baseline)
        XCTAssertEqual(verdict, .conflict)
    }

    /// 仅本地修改(云端未变)→ 沿用合并,等同上传本地。
    func testOnlyLocalChangedMerges() {
        let verdict = SyncConflict.evaluate(
            localXMLHash: "new-local",
            remoteXMLHash: "base-remote",
            baselines: baseline)
        XCTAssertEqual(verdict, .merge)
    }

    /// 仅云端修改(本地未变)→ 沿用合并,等同拉取云端。
    func testOnlyRemoteChangedMerges() {
        let verdict = SyncConflict.evaluate(
            localXMLHash: "base-local",
            remoteXMLHash: "new-remote",
            baselines: baseline)
        XCTAssertEqual(verdict, .merge)
    }

    /// 双方都没变(重复同步)→ 合并(空操作)。
    func testNeitherChangedMerges() {
        let verdict = SyncConflict.evaluate(
            localXMLHash: "base-local",
            remoteXMLHash: "base-remote",
            baselines: baseline)
        XCTAssertEqual(verdict, .merge)
    }

    /// 首次同步(基线缺失)→ 无从比较,沿用合并,不打扰用户。
    func testFirstSyncWithoutBaselinesMerges() {
        let verdict = SyncConflict.evaluate(
            localXMLHash: "new-local",
            remoteXMLHash: "new-remote",
            baselines: .init(localXMLHash: nil, remoteXMLHash: nil))
        XCTAssertEqual(verdict, .merge)
    }

    /// 云端还没有文件(download 返回 nil 语义)→ 直接上传本地,非冲突。
    func testMissingRemoteFileMerges() {
        let verdict = SyncConflict.evaluate(
            localXMLHash: "new-local",
            remoteXMLHash: nil,
            baselines: baseline)
        XCTAssertEqual(verdict, .merge)
    }

    /// 回归:对端把**相同内容**重新加密上传(密文 nonce 变了,明文没变)
    /// → 远端内容哈希仍等于基线,不算远端修改;即便本地此时也有真修改,
    /// 也只是"仅本地修改"的合并,不得弹冲突(旧版密文域比较会误报)。
    func testPeerReuploadWithSameContentIsNotRemoteChange() {
        let verdict = SyncConflict.evaluate(
            localXMLHash: "new-local",
            remoteXMLHash: "base-remote",
            baselines: baseline)
        XCTAssertEqual(verdict, .merge)
    }

    /// 编辑后明文 XML 哈希必须变化,否则本地侧的"是否改过"检测失效。
    func testXmlHashChangesAfterLocalEdit() {
        var db = PasswordDatabase()
        let before = SyncConflict.sha256Hex(db.xmlData())
        db.cards.append(Card(id: 1, title: "Conflict Probe"))
        let after = SyncConflict.sha256Hex(db.xmlData())
        XCTAssertNotEqual(before, after)
    }

    /// SHA-256 十六进制编码对齐已知向量("abc")。
    func testSha256HexKnownVector() {
        XCTAssertEqual(
            SyncConflict.sha256Hex(Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
