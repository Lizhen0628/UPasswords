import Foundation
import SwiftData
import XCTest
import UPasswordsCore
@testable import UPasswordsPersistence

final class SwiftDataVaultStoreTests: XCTestCase {
    func testLegacyImportRoundTripsEncryptedBusinessRows() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("upw-swiftdata-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let legacy = DatabaseStore(root: root)
        try legacy.create(name: "Main", password: "migration-password")
        var (database, _) = try legacy.loadUnlocked(name: "Main", password: "migration-password")
        database.cards = [Card(title: "private-title")]
        let (_, key) = try legacy.loadUnlocked(name: "Main", password: "migration-password")
        try legacy.save(database, name: "Main", vaultKey: key)

        let native = try SwiftDataVaultStore(root: root)
        XCTAssertTrue(try native.importLegacyIfNeeded(
            name: "Main", password: "migration-password", legacyStore: legacy))
        XCTAssertFalse(try native.importLegacyIfNeeded(
            name: "Main", password: "migration-password", legacyStore: legacy))

        let restored = try native.loadUnlocked(name: "Main", password: "migration-password").0
        XCTAssertEqual(restored.cards.map(\.title), ["private-title"])

        let nativeFiles = try FileManager.default
            .contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter { $0.lastPathComponent.contains("NativeVault") }
        XCTAssertFalse(nativeFiles.isEmpty)
        for file in nativeFiles {
            if let data = try? Data(contentsOf: file) {
                XCTAssertNil(data.range(of: Data("private-title".utf8)))
            }
        }
    }

    func testVaultLifecycleDeletesAndRenamesRows() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("upw-swiftdata-lifecycle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let legacy = DatabaseStore(root: root)
        try legacy.create(name: "Main", password: "migration-password")
        let (database, key) = try legacy.loadUnlocked(name: "Main", password: "migration-password")
        let native = try SwiftDataVaultStore(root: root)
        _ = try native.importLegacyIfNeeded(
            name: "Main", password: "migration-password", legacyStore: legacy)

        try native.renameVault(from: "Main", to: "Renamed")
        XCTAssertTrue(try native.containsVault(name: "Renamed"))
        XCTAssertFalse(try native.containsVault(name: "Main"))
        try native.replace(database, name: "Renamed", vaultKey: key)
        _ = try native.loadUnlocked(name: "Renamed", password: "migration-password")

        try native.deleteVault(name: "Renamed")
        XCTAssertFalse(try native.containsVault(name: "Renamed"))
        try native.deleteAllVaults()
    }

    @MainActor
    func testLegacyProfileRowsMoveToDedicatedTableWithoutDataLoss() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("upw-swiftdata-profile-migration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let profileID = UUID()

        do {
            let legacy = DatabaseStore(root: root)
            try legacy.create(name: "Main", password: "migration-password")
            let native = try SwiftDataVaultStore(root: root)
            _ = try native.importLegacyIfNeeded(
                name: "Main", password: "migration-password", legacyStore: legacy)
            let (database, key) = try legacy.loadUnlocked(name: "Main", password: "migration-password")
            var profile = UserProfile(id: profileID)
            profile.fields = [Field(name: "email", value: "private@example.test")]
            profile.modified = 1_700_000_000_000
            var profileDatabase = database
            profileDatabase.userProfiles = [profile]
            try native.replace(profileDatabase, name: "Main", vaultKey: key, revisions: [profile.id: 4])

            let context = native.container.mainContext
            let profileRow = try XCTUnwrap(context.fetch(FetchDescriptor<LocalVaultProfileRecord>()).first)
            context.insert(LocalVaultItemRecord(
                vaultID: profileRow.vaultID,
                itemUUID: profileRow.itemUUID,
                kind: 3,
                revision: profileRow.revision,
                body: profileRow.body,
                bodySHA256: profileRow.bodySHA256,
                bodyBytes: profileRow.bodyBytes,
                modifiedMS: profileRow.modifiedMS,
                createdMS: profileRow.createdMS,
                updatedMS: profileRow.updatedMS,
                originSessionID: profileRow.originSessionID,
                originDeviceName: profileRow.originDeviceName,
                originPlatform: profileRow.originPlatform
            ))
            context.delete(profileRow)
            try context.save()
        }

        let migrated = try SwiftDataVaultStore(root: root)
        let verificationContext = ModelContext(migrated.container)
        let itemRows = try verificationContext.fetch(FetchDescriptor<LocalVaultItemRecord>())
        let profileRows = try verificationContext.fetch(FetchDescriptor<LocalVaultProfileRecord>())
        XCTAssertFalse(itemRows.contains { $0.kind == 3 })
        XCTAssertEqual(profileRows.count, 1)
        XCTAssertEqual(profileRows.first?.revision, 4)
        let restored = try migrated.loadUnlocked(name: "Main", password: "migration-password").0
        XCTAssertEqual(restored.userProfiles.map(\.id), [profileID])
        XCTAssertEqual(restored.userProfiles.first?.fields.first?.value, "private@example.test")
    }

    @MainActor
    func testReplacePreservesAttachmentCacheRevisionAndRekeysCache() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("upw-swiftdata-attachment-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let legacy = DatabaseStore(root: root)
        try legacy.create(name: "Main", password: "migration-password")
        let (_, originalKey) = try legacy.loadUnlocked(name: "Main", password: "migration-password")
        var database = PasswordDatabase()
        var card = Card(title: "Initial")
        let attachmentID = UUID()
        let contentVersion = UUID()
        let bytes = Data("cached attachment".utf8)
        card.files = [Attachment(
            id: attachmentID,
            contentVersion: contentVersion,
            name: "file.txt",
            data: bytes
        )]
        database.cards = [card]

        let native = try SwiftDataVaultStore(root: root)
        try native.replace(
            database,
            name: "Main",
            envelope: try Data(contentsOf: legacy.keyURL(for: "Main")),
            vaultKey: originalKey,
            revisions: [card.id: 7]
        )

        var metadataOnly = database
        metadataOnly.cards[0].title = "Renamed"
        metadataOnly.cards[0].files[0].name = "renamed.txt"
        metadataOnly.cards[0].files[0].discardLocalContent()
        try native.replace(metadataOnly, name: "Main", vaultKey: originalKey)

        let loaded = try native.loadUnlocked(name: "Main", password: "migration-password").0
        XCTAssertEqual(loaded.cards[0].files[0].data, bytes)
        XCTAssertEqual(loaded.cards[0].files[0].contentVersion, contentVersion)

        let rows = try native.container.mainContext.fetch(FetchDescriptor<LocalVaultItemRecord>())
        XCTAssertEqual(rows.first?.revision, 7)

        let newKey = DatabaseCipher.generateVaultKey()
        let newEnvelope = try DatabaseCipher.wrapVaultKey(newKey, password: "new-migration-password")
        try native.replace(
            loaded,
            name: "Main",
            envelope: newEnvelope,
            vaultKey: newKey,
            revisions: [card.id: 8],
            previousVaultKey: originalKey
        )
        let rekeyed = try native.loadUnlocked(name: "Main", password: "new-migration-password").0
        XCTAssertEqual(rekeyed.cards[0].files[0].data, bytes)

        var evictedSnapshot = rekeyed
        evictedSnapshot.cards[0].files[0].discardLocalContent()
        try native.replace(evictedSnapshot, name: "Main", vaultKey: newKey)
        try native.evictAttachmentContent(
            vaultName: "Main",
            attachmentID: attachmentID,
            contentVersion: contentVersion
        )
        let evicted = try native.loadUnlocked(name: "Main", password: "new-migration-password").0
        XCTAssertNil(evicted.cards[0].files[0].data)
    }
}
