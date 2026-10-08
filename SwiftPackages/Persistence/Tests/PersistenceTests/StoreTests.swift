import XCTest
import UPasswordsCore
@testable import UPasswordsPersistence

final class StoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("upw-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testCreateLoadSaveBackupRestoreRenameDelete() throws {
        let store = DatabaseStore(root: tempDir)
        try store.create(name: "Alpha", password: "pw1", now: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(store.exists("Alpha"))

        var db = try store.load(name: "Alpha", password: "pw1")
        XCTAssertEqual(db.templateCards.count, 16)
        var card = Card(id: 900)
        card.title = "Added"
        db.cards.append(card)
        try store.save(db, name: "Alpha", password: "pw1")

        let reloaded = try store.load(name: "Alpha", password: "pw1")
        XCTAssertEqual(reloaded.card(id: 900)?.title, "Added")

        XCTAssertThrowsError(try store.load(name: "Alpha", password: "bad"))

        try store.backup(name: "Alpha", password: "pw1", now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(store.backups(name: "Alpha").count, 1)

        try store.rename("Alpha", to: "Beta")
        XCTAssertFalse(store.exists("Alpha"))
        XCTAssertTrue(store.exists("Beta"))

        try store.delete(name: "Beta")
        XCTAssertFalse(store.exists("Beta"))
    }

    func testInvalidNamesRejected() {
        let store = DatabaseStore(root: tempDir)
        XCTAssertThrowsError(try store.create(name: "bad name!", password: "x"))
        XCTAssertThrowsError(try store.create(name: "", password: "x"))
    }

    func testEncryptedFileFormat() throws {
        let store = DatabaseStore(root: tempDir)
        try store.create(name: "Gamma", password: "pw")
        let data = try Data(contentsOf: store.url(for: "Gamma"))
        XCTAssertTrue(DatabaseCipher.checkFileMagic(data), "on-disk container uses DatabaseCipher format")
        XCTAssertNil(String(data: data, encoding: .utf8).flatMap { $0.contains("<database>") ? $0 : nil },
                     "plaintext XML must not appear in the container")
    }
}
