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
