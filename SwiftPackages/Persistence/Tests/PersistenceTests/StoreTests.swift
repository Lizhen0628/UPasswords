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
        XCTAssertTrue(DatabaseCipher.isV2Container(data), "on-disk container uses v2 envelope format")
        // 信封同时生成,且可以用主密码解开出库密钥
        let envelope = try Data(contentsOf: store.keyURL(for: "Gamma"))
        let vek = try DatabaseCipher.unwrapVaultKey(envelope, password: "pw")
        let plain = try DatabaseCipher.decryptBody(data, vaultKey: vek)
        XCTAssertTrue(String(data: plain, encoding: .utf8)?.contains("<database>") == true)
        XCTAssertNil(String(data: data, encoding: .utf8).flatMap { $0.contains("<database>") ? $0 : nil },
                     "plaintext XML must not appear in the container")
    }
}

// MARK: - v2 信封加密(Store 层)

final class StoreV2Tests: XCTestCase {
    private var tempDir: URL!
    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UPWStoreV2-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// v1 旧库加载后自动迁移 v2:本体换魔数、生成信封、数据不变。
    func testV1MigrationOnLoad() throws {
        let store = DatabaseStore(root: tempDir)
        // 手写 v1 库(模拟旧版遗留)
        let db = PasswordDatabase.createDefault()
        let v1 = try DatabaseCipher.encryptedData(db.xmlData(), password: "pw")
        try v1.write(to: store.url(for: "Legacy"))
        let (loaded, vek) = try store.loadUnlocked(name: "Legacy", password: "pw")
        XCTAssertEqual(loaded.cards.count, db.cards.count)
        let onDisk = try Data(contentsOf: store.url(for: "Legacy"))
        XCTAssertTrue(DatabaseCipher.isV2Container(onDisk))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.keyURL(for: "Legacy").path))
        // 迁移后可用库密钥直接读
        XCTAssertEqual(try DatabaseCipher.decryptBody(onDisk, vaultKey: vek), db.xmlData())
    }

    /// 改密只动信封:本体字节不变,旧密码失效、新密码可用。
    func testRewrapOnlyTouchesEnvelope() throws {
        let store = DatabaseStore(root: tempDir)
        try store.create(name: "Delta", password: "old")
        let (db, vek) = try store.loadUnlocked(name: "Delta", password: "old")
        let bodyBefore = try Data(contentsOf: store.url(for: "Delta"))
        try store.rewrap(name: "Delta", vaultKey: vek, newPassword: "new")
        XCTAssertEqual(bodyBefore, try Data(contentsOf: store.url(for: "Delta")), "body untouched")
        XCTAssertThrowsError(try store.loadUnlocked(name: "Delta", password: "old"))
        let (db2, _) = try store.loadUnlocked(name: "Delta", password: "new")
        XCTAssertEqual(db2.cards.count, db.cards.count)
    }

    /// 保存只需库密钥(改密后无需主密码即可保存)。
    func testSaveWithVaultKey() throws {
        let store = DatabaseStore(root: tempDir)
        try store.create(name: "Echo", password: "pw")
        let (db, vek) = try store.loadUnlocked(name: "Echo", password: "pw")
        try store.save(db, name: "Echo", vaultKey: vek)
        let (db2, _) = try store.loadUnlocked(name: "Echo", password: "pw")
        XCTAssertEqual(db2.cards.count, db.cards.count)
    }

    /// 删除/重命名连信封装一起处理。
    func testKeyLifecycleWithRenameDelete() throws {
        let store = DatabaseStore(root: tempDir)
        try store.create(name: "Foxtrot", password: "pw")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.keyURL(for: "Foxtrot").path))
        try store.rename("Foxtrot", to: "Golf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.keyURL(for: "Golf").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.keyURL(for: "Foxtrot").path))
        try store.delete(name: "Golf")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.keyURL(for: "Golf").path))
    }
}
