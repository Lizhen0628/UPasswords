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

        let (loaded, vek) = try store.loadUnlocked(name: "Alpha", password: "pw1")
        var db = loaded
        XCTAssertEqual(db.templateCards.count, 16)
        var card = Card(id: 900)
        card.title = "Added"
        db.cards.append(card)
        try store.save(db, name: "Alpha", vaultKey: vek)

        let reloaded = try store.load(name: "Alpha", password: "pw1")
        XCTAssertEqual(reloaded.card(id: 900)?.title, "Added")

        XCTAssertThrowsError(try store.load(name: "Alpha", password: "bad"))

        try store.backup(name: "Alpha", now: Date(timeIntervalSince1970: 100))
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

    /// 非 v2 容器拒绝加载;v2 缺信封报专用错误。
    func testLoadRejectsNonV2AndMissingEnvelope() throws {
        let store = DatabaseStore(root: tempDir)
        // 垃圾文件:报格式错误
        try Data("garbage".utf8).write(to: store.url(for: "Junk"))
        XCTAssertThrowsError(try store.loadUnlocked(name: "Junk", password: "pw")) { error in
            XCTAssertTrue("\(error)".contains("格式") || "\(error)".contains("format"))
        }
        // 合法 v2 本体但无信封:报信封缺失
        let vek = DatabaseCipher.generateVaultKey()
        let body = try DatabaseCipher.encryptBody(PasswordDatabase.createDefault().xmlData(), vaultKey: vek)
        try body.write(to: store.url(for: "NoKey"))
        XCTAssertThrowsError(try store.loadUnlocked(name: "NoKey", password: "pw")) { error in
            XCTAssertTrue("\(error)".contains("信封") || "\(error)".contains("envelope"))
        }
    }

    /// saveEnvelope 保留原始字节(含 changedAt),非法信封拒绝写入。
    func testSaveEnvelope() throws {
        let store = DatabaseStore(root: tempDir)
        let vek = DatabaseCipher.generateVaultKey()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let envelope = try DatabaseCipher.wrapVaultKey(vek, password: "pw", changedAt: t0)
        try store.saveEnvelope(envelope, for: "Env")
        XCTAssertEqual(store.envelopeData(for: "Env"), envelope)
        XCTAssertThrowsError(try store.saveEnvelope(Data("junk-junk-junk".utf8), for: "Env"))
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

    /// 密钥轮换:本体以全新 VEK 重加密,新密码可用、旧密码失效,
    /// 且旧 VEK 解不开轮换后的新本体(旧材料对新数据失效)。
    func testKeyRotationInvalidatesOldMaterial() throws {
        let store = DatabaseStore(root: tempDir)
        try store.create(name: "Rotate", password: "old")
        var (db, oldVek) = try store.loadUnlocked(name: "Rotate", password: "old")
        db.cards.append(Card(id: 901, title: "AfterRotation"))
        let bodyBefore = try Data(contentsOf: store.url(for: "Rotate"))
        // 旧密文用旧 VEK 可解(轮换前副本即泄露风险的等价物)
        _ = try DatabaseCipher.decryptBody(bodyBefore, vaultKey: oldVek)

        let newVek = DatabaseCipher.generateVaultKey()
        try store.save(db, name: "Rotate", vaultKey: newVek)
        try store.rewrap(name: "Rotate", vaultKey: newVek, newPassword: "new")

        let bodyAfter = try Data(contentsOf: store.url(for: "Rotate"))
        XCTAssertNotEqual(bodyBefore, bodyAfter, "body re-encrypted")
        XCTAssertThrowsError(try store.loadUnlocked(name: "Rotate", password: "old"))
        // 旧 VEK 解不开新本体:持有旧密文+旧密钥者无法读取轮换后内容
        XCTAssertThrowsError(try DatabaseCipher.decryptBody(bodyAfter, vaultKey: oldVek))
        let (db2, _) = try store.loadUnlocked(name: "Rotate", password: "new")
        XCTAssertEqual(db2.cards.last?.title, "AfterRotation", "content survives rotation")
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

    /// 本地文件对还原(新设备向导):外部 .upw/.upwkey 校验解密后落为新本地库;
    /// 错误密码/重名/坏信封在写盘前即被拒,不留半成品。
    func testRestoreFromLocalFilePair() throws {
        let store = DatabaseStore(root: tempDir)
        try store.create(name: "Source", password: "pw1")
        let (loaded, vek) = try store.loadUnlocked(name: "Source", password: "pw1")
        var db = loaded
        db.cards.append(Card(id: 902, title: "Migrated"))
        try store.save(db, name: "Source", vaultKey: vek)

        // 模拟"从其他设备拷来的一对文件":独立目录、任意文件名
        let incoming = tempDir.appendingPathComponent("incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        let body = incoming.appendingPathComponent("Restored.upw")
        let key = incoming.appendingPathComponent("Restored.upwkey")
        try FileManager.default.copyItem(at: store.url(for: "Source"), to: body)
        try FileManager.default.copyItem(at: store.keyURL(for: "Source"), to: key)

        let file = try store.restore(body: body, envelope: key, name: "Restored", password: "pw1")
        XCTAssertTrue(store.exists("Restored"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.keyURL(for: "Restored").path))
        XCTAssertEqual(file.name, "Restored")
        let migrated = try store.load(name: "Restored", password: "pw1")
        XCTAssertEqual(migrated.card(id: 902)?.title, "Migrated", "content survives local restore")

        // 错误密码:解信封失败,不落盘
        XCTAssertThrowsError(try store.restore(body: body, envelope: key, name: "WrongPw", password: "bad"))
        XCTAssertFalse(store.exists("WrongPw"))

        // 与现有库重名:拒绝
        XCTAssertThrowsError(try store.restore(body: body, envelope: key, name: "Restored", password: "pw1"))

        // 非法库名(如备份戳含连字符):拒绝
        XCTAssertThrowsError(try store.restore(body: body, envelope: key, name: "2026-0101", password: "pw1"))

        // 字节不是合法信封:拒绝且不落盘
        let stray = incoming.appendingPathComponent("Stray.upwkey")
        try Data([0x01, 0x02]).write(to: stray)
        XCTAssertThrowsError(try store.restore(body: body, envelope: stray, name: "Stray", password: "pw1"))
        XCTAssertFalse(store.exists("Stray"))
    }
}
