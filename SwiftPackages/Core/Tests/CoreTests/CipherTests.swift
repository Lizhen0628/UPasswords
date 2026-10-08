import XCTest
@testable import UPasswordsCore

final class CipherTests: XCTestCase {
    func testRoundTrip() throws {
        let plain = Data("<?xml version=\"1.0\"?><database><card title=\"卡\" id=\"1\"/></database>".utf8)
        let enc = try DatabaseCipher.encryptedData(plain, password: "s3cret!")
        XCTAssertGreaterThan(enc.count, plain.count)
        XCTAssertTrue(DatabaseCipher.checkFileMagic(enc))
        let dec = try DatabaseCipher.decryptedData(enc, password: "s3cret!")
        XCTAssertEqual(dec, plain)
    }

    func testWrongPasswordFails() throws {
        let enc = try DatabaseCipher.encryptedData(Data("hello".utf8), password: "right")
        XCTAssertThrowsError(try DatabaseCipher.decryptedData(enc, password: "wrong")) { error in
            XCTAssertTrue("\(error)".contains("密码错误") || "\(error)".contains("Wrong password"))
        }
    }

    func testMagicRejected() {
        XCTAssertFalse(DatabaseCipher.checkFileMagic(Data("not a database".utf8)))
        XCTAssertFalse(DatabaseCipher.checkFileMagic(Data()))
    }

    func testEncryptedOutputIsNonDeterministic() throws {
        let p = Data("payload".utf8)
        let a = try DatabaseCipher.encryptedData(p, password: "x")
        let b = try DatabaseCipher.encryptedData(p, password: "x")
        XCTAssertNotEqual(a, b, "random salt/nonce must make ciphertexts differ")
    }

    func testKeyDerivationDeterministic() {
        let salt = Data(repeating: 7, count: 16)
        let k1 = DatabaseCipher.deriveKey(password: "pw", salt: salt, iterations: 1000)
        let k2 = DatabaseCipher.deriveKey(password: "pw", salt: salt, iterations: 1000)
        XCTAssertEqual(k1.withUnsafeBytes { Data($0) }, k2.withUnsafeBytes { Data($0) })
        let k3 = DatabaseCipher.deriveKey(password: "pw2", salt: salt, iterations: 1000)
        XCTAssertNotEqual(k1.withUnsafeBytes { Data($0) }, k3.withUnsafeBytes { Data($0) })
    }
}

// MARK: - v2 信封加密

final class CipherV2Tests: XCTestCase {

    /// 本体:库密钥加解密往返;错误库密钥解不开。
    func testBodyRoundTrip() throws {
        let vek = DatabaseCipher.generateVaultKey()
        let plain = Data("vault-body".utf8)
        let enc = try DatabaseCipher.encryptBody(plain, vaultKey: vek)
        XCTAssertTrue(DatabaseCipher.isV2Container(enc))
        XCTAssertFalse(DatabaseCipher.checkFileMagic(enc))  // v1 魔数不同
        let dec = try DatabaseCipher.decryptBody(enc, vaultKey: vek)
        XCTAssertEqual(dec, plain)
        let other = DatabaseCipher.generateVaultKey()
        XCTAssertThrowsError(try DatabaseCipher.decryptBody(enc, vaultKey: other))
    }

    /// 信封:主密码包裹/解出库密钥;错密码抛错;changedAt 可读。
    func testEnvelopeRoundTrip() throws {
        let vek = DatabaseCipher.generateVaultKey()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let env = try DatabaseCipher.wrapVaultKey(vek, password: "pw123", changedAt: t0)
        XCTAssertEqual(env.count, 100)
        let unwrapped = try DatabaseCipher.unwrapVaultKey(env, password: "pw123")
        XCTAssertEqual(unwrapped.withUnsafeBytes { Data($0) }, vek.withUnsafeBytes { Data($0) })
        XCTAssertThrowsError(try DatabaseCipher.unwrapVaultKey(env, password: "wrong"))
        XCTAssertEqual(DatabaseCipher.envelopeChangedAt(env)?.timeIntervalSince1970 ?? 0,
                       t0.timeIntervalSince1970, accuracy: 0.001)
    }

    /// 改密语义:同一库密钥换密码重裹信封,本体完全不需要动。
    func testRewrapKeepsBodyUsable() throws {
        let vek = DatabaseCipher.generateVaultKey()
        let body = try DatabaseCipher.encryptBody(Data("cards".utf8), vaultKey: vek)
        let envOld = try DatabaseCipher.wrapVaultKey(vek, password: "old")
        let envNew = try DatabaseCipher.wrapVaultKey(vek, password: "new")
        // 旧密码解不开新信封
        XCTAssertThrowsError(try DatabaseCipher.unwrapVaultKey(envNew, password: "old"))
        // 新密码解开新信封 → 同一库密钥 → 本体照样解开
        let vek2 = try DatabaseCipher.unwrapVaultKey(envNew, password: "new")
        XCTAssertEqual(try DatabaseCipher.decryptBody(body, vaultKey: vek2), Data("cards".utf8))
        XCTAssertEqual(try DatabaseCipher.decryptBody(body, vaultKey: vek), Data("cards".utf8))
        _ = envOld
    }

    /// v1 容器不受 v2 影响:旧格式照常加解密,且不会被误判为 v2。
    func testV1Unaffected() throws {
        let enc = try DatabaseCipher.encryptedData(Data("legacy".utf8), password: "pw")
        XCTAssertFalse(DatabaseCipher.isV2Container(enc))
        XCTAssertTrue(DatabaseCipher.checkFileMagic(enc))
        XCTAssertEqual(try DatabaseCipher.decryptedData(enc, password: "pw"), Data("legacy".utf8))
    }
}
