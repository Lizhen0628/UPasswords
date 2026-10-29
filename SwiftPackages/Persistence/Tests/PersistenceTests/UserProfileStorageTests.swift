import CryptoKit
import Foundation
import XCTest
import UPasswordsCore
@testable import UPasswordsPersistence

final class UserProfileStorageTests: XCTestCase {
    func testProfileIsEncryptedOnDiskAndParticipatesInRowSync() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DatabaseStore(root: root)
        try store.create(name: "Profile", password: "test-master-password")
        var (database, key) = try store.loadUnlocked(name: "Profile", password: "test-master-password")
        var draft = PersonalInfoDraft()
        draft.email = "profile-storage@example.com"
        draft.postalCode = "00100"
        let profile = try XCTUnwrap(draft.makeProfile(autofillEnabled: false))
        database.userProfiles = [profile]
        try store.save(database, name: "Profile", vaultKey: key)
        let stored = try Data(contentsOf: store.url(for: "Profile"))
        XCTAssertNil(stored.range(of: Data(draft.email.utf8)))
        let restored = try store.load(name: "Profile", password: "test-master-password")
        XCTAssertEqual(restored.userProfiles.first?.fields.map(\.value), [draft.email, draft.postalCode])
        XCTAssertEqual(restored.userProfiles.first?.registrationAutofillEnabled, false)
        var state = RowSyncState()
        let rowKey = RowSyncKey(raw: key.withUnsafeBytes { Data($0) })
        try state.recomputeDirty(database: restored, key: rowKey)
        XCTAssertNotNil(state.dirtyUpserts[profile.id])
        let plaintext = DatabaseItemCodec.xmlData(.userProfile(profile))
        let sealed = try RowSyncCipher.encrypt(plaintext, key: rowKey, uuid: profile.id)
        XCTAssertNil(sealed.range(of: Data(draft.email.utf8)))
        XCTAssertEqual(RowSyncCipher.decrypt(sealed, key: rowKey, uuid: profile.id), plaintext)
        XCTAssertNil(RowSyncCipher.decrypt(sealed, key: rowKey, uuid: UUID()))
        var empty = PasswordDatabase()
        RowSync.applyItem(.userProfile(profile), to: &empty)
        XCTAssertEqual(RowSync.allItems(database: empty).first?.syncKind, 3)
        state.syncedMtimes[profile.id] = profile.modified
        empty.userProfiles = []
        try state.recomputeDirty(database: empty, key: rowKey)
        XCTAssertNotNil(state.dirtyDeletes[profile.id])
    }
}
