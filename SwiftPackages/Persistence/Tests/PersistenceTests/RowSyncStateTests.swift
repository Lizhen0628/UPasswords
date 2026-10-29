import CryptoKit
import Foundation
import XCTest
import UPasswordsCore
@testable import UPasswordsPersistence

final class RowSyncStateTests: XCTestCase {
    private let key = RowSyncKey(raw: Data(repeating: 7, count: 32))

    func testLegacySidecarKeepsPendingEditsWithoutEncryptedBaselineField() throws {
        var original = RowSyncState()
        let id = UUID()
        original.cursor = 17
        original.revisions[id] = 3
        original.dirtyUpserts[id] = 100
        let encoded = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "encryptedItemBaselines")
        object.removeValue(forKey: "pendingConflicts")
        object.removeValue(forKey: "quarantinedItems")
        object.removeValue(forKey: "needsSyncContinuation")
        object.removeValue(forKey: "importedSourceKeys")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(RowSyncState.self, from: legacy)
        XCTAssertEqual(decoded, original)
    }

    func testPendingConflictMarkerRoundTripsAndPreventsDirtyRecomputation() throws {
        let base = Card(title: "Base")
        var local = base
        local.title = "Local candidate"
        var database = PasswordDatabase()
        database.cards = [local]
        var state = RowSyncState()
        state.revisions[local.id] = 2
        state.syncedMtimes[local.id] = base.modified
        state.encryptedItemBaselines[local.id] = try RowSyncCipher.encryptBaseline(
            .card(base), key: key)
        state.dirtyUpserts[local.id] = local.modified
        let plaintext = DatabaseItemCodec.xmlData(.card(local))
        let identity = RowSyncCipher.conflictCandidateIdentity(
            plaintext: plaintext, key: key, uuid: local.id,
            baseRevision: 1, kind: 1, isDelete: false)
        state.pendingConflicts[local.id] = RowSyncPendingConflict(
            conflictID: String(repeating: "a", count: 32),
            candidateID: identity.candidateID,
            fingerprint: identity.fingerprint,
            baseRevision: 1,
            kind: 1,
            isDelete: false)

        try state.recomputeDirty(database: database, key: key)

        XCTAssertEqual(state.dirtyUpserts[local.id], local.modified)
        XCTAssertTrue(state.hasPendingWork)
        let decoded = try JSONDecoder().decode(RowSyncState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded, state)
    }

    func testLegacySyncedRowsRequireBaselineMigrationButAreNotAllMarkedDirty() throws {
        let card = Card(title: "Already synced")
        var database = PasswordDatabase()
        database.cards = [card]
        var state = RowSyncState()
        state.revisions[card.id] = 2
        state.syncedMtimes[card.id] = card.modified

        XCTAssertTrue(state.needsContentBaselineMigration)
        try state.recomputeDirty(database: database, key: key)
        XCTAssertFalse(state.hasPendingWork)
        XCTAssertTrue(state.needsContentBaselineMigration)
    }

    func testLegacySameTimestampEditIsDetectedBySnapshotMigration() throws {
        let card = Card(title: "Local edit")
        let remote = Card(id: card.id, title: "Previous cloud value")
        var database = PasswordDatabase()
        database.cards = [card]
        var state = RowSyncState()
        state.revisions[card.id] = 2
        state.syncedMtimes[card.id] = card.modified
        try state.recomputeDirty(database: database, key: key)

        XCTAssertFalse(state.hasPendingWork)
        XCTAssertFalse(RowSyncBaseline(item: .card(card)).matches(.card(remote)))
    }

    func testNewLocalRowsWithoutRemoteBaselineRemainUploadCandidates() throws {
        let card = Card(title: "Local new row")
        var database = PasswordDatabase()
        database.cards = [card]
        var state = RowSyncState()
        try state.recomputeDirty(database: database, key: key)

        XCTAssertEqual(state.dirtyUpserts[card.id], card.modified)
        XCTAssertFalse(state.needsContentBaselineMigration)
    }

    func testMalformedEncryptedBaselineFieldFailsInsteadOfResettingState() throws {
        let data = try JSONEncoder().encode(RowSyncState())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["encryptedItemBaselines"] = 123
        let malformed = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(RowSyncState.self, from: malformed))
    }

    func testQuarantinedPayloadIsEncryptedAndBoundToItsIdentity() throws {
        let secretCiphertext = "private-remote-payload"
        let entry = RelayClient.ChangeEntry(
            seq: 23, uuid: UUID(), op: "upsert", revision: 4, deleted: false,
            bodyB64: secretCiphertext, kind: 1, modifiedMs: 100)
        let quarantined = try RowSyncCipher.quarantine(
            entry, reason: .authenticationFailed, key: key)
        var state = RowSyncState()
        state.cursor = 23
        state.needsSyncContinuation = true
        state.quarantinedItems[quarantined.id] = quarantined

        let sidecar = try JSONEncoder().encode(state)
        XCTAssertNil(sidecar.range(of: Data(secretCiphertext.utf8)))
        let decoded = try JSONDecoder().decode(RowSyncState.self, from: sidecar)
        XCTAssertEqual(decoded, state)
        XCTAssertTrue(decoded.needsSyncContinuation)
        guard case .change(let restored) = try RowSyncCipher.openQuarantine(quarantined, key: key) else {
            return XCTFail("Expected an isolated change")
        }
        XCTAssertEqual(restored, entry)

        let wrongKey = RowSyncKey(raw: Data(repeating: 8, count: 32))
        XCTAssertThrowsError(try RowSyncCipher.openQuarantine(quarantined, key: wrongKey))
    }

    func testQuarantinedCandidatePayloadIsEncryptedAndBoundToItsIdentity() throws {
        let secretCiphertext = Data("private-candidate-payload".utf8).base64EncodedString()
        let itemID = UUID()
        let candidate = RelayClient.ConflictCandidate(
            candidateID: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            kind: 1,
            isDelete: false,
            revision: 7,
            modifiedAt: Date(timeIntervalSince1970: 100),
            committedAt: Date(timeIntervalSince1970: 101),
            deviceName: "Device",
            platform: "macos",
            bodyB64: secretCiphertext,
            sha256: String(repeating: "b", count: 64))
        let conflict = RelayClient.ConflictRecord(
            conflictID: "cccccccccccccccccccccccccccccccc",
            itemUUID: itemID,
            baseRevision: 6,
            currentRevision: 7,
            currentDeletedSequence: 0,
            generation: 1,
            createdAt: Date(timeIntervalSince1970: 90),
            updatedAt: Date(timeIntervalSince1970: 91),
            candidates: [candidate])
        let quarantined = try RowSyncCipher.quarantineCandidate(
            candidate, conflict: conflict, reason: .authenticationFailed, key: key)
        var state = RowSyncState()
        state.quarantinedCandidates[quarantined.id] = quarantined

        let sidecar = try JSONEncoder().encode(state)
        XCTAssertNil(sidecar.range(of: Data(secretCiphertext.utf8)))
        let decoded = try JSONDecoder().decode(RowSyncState.self, from: sidecar)
        XCTAssertEqual(decoded, state)
        let restored = try RowSyncCipher.openQuarantineCandidate(quarantined, key: key)
        XCTAssertEqual(restored, candidate)
        let wrongKey = RowSyncKey(raw: Data(repeating: 9, count: 32))
        XCTAssertThrowsError(try RowSyncCipher.openQuarantineCandidate(quarantined, key: wrongKey))
    }

    func testQuarantineSuppressesDirtyRecomputationForItsProtectedLocalItem() throws {
        let card = Card(title: "Preserved local copy")
        var database = PasswordDatabase()
        database.cards = [card]
        var state = RowSyncState()
        state.revisions[card.id] = 1
        state.syncedMtimes[card.id] = card.modified
        let entry = RelayClient.ChangeEntry(
            seq: 9, uuid: card.id, op: "upsert", revision: 2, deleted: false,
            bodyB64: "damaged", kind: 1, modifiedMs: card.modified + 1)
        let quarantined = try RowSyncCipher.quarantine(
            entry, reason: .authenticationFailed, key: key)
        state.quarantinedItems[quarantined.id] = quarantined
        state.encryptedItemBaselines[card.id] = try RowSyncCipher.encryptBaseline(.card(card), key: key)

        try state.recomputeDirty(database: database, key: key)

        XCTAssertNil(state.dirtyUpserts[card.id])
        XCTAssertNil(state.dirtyDeletes[card.id])
        XCTAssertFalse(state.needsContentBaselineMigration)
    }

    func testContentChangesAreDirtyButTimestampOnlyChangesAreNot() throws {
        var card = Card(title: "Baseline")
        card.modified = 500
        var database = PasswordDatabase()
        database.cards = [card]
        var state = RowSyncState()
        state.revisions[card.id] = 1
        state.syncedMtimes[card.id] = card.modified
        state.encryptedItemBaselines[card.id] = try RowSyncCipher.encryptBaseline(.card(card), key: key)
        try state.recomputeDirty(database: database, key: key)
        XCTAssertFalse(state.hasPendingWork)

        database.cards[0].title = "Changed without a newer clock"
        try state.recomputeDirty(database: database, key: key)
        XCTAssertNotNil(state.dirtyUpserts[card.id])

        state.dirtyUpserts = [:]
        database.cards[0] = card
        database.cards[0].modified = 100
        try state.recomputeDirty(database: database, key: key)
        XCTAssertFalse(state.hasPendingWork)
    }

    func testUnauthenticatedBaselineFailsWithoutChangingState() throws {
        let card = Card(title: "Protected")
        var database = PasswordDatabase()
        database.cards = [card]
        var state = RowSyncState()
        state.revisions[card.id] = 1
        state.syncedMtimes[card.id] = card.modified
        state.encryptedItemBaselines[card.id] = try RowSyncCipher.encryptBaseline(.card(card), key: key)
        let before = state
        let wrongKey = RowSyncKey(raw: Data(repeating: 8, count: 32))

        XCTAssertThrowsError(try state.recomputeDirty(database: database, key: wrongKey)) { error in
            XCTAssertEqual(error as? RowSyncSafetyError, .baselineUnavailable)
        }
        XCTAssertEqual(state, before)
    }

    func testLegacyFieldWithoutPersistentIDMatchesAfterBaselineRoundTrip() throws {
        let legacyFieldJSON = Data(#"{"name":"Password","type":"password","value":"secret","autofill":"off","history":[]}"#.utf8)
        let field = try JSONDecoder().decode(Field.self, from: legacyFieldJSON)
        XCTAssertFalse(field.hasPersistentID)

        var card = Card(title: "Legacy")
        card.fields = [field]
        let encrypted = try RowSyncCipher.encryptBaseline(.card(card), key: key)
        let baseline = try XCTUnwrap(
            RowSyncCipher.decryptBaseline(encrypted, key: key, uuid: card.id))

        XCTAssertTrue(baseline.matches(.card(card)))
    }

    func testPreviousBaselineEncodingRemainsReadable() throws {
        var card = Card(title: "Legacy baseline")
        let legacyFieldJSON = Data(#"{"name":"Login","type":"login","value":"user","autofill":"off","history":[]}"#.utf8)
        card.fields = [try JSONDecoder().decode(Field.self, from: legacyFieldJSON)]
        let item = DatabaseItem.card(card)
        let currentData = try JSONEncoder().encode(RowSyncBaseline(item: item))
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: currentData) as? [String: Any])
        var cardSnapshot = try XCTUnwrap(root["card"] as? [String: Any])
        var encodedCard = try XCTUnwrap(cardSnapshot["card"] as? [String: Any])
        let fields = try XCTUnwrap(cardSnapshot.removeValue(forKey: "fields"))
        encodedCard["fields"] = fields
        cardSnapshot["card"] = encodedCard
        root["card"] = cardSnapshot
        let previousData = try JSONSerialization.data(withJSONObject: root)
        let sealed = try AES.GCM.seal(
            previousData,
            using: SymmetricKey(data: key.raw),
            authenticating: Data("UPW-SYNC-BASELINE-V1:\(card.id.uuidString)".utf8)
        )
        let encrypted = try XCTUnwrap(sealed.combined)

        let baseline = try XCTUnwrap(
            RowSyncCipher.decryptBaseline(encrypted, key: key, uuid: card.id))
        XCTAssertTrue(baseline.matches(item))
    }

    func testLegacyProfileFieldsMatchAfterBaselineRoundTrip() throws {
        let legacyFieldJSON = Data(#"{"name":"Email","type":"email","value":"user@example.test","autofill":"email","history":[]}"#.utf8)
        var profile = UserProfile()
        profile.fields = [try JSONDecoder().decode(Field.self, from: legacyFieldJSON)]
        let item = DatabaseItem.userProfile(profile)
        let encrypted = try RowSyncCipher.encryptBaseline(item, key: key)
        let baseline = try XCTUnwrap(
            RowSyncCipher.decryptBaseline(encrypted, key: key, uuid: profile.id))

        XCTAssertTrue(baseline.matches(item))
    }

    func testPreviousProfileBaselineEncodingRemainsReadable() throws {
        let legacyFieldJSON = Data(#"{"name":"Email","type":"email","value":"user@example.test","autofill":"email","history":[]}"#.utf8)
        var profile = UserProfile()
        profile.fields = [try JSONDecoder().decode(Field.self, from: legacyFieldJSON)]
        let item = DatabaseItem.userProfile(profile)
        let currentData = try JSONEncoder().encode(RowSyncBaseline(item: item))
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: currentData) as? [String: Any])
        var profileSnapshot = try XCTUnwrap(root["userProfile"] as? [String: Any])
        var encodedProfile = try XCTUnwrap(profileSnapshot.removeValue(forKey: "profile") as? [String: Any])
        let fields = try XCTUnwrap(profileSnapshot.removeValue(forKey: "fields"))
        encodedProfile["fields"] = fields
        root["userProfile"] = encodedProfile
        let previousData = try JSONSerialization.data(withJSONObject: root)
        let sealed = try AES.GCM.seal(
            previousData,
            using: SymmetricKey(data: key.raw),
            authenticating: Data("UPW-SYNC-BASELINE-V1:\(profile.id.uuidString)".utf8)
        )
        let encrypted = try XCTUnwrap(sealed.combined)

        let baseline = try XCTUnwrap(
            RowSyncCipher.decryptBaseline(encrypted, key: key, uuid: profile.id))
        XCTAssertTrue(baseline.matches(item))
    }

    func testSidecarDoesNotExposeItemOrAttachmentContents() throws {
        var card = Card(title: "private-card-title")
        card.notes = "private-card-notes"
        card.fields = [Field(name: "Password", type: .password, value: "private-field-value")]
        card.files = [Attachment(name: "private-document-name", data: Data("private-file-bytes".utf8))]
        var state = RowSyncState()
        state.revisions[card.id] = 1
        state.syncedMtimes[card.id] = card.modified
        state.encryptedItemBaselines[card.id] = try RowSyncCipher.encryptBaseline(.card(card), key: key)

        let sidecar = try JSONEncoder().encode(state)
        for secret in [
            "private-card-title", "private-card-notes", "private-field-value",
            "private-document-name", "private-file-bytes"
        ] {
            XCTAssertNil(sidecar.range(of: Data(secret.utf8)))
        }
    }

    func testDeletionDetectionUsesRevisionIdentityWithoutTimestampBaseline() throws {
        let id = UUID()
        var state = RowSyncState()
        state.revisions[id] = 4
        try state.recomputeDirty(database: PasswordDatabase(), key: key)

        XCTAssertNotNil(state.dirtyDeletes[id])
    }
}
