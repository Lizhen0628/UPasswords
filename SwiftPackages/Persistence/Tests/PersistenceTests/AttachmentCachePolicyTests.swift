import Foundation
import Testing

import UPasswordsCore
@testable import UPasswordsPersistence

@Suite("Protected attachment cache eviction")
struct AttachmentCachePolicyTests {
    private let key = RowSyncKey(raw: Data(repeating: 7, count: 32))
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func fixture() throws -> (PasswordDatabase, RowSyncState, [AttachmentDownloadLedger.Version]) {
        var database = PasswordDatabase()
        var state = RowSyncState()
        for index in 0..<3 {
            var card = Card(title: "Card \(index)")
            card.modified = 10
            card.files = [Attachment(name: "File", data: Data(repeating: UInt8(index), count: 10))]
            database.cards.append(card)
            state.revisions[card.id] = 1
            state.syncedMtimes[card.id] = card.modified
            state.encryptedItemBaselines[card.id] = try RowSyncCipher.encryptBaseline(.card(card), key: key)
        }
        return (database, state, AttachmentDownloadLedger.versions(in: database))
    }

    @Test("Eviction follows access order, preserves versions, and suppresses automatic re-download")
    func evictsOldest() throws {
        let (database, state, versions) = try fixture()
        var ledger = AttachmentDownloadLedger()
        for (index, version) in versions.enumerated() {
            ledger.recordAccess(to: version, now: now.addingTimeInterval(Double(index)))
        }
        let plan = try AttachmentCachePolicy.makePlan(database: database, state: state, key: key,
            ledger: ledger, budgetBytes: 30, incomingBytes: 10)
        #expect(plan.hasCapacity)
        #expect(plan.evictedVersions == [versions[0]])
        #expect(plan.cachedBytes == 20)
        #expect(plan.database.cards[0].files[0].data == nil)
        #expect(plan.database.cards[0].files[0].contentVersion == database.cards[0].files[0].contentVersion)
        #expect(plan.database.cards[0].modified == database.cards[0].modified)
        #expect(!plan.ledger.isReady(versions[0], now: now))
        #expect(plan.database.cards[1] == database.cards[1])
        #expect(database.cards[0].files[0].data != nil)
        var recomputed = state
        try recomputed.recomputeDirty(database: plan.database, key: key)
        #expect(!recomputed.hasPendingWork)
    }

    @Test("Offline retention and in-use versions are never eviction candidates")
    func protectsOfflineAndInUse() throws {
        let (database, state, versions) = try fixture()
        var ledger = AttachmentDownloadLedger()
        ledger.setKeptOffline(true, for: versions[0].identity)
        let plan = try AttachmentCachePolicy.makePlan(database: database, state: state, key: key,
            ledger: ledger, budgetBytes: 30, incomingBytes: 10, protectedVersions: [versions[1]])
        #expect(plan.evictedVersions == [versions[2]])
        #expect(plan.database.cards[0].files[0].hasContent)
        #expect(plan.database.cards[1].files[0].hasContent)
    }

    @Test("Whole-library downloads protect cached successes and pause when the batch exceeds its budget")
    func protectsWholeLibraryBatch() throws {
        var (database, state, versions) = try fixture()
        let missing = Attachment(name: "remote", data: nil)
        database.cards[0].files.append(missing)
        state.encryptedItemBaselines[database.cards[0].id] = try RowSyncCipher.encryptBaseline(
            .card(database.cards[0]), key: key)
        var ledger = AttachmentDownloadLedger()
        ledger.requestAll(in: database)
        let plan = try AttachmentCachePolicy.makePlan(database: database, state: state, key: key,
            ledger: ledger, budgetBytes: 30, incomingBytes: 1)
        #expect(!plan.hasCapacity)
        #expect(plan.evictedVersions.isEmpty)
        #expect(plan.database == database)
        #expect(versions.allSatisfy { plan.ledger.isReady($0, now: now) })
        ledger.cancelDownloadAll()
        let released = try AttachmentCachePolicy.makePlan(database: database, state: state, key: key,
            ledger: ledger, budgetBytes: 30, incomingBytes: 1)
        #expect(released.hasCapacity)
        #expect(released.evictedVersions.count == 1)
    }

    @Test("Unsynced edits, conflict rows, and rows without trusted baselines remain intact")
    func protectsPendingAndUnknown() throws {
        let (database, initial, versions) = try fixture()
        var state = initial
        state.markDirty(uuid: database.cards[0].id, modifiedMs: 11)
        state.pendingConflicts[database.cards[1].id] = RowSyncPendingConflict(
            conflictID: "conflict", candidateID: "candidate", fingerprint: "fingerprint",
            baseRevision: 1, kind: 1, isDelete: false)
        state.encryptedItemBaselines.removeValue(forKey: database.cards[2].id)
        let plan = try AttachmentCachePolicy.makePlan(database: database, state: state, key: key,
            ledger: AttachmentDownloadLedger(), budgetBytes: 30, incomingBytes: 10)
        #expect(!plan.hasCapacity)
        #expect(plan.evictedVersions.isEmpty)
        #expect(plan.database == database)
        #expect(versions.allSatisfy { plan.ledger.records[$0] == nil })
    }

    @Test("Same timestamp unsaved content changes are protected by the encrypted baseline")
    func detectsUnmarkedEdits() throws {
        var (database, state, _) = try fixture()
        for index in database.cards.indices { database.cards[index].notes = "Pending edit" }
        let plan = try AttachmentCachePolicy.makePlan(database: database, state: state, key: key,
            ledger: AttachmentDownloadLedger(), budgetBytes: 0)
        #expect(!plan.hasCapacity)
        #expect(plan.database == database)
    }

    @Test("Insufficient eligible bytes do not evict anything or destroy useful caches")
    func avoidsFutileCleanup() throws {
        let (database, state, versions) = try fixture()
        let plan = try AttachmentCachePolicy.makePlan(database: database, state: state, key: key,
            ledger: AttachmentDownloadLedger(), budgetBytes: 5, incomingBytes: 4,
            protectedVersions: [versions[0]])
        #expect(!plan.hasCapacity)
        #expect(plan.evictedVersions.isEmpty)
        #expect(plan.cachedBytes == 30)
        #expect(plan.database == database)
    }

    @Test("A corrupt baseline stops cleanup before inputs change")
    func rejectsCorruptBaseline() throws {
        let (database, initial, versions) = try fixture()
        var state = initial
        state.encryptedItemBaselines[database.cards[0].id] = Data([1, 2, 3])
        #expect(throws: RowSyncSafetyError.baselineUnavailable) {
            try AttachmentCachePolicy.makePlan(database: database, state: state, key: key,
                ledger: AttachmentDownloadLedger(), budgetBytes: 0)
        }
        #expect(database.cards[0].files[0].hasContent)
        #expect(versions.count == 3)
    }

    @Test("A late download cannot replace edited or deleted references")
    func rejectsStaleInstall() throws {
        var (database, _, versions) = try fixture()
        database.cards[0].files[0].discardLocalContent()
        #expect(RowSync.installDownloadedAttachmentContent(Data([7]), for: versions[0], into: &database))
        #expect(database.cards[0].files[0].data == Data([7]))
        database.cards[0].files[0] = Attachment(id: versions[0].identity.attachmentID, name: "Replacement", data: nil)
        #expect(!RowSync.installDownloadedAttachmentContent(Data([8]), for: versions[0], into: &database))
        database.cards.removeFirst()
        #expect(!RowSync.installDownloadedAttachmentContent(Data([9]), for: versions[0], into: &database))
    }
}
