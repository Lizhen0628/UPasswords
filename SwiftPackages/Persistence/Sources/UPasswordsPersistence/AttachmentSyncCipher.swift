import CryptoKit
import Foundation
import UPasswordsCore

/// Encrypted attachment bytes and their VEK-wrapped per-attachment data key.
public struct EncryptedAttachment: Equatable {
    /// AES-GCM ciphertext containing nonce, encrypted bytes, and authentication tag.
    public let cipher: Data
    /// AES-GCM wrapped 32-byte data encryption key.
    public let dekWrapped: Data

    /// Creates the result of encrypting one attachment version.
    public init(cipher: Data, dekWrapped: Data) {
        self.cipher = cipher
        self.dekWrapped = dekWrapped
    }
}

/// Encrypts attachment versions independently from their parent row payload.
public enum AttachmentSyncCipher {
    private static let aadPrefix = "UPW-ATTACHMENT-VERSION-V1:"
    private static let dekDomain = ":DEK"

    private enum CipherError: Error {
        case invalidVaultKey
        case authenticationFailed
        case encryptionFailed
    }

    /// Encrypts content with a random DEK and wraps that key with the vault key.
    ///
    /// - Parameters:
    ///   - data: Attachment plaintext bytes.
    ///   - key: Current 32-byte vault encryption key.
    ///   - attachmentID: Stable logical attachment identity.
    ///   - contentVersion: Stable token for these exact content bytes.
    /// - Returns: Ciphertext and its wrapped DEK for upload and metadata commit.
    /// - Throws: `CipherError` if key validation or authenticated encryption fails.
    public static func encrypt(
        data: Data,
        key: RowSyncKey,
        attachmentID: UUID,
        contentVersion: UUID
    ) throws -> EncryptedAttachment {
        guard key.raw.count == 32 else { throw CipherError.invalidVaultKey }
        let aad = associatedData(attachmentID: attachmentID, contentVersion: contentVersion)
        let dek = SymmetricKey(size: .bits256)

        do {
            let sealedContent = try AES.GCM.seal(data, using: dek, authenticating: aad)
            guard let cipher = sealedContent.combined else {
                throw CipherError.encryptionFailed
            }
            let sealedDEK = try AES.GCM.seal(
                dek.withUnsafeBytes { Data($0) },
                using: SymmetricKey(data: key.raw),
                authenticating: aad + Data(dekDomain.utf8))
            guard let dekWrapped = sealedDEK.combined else {
                throw CipherError.encryptionFailed
            }
            return EncryptedAttachment(cipher: cipher, dekWrapped: dekWrapped)
        } catch {
            Log.error("sync", "attachment encryption failed id=\(attachmentID.uuidString.prefix(8))…")
            throw CipherError.encryptionFailed
        }
    }

    /// Decrypts one downloaded attachment version after authenticating its identity.
    ///
    /// - Parameters:
    ///   - cipher: Combined AES-GCM ciphertext from object storage.
    ///   - dekWrapped: The DEK wrapped by the current vault key.
    ///   - key: Current 32-byte vault encryption key.
    ///   - attachmentID: Stable logical attachment identity.
    ///   - contentVersion: Expected content version from the encrypted row.
    /// - Returns: Verified attachment plaintext.
    /// - Throws: `CipherError` when the key, wrapper, identity, version, or ciphertext is invalid.
    public static func decrypt(
        cipher: Data,
        dekWrapped: Data,
        key: RowSyncKey,
        attachmentID: UUID,
        contentVersion: UUID
    ) throws -> Data {
        let dek = try unwrapDEK(
            dekWrapped, key: key, attachmentID: attachmentID, contentVersion: contentVersion)
        do {
            let box = try AES.GCM.SealedBox(combined: cipher)
            return try AES.GCM.open(
                box, using: SymmetricKey(data: dek),
                authenticating: associatedData(attachmentID: attachmentID, contentVersion: contentVersion))
        } catch {
            throw CipherError.authenticationFailed
        }
    }

    /// Rewraps the same DEK under a new vault key without changing content version or blob bytes.
    ///
    /// - Parameters:
    ///   - dekWrapped: Existing wrapper under `oldKey`.
    ///   - oldKey: Current vault encryption key.
    ///   - newKey: Replacement vault encryption key.
    ///   - attachmentID: Stable logical attachment identity.
    ///   - contentVersion: Stable token associated with the wrapped DEK.
    /// - Returns: The same DEK wrapped under `newKey`.
    /// - Throws: `CipherError` if either key is invalid or the existing wrapper cannot be authenticated.
    public static func rewrap(
        _ dekWrapped: Data,
        oldKey: RowSyncKey,
        newKey: RowSyncKey,
        attachmentID: UUID,
        contentVersion: UUID
    ) throws -> Data {
        guard newKey.raw.count == 32 else { throw CipherError.invalidVaultKey }
        let dek = try unwrapDEK(
            dekWrapped, key: oldKey, attachmentID: attachmentID, contentVersion: contentVersion)
        let aad = associatedData(attachmentID: attachmentID, contentVersion: contentVersion)
        do {
            let sealed = try AES.GCM.seal(
                dek, using: SymmetricKey(data: newKey.raw),
                authenticating: aad + Data(dekDomain.utf8))
            guard let combined = sealed.combined else { throw CipherError.encryptionFailed }
            return combined
        } catch {
            throw CipherError.encryptionFailed
        }
    }

    private static func unwrapDEK(
        _ dekWrapped: Data,
        key: RowSyncKey,
        attachmentID: UUID,
        contentVersion: UUID
    ) throws -> Data {
        guard key.raw.count == 32 else { throw CipherError.invalidVaultKey }
        let aad = associatedData(attachmentID: attachmentID, contentVersion: contentVersion)
        do {
            let box = try AES.GCM.SealedBox(combined: dekWrapped)
            let dek = try AES.GCM.open(
                box, using: SymmetricKey(data: key.raw),
                authenticating: aad + Data(dekDomain.utf8))
            guard dek.count == 32 else { throw CipherError.authenticationFailed }
            return dek
        } catch {
            throw CipherError.authenticationFailed
        }
    }

    private static func associatedData(attachmentID: UUID, contentVersion: UUID) -> Data {
        Data("\(aadPrefix)\(attachmentID.uuidString.lowercased()):\(contentVersion.uuidString.lowercased())".utf8)
    }
}
