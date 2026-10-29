import XCTest
@testable import UPasswordsPersistence

final class AttachmentSyncCipherTests: XCTestCase {
    func testEncryptAndDecryptBindCiphertextToAttachmentAndVersion() throws {
        let key = RowSyncKey(raw: Data(repeating: 0x31, count: 32))
        let attachmentID = UUID()
        let version = UUID()
        let plaintext = Data("private attachment contents".utf8)
        let encrypted = try AttachmentSyncCipher.encrypt(
            data: plaintext, key: key, attachmentID: attachmentID, contentVersion: version)

        XCTAssertNotEqual(encrypted.cipher, plaintext)
        XCTAssertEqual(try AttachmentSyncCipher.decrypt(
            cipher: encrypted.cipher, dekWrapped: encrypted.dekWrapped, key: key,
            attachmentID: attachmentID, contentVersion: version), plaintext)
        XCTAssertThrowsError(try AttachmentSyncCipher.decrypt(
            cipher: encrypted.cipher, dekWrapped: encrypted.dekWrapped, key: key,
            attachmentID: UUID(), contentVersion: version))
        XCTAssertThrowsError(try AttachmentSyncCipher.decrypt(
            cipher: encrypted.cipher, dekWrapped: encrypted.dekWrapped, key: key,
            attachmentID: attachmentID, contentVersion: UUID()))
    }

    func testRewrapChangesOnlyTheDEKWrapperAcrossVaultKeyRotation() throws {
        let oldKey = RowSyncKey(raw: Data(repeating: 0x41, count: 32))
        let newKey = RowSyncKey(raw: Data(repeating: 0x52, count: 32))
        let attachmentID = UUID()
        let version = UUID()
        let plaintext = Data(repeating: 0x63, count: 4096)
        let encrypted = try AttachmentSyncCipher.encrypt(
            data: plaintext, key: oldKey, attachmentID: attachmentID, contentVersion: version)

        let rewrapped = try AttachmentSyncCipher.rewrap(
            encrypted.dekWrapped, oldKey: oldKey, newKey: newKey,
            attachmentID: attachmentID, contentVersion: version)

        XCTAssertNotEqual(rewrapped, encrypted.dekWrapped)
        XCTAssertEqual(try AttachmentSyncCipher.decrypt(
            cipher: encrypted.cipher, dekWrapped: rewrapped, key: newKey,
            attachmentID: attachmentID, contentVersion: version), plaintext)
        XCTAssertThrowsError(try AttachmentSyncCipher.decrypt(
            cipher: encrypted.cipher, dekWrapped: rewrapped, key: oldKey,
            attachmentID: attachmentID, contentVersion: version))
    }

    func testRejectsNonVaultSizedKeys() {
        let invalidKey = RowSyncKey(raw: Data(repeating: 0x31, count: 16))
        XCTAssertThrowsError(try AttachmentSyncCipher.encrypt(
            data: Data([1]), key: invalidKey, attachmentID: UUID(), contentVersion: UUID()))
    }
}
