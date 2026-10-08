import CryptoKit
import XCTest
@testable import UPasswordsCore

final class PasskeyTests: XCTestCase {

    // MARK: authenticatorData 布局

    func testAuthenticatorDataLayout() throws {
        let authData = WebAuthn.authenticatorData(relyingParty: "example.com",
                                                  userVerified: true, signCount: 0x01020304)
        XCTAssertEqual(authData.count, 32 + 1 + 4)
        // rpIDHash = SHA-256("example.com")
        let expectHash = Data(SHA256.hash(data: Data("example.com".utf8)))
        XCTAssertEqual(authData.prefix(32), expectHash)
        // flags: UP|UV = 0x05
        XCTAssertEqual(authData[32], 0x05)
        // signCount 大端
        XCTAssertEqual(Array(authData.suffix(4)), [0x01, 0x02, 0x03, 0x04])
    }

    func testAuthenticatorDataRegistrationFlags() throws {
        let pair = WebAuthn.generateKeyPair()
        let credID = WebAuthn.makeCredentialID()
        let attested = try WebAuthn.attestedCredentialData(credentialID: credID,
                                                           publicKeyX963: pair.publicKeyX963)
        let authData = WebAuthn.authenticatorData(relyingParty: "example.com", userVerified: true,
                                                  signCount: 0, attestedCredentialData: attested)
        // flags: UP|UV|AT = 0x45
        XCTAssertEqual(authData[32], 0x45)
        XCTAssertEqual(authData.count, 37 + attested.count)
        // attestedCredentialData 内部布局:AAGUID(16 零) ‖ len ‖ credID ‖ COSE
        XCTAssertEqual(attested.prefix(16), Data(count: 16))
        XCTAssertEqual(Array(attested[16..<18]), [0x00, 0x20]) // 32 字节 credID
        XCTAssertEqual(attested.subdata(in: 18..<50), credID)
    }

    // MARK: CBOR / attestationObject

    func testAttestationObjectCBOR() throws {
        let authData = Data([0xAA, 0xBB])
        let obj = WebAuthn.attestationObject(authData: authData)
        // a3 63 66 6d 74 64 6e 6f 6e 65 67 61 74 74 53 74 6d 74 a0 68 61 75 74 68 44 61 74 61 42 aa bb
        var expect = Data([0xa3])
        expect.append(contentsOf: [0x63]) ; expect.append(contentsOf: "fmt".utf8)
        expect.append(contentsOf: [0x64]) ; expect.append(contentsOf: "none".utf8)
        expect.append(contentsOf: [0x67]) ; expect.append(contentsOf: "attStmt".utf8)
        expect.append(0xa0)
        expect.append(contentsOf: [0x68]) ; expect.append(contentsOf: "authData".utf8)
        expect.append(contentsOf: [0x42, 0xaa, 0xbb])
        XCTAssertEqual(obj, expect)
    }

    func testCOSEPublicKey() throws {
        // 固定 65 字节公钥(04 ‖ X(0x01×32) ‖ Y(0x02×32))
        var x963 = Data([0x04])
        x963.append(contentsOf: [UInt8](repeating: 0x01, count: 32))
        x963.append(contentsOf: [UInt8](repeating: 0x02, count: 32))
        let cose = try WebAuthn.cosePublicKey(x963: x963)
        // a5 01 02 03 26 20 01 21 58 20 <x> 22 58 20 <y>
        XCTAssertEqual(cose[0], 0xa5)
        XCTAssertEqual(Array(cose[1..<3]), [0x01, 0x02])   // 1: 2
        XCTAssertEqual(Array(cose[3..<5]), [0x03, 0x26])   // 3: -7
        XCTAssertEqual(Array(cose[5..<7]), [0x20, 0x01])   // -1: 1
        XCTAssertEqual(Array(cose[7..<9]), [0x21, 0x58])   // -2: bytes(32)
        XCTAssertEqual(cose[9], 0x20)
        XCTAssertEqual(cose.subdata(in: 10..<42), Data(repeating: 0x01, count: 32))
        XCTAssertEqual(Array(cose[42..<44]), [0x22, 0x58]) // -3: bytes(32)
        XCTAssertEqual(cose[44], 0x20)
        XCTAssertEqual(cose.subdata(in: 45..<77), Data(repeating: 0x02, count: 32))
        XCTAssertEqual(cose.count, 77)
    }

    // MARK: 签名往返

    func testAssertionSignatureRoundTrip() throws {
        let pair = WebAuthn.generateKeyPair()
        let authData = WebAuthn.authenticatorData(relyingParty: "example.com",
                                                  userVerified: true, signCount: 1)
        let clientDataHash = Data(SHA256.hash(data: Data("client-data-json".utf8)))
        let der = try WebAuthn.assertionSignature(privateKeyRaw: pair.privateKey,
                                                  authData: authData, clientDataHash: clientDataHash)
        let publicKey = try P256.Signing.PublicKey(x963Representation: pair.publicKeyX963)
        let signature = try P256.Signing.ECDSASignature(derRepresentation: der)
        var message = authData
        message.append(clientDataHash)
        XCTAssertTrue(publicKey.isValidSignature(signature, for: message))
    }

    func testGenerateKeyPairRawRoundTrip() throws {
        let pair = WebAuthn.generateKeyPair()
        // 存储的 rawRepresentation 必须能重建私钥,且公钥一致
        let rebuilt = try P256.Signing.PrivateKey(rawRepresentation: pair.privateKey)
        XCTAssertEqual(rebuilt.publicKey.x963Representation, pair.publicKeyX963)
    }

    // MARK: 凭据 JSON 与卡片字段

    func testPasskeyCardRoundTrip() {
        var card = Card(id: 1)
        XCTAssertNil(card.passkey)
        let passkey = Passkey(credentialID: Data([1, 2, 3]), relyingParty: "example.com",
                              userHandle: Data([4, 5]), userName: "liz",
                              privateKey: Data([9, 9]), signCount: 7, created: 123)
        card.setPasskey(passkey)
        XCTAssertEqual(card.passkey, passkey)
        // 覆盖更新而非追加字段
        var updated = passkey
        updated.signCount = 8
        card.setPasskey(updated)
        XCTAssertEqual(card.passkey?.signCount, 8)
        XCTAssertEqual(card.fields.filter { $0.name == Card.passkeyFieldName }.count, 1)
    }
}
