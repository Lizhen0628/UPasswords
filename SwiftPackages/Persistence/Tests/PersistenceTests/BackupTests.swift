import XCTest
import UPasswordsCore
@testable import UPasswordsPersistence

/// 备份链路的精细化测试:清理(keep=10)、恢复到新库名、跨恢复读取。
/// DatabaseStore 在拆包时改动过(去 AppKit、public 化),此处钉住其行为。
final class BackupTests: XCTestCase {
    private var tempDir: URL!
    private var store: DatabaseStore!

    override func setUp() {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("upw-backup-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = DatabaseStore(root: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testPruneKeepsTenMostRecent() throws {
        try store.create(name: "Alpha", password: "pw", now: Date(timeIntervalSince1970: 0))
        for i in 0..<13 {
            try store.backup(name: "Alpha", password: "pw", now: Date(timeIntervalSince1970: Double(100 + i)))
        }
        let kept = store.backups(name: "Alpha")
        XCTAssertEqual(kept.count, 10, "keep limit is 10")
        // 最新备份排最前:最后一次(时间戳 112)对应的文件名必须保留
        let newest = DatabaseStore.backupStampFormatter.string(from: Date(timeIntervalSince1970: 112))
        XCTAssertTrue(kept.first?.lastPathComponent == "\(newest).upw", "newest backup must sort first and survive pruning")
    }

    func testRestoreIntoNewNameRoundTrip() throws {
        try store.create(name: "Alpha", password: "pw", now: Date(timeIntervalSince1970: 0))
        var db = try store.load(name: "Alpha", password: "pw")
        var card = Card(id: 777, title: "Restored")
        db.cards.append(card)
        try store.save(db, name: "Alpha", password: "pw")
        try store.backup(name: "Alpha", password: "pw", now: Date(timeIntervalSince1970: 50))

        let backup = try XCTUnwrap(store.backups(name: "Alpha").first)
        try store.restore(backup: backup, to: "Beta")
        XCTAssertTrue(store.exists("Beta"))
        let restored = try store.load(name: "Beta", password: "pw")
        XCTAssertEqual(restored.card(id: 777)?.title, "Restored", "restored copy must contain pre-backup edits")
    }

    func testRestoreRejectsMagicMismatch() throws {
        try store.create(name: "Alpha", password: "pw", now: Date(timeIntervalSince1970: 0))
        let foreign = tempDir.appendingPathComponent("foreign.upw")
        try Data("plaintext junk".utf8).write(to: foreign)
        XCTAssertThrowsError(try store.restore(backup: foreign, to: "Alpha2"))
        XCTAssertFalse(store.exists("Alpha2"), "rejected restore must not write the target")
    }

    func testDeleteBackupConfinedToOwnDirectory() throws {
        try store.create(name: "Alpha", password: "pw", now: Date(timeIntervalSince1970: 0))
        try store.backup(name: "Alpha", password: "pw", now: Date(timeIntervalSince1970: 1))
        let outside = tempDir.appendingPathComponent("outside.upw")
        try Data("x".utf8).write(to: outside)
        XCTAssertThrowsError(try store.deleteBackup(outside, name: "Alpha"),
                             "deleteBackup must reject paths outside the database's backup dir")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }
}
