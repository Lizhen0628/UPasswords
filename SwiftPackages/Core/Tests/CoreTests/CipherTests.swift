import CryptoKit
import XCTest
@testable import UPasswordsCore

final class CipherTests: XCTestCase {
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

    func testBrowserEncryptedSnapshotMatchesNativeContainerAndXML() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let vectorURL = repositoryRoot
            .appendingPathComponent("Contracts/test-vectors/browser-encrypted-snapshot.json")
        let vectorData = try Data(contentsOf: vectorURL)
        let vector = try XCTUnwrap(try JSONSerialization.jsonObject(with: vectorData) as? [String: String])
        let vaultKeyData = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(vector["vaultKey"])))
        let body = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(vector["body"])))
        let expectedXML = try XCTUnwrap(vector["xml"])
        let plaintext = try DatabaseCipher.decryptBody(
            body,
            vaultKey: SymmetricKey(data: vaultKeyData))

        XCTAssertEqual(String(data: plaintext, encoding: .utf8), expectedXML)
        let database = try PasswordDatabase.parse(plaintext)
        XCTAssertEqual(database.cards.first?.title, "Browser copy")
    }

    /// 本体:库密钥加解密往返;错误库密钥解不开。
    func testBodyRoundTrip() throws {
        let vek = DatabaseCipher.generateVaultKey()
        let plain = Data("vault-body".utf8)
        let enc = try DatabaseCipher.encryptBody(plain, vaultKey: vek)
        XCTAssertTrue(DatabaseCipher.isV2Container(enc))
        let dec = try DatabaseCipher.decryptBody(enc, vaultKey: vek)
        XCTAssertEqual(dec, plain)
        let other = DatabaseCipher.generateVaultKey()
        XCTAssertThrowsError(try DatabaseCipher.decryptBody(enc, vaultKey: other))
    }

    /// 加密输出非确定:随机 nonce 使同明文每次密文不同。
    func testEncryptBodyIsNonDeterministic() throws {
        let vek = DatabaseCipher.generateVaultKey()
        let p = Data("payload".utf8)
        let a = try DatabaseCipher.encryptBody(p, vaultKey: vek)
        let b = try DatabaseCipher.encryptBody(p, vaultKey: vek)
        XCTAssertNotEqual(a, b, "random nonce must make ciphertexts differ")
    }

    /// 非 v2 数据一律拒绝(垃圾/空/截断)。
    func testV2MagicRejected() {
        XCTAssertFalse(DatabaseCipher.isV2Container(Data("not a database".utf8)))
        XCTAssertFalse(DatabaseCipher.isV2Container(Data()))
        XCTAssertFalse(DatabaseCipher.isV2Container(Data("UPWDB2".utf8)))
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
}
