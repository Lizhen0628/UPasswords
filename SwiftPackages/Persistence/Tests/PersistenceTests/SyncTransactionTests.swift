import CryptoKit
import XCTest
import UPasswordsCore
@testable import UPasswordsPersistence

final class SyncTransactionTests: XCTestCase {
    private enum InjectedFailure: Error {
        case interrupted
    }

    private var root: URL!
    private let rowKey = RowSyncKey(raw: Data(repeating: 9, count: 32))

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UPWSyncTransaction-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func state(for database: PasswordDatabase, cursor: Int) throws -> RowSyncState {
        var state = RowSyncState()
        state.cursor = cursor
        for item in RowSync.allItems(database: database) {
            state.revisions[item.uuid] = UInt64(cursor)
            state.syncedMtimes[item.uuid] = item.modifiedMs
            state.encryptedItemBaselines[item.uuid] = try RowSyncCipher.encryptBaseline(item, key: rowKey)
        }
        return state
    }

    private func stageFiles(in store: DatabaseStore) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: store.databasesDir,
                                                    includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "stage" }
    }

    private func journal(in store: DatabaseStore, name: String = "Alpha") -> URL {
        store.databasesDir.appendingPathComponent("\(name).upwsync-transaction.json")
    }

    private func initialSnapshot(in store: DatabaseStore) throws -> (PasswordDatabase, SymmetricKey) {
        let database = PasswordDatabase.createDefault()
        let key = DatabaseCipher.generateVaultKey()
        let envelope = try DatabaseCipher.wrapVaultKey(key, password: "old")
        try store.commitSyncSnapshot(database, name: "Alpha", vaultKey: key,
                                     state: try state(for: database, cursor: 1), envelope: envelope)
        return (database, key)
    }

    func testSnapshotAndSyncBaselineCommitTogether() throws {
        let store = DatabaseStore(root: root)
        var (database, key) = try initialSnapshot(in: store)
        let card = Card(title: "Committed")
        database.cards.append(card)
        let expected = try state(for: database, cursor: 9)
        let envelope = try Data(contentsOf: store.keyURL(for: "Alpha"))

        try store.commitSyncSnapshot(database, name: "Alpha", vaultKey: key, state: expected)

        XCTAssertEqual(try store.load(name: "Alpha", password: "old").card(id: card.id)?.title,
                       card.title)
        var restoredState = try store.loadSyncState(for: "Alpha")
        XCTAssertEqual(restoredState, expected)
        try restoredState.recomputeDirty(database: database, key: rowKey)
        XCTAssertFalse(restoredState.hasPendingWork)
        for item in RowSync.allItems(database: database) {
            let encrypted = try XCTUnwrap(restoredState.encryptedItemBaselines[item.uuid])
            let baseline = try XCTUnwrap(
                RowSyncCipher.decryptBaseline(encrypted, key: rowKey, uuid: item.uuid))
            XCTAssertTrue(baseline.matches(item))
        }
        XCTAssertEqual(try Data(contentsOf: store.keyURL(for: "Alpha")), envelope)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal(in: store).path))
        XCTAssertTrue(try stageFiles(in: store).isEmpty)
    }

    func testQuarantinePayloadAndCursorRecoverTogetherAfterInterruptedCommit() throws {
        let store = DatabaseStore(root: root)
        var (database, key) = try initialSnapshot(in: store)
        let keptCard = Card(title: "Kept local record")
        database.cards.append(keptCard)
        var nextState = try state(for: database, cursor: 5)
        let vaultRowKey = RowSyncKey(raw: key.withUnsafeBytes { Data($0) })
        let remoteID = UUID()
        let remoteChange = RelayClient.ChangeEntry(
            seq: 5, uuid: remoteID, op: "upsert", revision: 1, deleted: false,
            bodyB64: "damaged-cloud-payload", kind: 1, modifiedMs: 100)
        let quarantined = try RowSyncCipher.quarantine(
            remoteChange, reason: .authenticationFailed, key: vaultRowKey)
        nextState.quarantinedItems[quarantined.id] = quarantined
        nextState.needsSyncContinuation = true
        store.transactionFaultInjector = { if $0 == "body" { throw InjectedFailure.interrupted } }

        XCTAssertThrowsError(try store.commitSyncSnapshot(
            database, name: "Alpha", vaultKey: key, state: nextState))

        let restarted = DatabaseStore(root: root)
        let restoredDatabase = try restarted.load(name: "Alpha", password: "old")
        let restoredState = try restarted.loadSyncState(for: "Alpha")
        XCTAssertNotNil(restoredDatabase.card(id: keptCard.id))
        XCTAssertEqual(restoredState.cursor, 5)
        XCTAssertTrue(restoredState.needsSyncContinuation)
        let restoredQuarantine = try XCTUnwrap(restoredState.quarantinedItems[quarantined.id])
        guard case .change(let restoredChange) = try RowSyncCipher.openQuarantine(
            restoredQuarantine, key: vaultRowKey) else {
            return XCTFail("Expected the original remote change")
        }
        XCTAssertEqual(restoredChange.bodyB64, "damaged-cloud-payload")
    }

    func testRestoredHistoryIsCommittedAndRecoveredWithSnapshot() throws {
        for point in ["journal", "body", "state", "envelope", "backupHistory"] {
            let directory = root.appendingPathComponent("history-\(point)")
            let store = DatabaseStore(root: directory)
            let database = PasswordDatabase.createDefault()
            let key = DatabaseCipher.generateVaultKey()
            let envelope = try DatabaseCipher.wrapVaultKey(key, password: "new")
            let plaintext = Data("encrypted historical content".utf8)
            let sealed = try AES.GCM.seal(plaintext, using: key)
            let history = try XCTUnwrap(sealed.combined)
            store.transactionFaultInjector = { if $0 == point { throw InjectedFailure.interrupted } }

            XCTAssertThrowsError(try store.commitSyncSnapshot(
                database,
                name: "Alpha",
                vaultKey: key,
                state: RowSyncState(),
                envelope: envelope,
                backupHistory: history))

            let restarted = DatabaseStore(root: directory)
            _ = try restarted.load(name: "Alpha", password: "new")
            XCTAssertEqual(try Data(contentsOf: restarted.backupHistoryURL(for: "Alpha")), history)
            XCTAssertTrue(try stageFiles(in: restarted).isEmpty)
        }
    }

    func testEveryPostJournalInterruptionRecoversAllThreeFilesAfterRestart() throws {
        for point in ["journal", "body", "state", "envelope"] {
            let directory = root.appendingPathComponent(point)
            let store = DatabaseStore(root: directory)
            var (database, _) = try initialSnapshot(in: store)
            let card = Card(title: point)
            database.cards.append(card)
            let newKey = DatabaseCipher.generateVaultKey()
            let envelope = try DatabaseCipher.wrapVaultKey(newKey, password: "new")
            let expected = try state(for: database, cursor: 7)
            store.transactionFaultInjector = { stage in
                if stage == point { throw InjectedFailure.interrupted }
            }
            XCTAssertThrowsError(try store.commitSyncSnapshot(database, name: "Alpha",
                vaultKey: newKey, state: expected, envelope: envelope), point)
            XCTAssertTrue(FileManager.default.fileExists(atPath: journal(in: store).path), point)

            let restarted = DatabaseStore(root: directory)
            let loaded = try restarted.load(name: "Alpha", password: "new")
            XCTAssertEqual(loaded.card(id: card.id)?.title, point)
            XCTAssertEqual(try restarted.loadSyncState(for: "Alpha"), expected)
            XCTAssertEqual(try Data(contentsOf: restarted.keyURL(for: "Alpha")), envelope)
            XCTAssertThrowsError(try restarted.load(name: "Alpha", password: "old"))
            let body = try Data(contentsOf: restarted.url(for: "Alpha"))
            try restarted.recoverSyncTransaction(for: "Alpha")
            XCTAssertEqual(try Data(contentsOf: restarted.url(for: "Alpha")), body)
            XCTAssertTrue(try stageFiles(in: restarted).isEmpty)
        }
    }

    func testStateFirstReadAlsoCompletesPendingBodyAndEnvelope() throws {
        let store = DatabaseStore(root: root)
        var (database, key) = try initialSnapshot(in: store)
        let card = Card(title: "Recovered")
        database.cards.append(card)
        let expected = try state(for: database, cursor: 8)
        store.transactionFaultInjector = { if $0 == "body" { throw InjectedFailure.interrupted } }
        XCTAssertThrowsError(try store.commitSyncSnapshot(database, name: "Alpha",
                                                           vaultKey: key, state: expected))
        let restarted = DatabaseStore(root: root)
        XCTAssertEqual(try restarted.loadSyncState(for: "Alpha"), expected)
        XCTAssertNotNil(try restarted.load(name: "Alpha", password: "old").card(id: card.id))
    }

    func testStagingFailuresPreserveOldGenerationAndCleanStaging() throws {
        for point in ["stageBody", "stageState", "stageEnvelope"] {
            let directory = root.appendingPathComponent(point)
            let store = DatabaseStore(root: directory)
            var (database, _) = try initialSnapshot(in: store)
            let oldBody = try Data(contentsOf: store.url(for: "Alpha"))
            let oldState = try Data(contentsOf: store.syncStateURL(for: "Alpha"))
            let oldEnvelope = try Data(contentsOf: store.keyURL(for: "Alpha"))
            database.cards.append(Card(title: "Uncommitted"))
            let key = DatabaseCipher.generateVaultKey()
            let envelope = try DatabaseCipher.wrapVaultKey(key, password: "new")
            store.transactionFaultInjector = { if $0 == point { throw InjectedFailure.interrupted } }
            XCTAssertThrowsError(try store.commitSyncSnapshot(database, name: "Alpha",
                vaultKey: key, state: try state(for: database, cursor: 2), envelope: envelope))
            XCTAssertEqual(try Data(contentsOf: store.url(for: "Alpha")), oldBody)
            XCTAssertEqual(try Data(contentsOf: store.syncStateURL(for: "Alpha")), oldState)
            XCTAssertEqual(try Data(contentsOf: store.keyURL(for: "Alpha")), oldEnvelope)
            XCTAssertFalse(FileManager.default.fileExists(atPath: journal(in: store).path))
            XCTAssertTrue(try stageFiles(in: store).isEmpty)
        }
    }

    func testMissingOrCorruptStagingBlocksReadsAndWrites() throws {
        for suffix in ["upw", "upwsync", "upwkey"] {
            for missing in [true, false] {
                let directory = root.appendingPathComponent("\(suffix)-\(missing)")
                let store = DatabaseStore(root: directory)
                let (database, key) = try initialSnapshot(in: store)
                let envelope = try Data(contentsOf: store.keyURL(for: "Alpha"))
                store.transactionFaultInjector = { if $0 == "journal" { throw InjectedFailure.interrupted } }
                XCTAssertThrowsError(try store.commitSyncSnapshot(database, name: "Alpha",
                    vaultKey: key, state: try state(for: database, cursor: 2), envelope: envelope))
                let target = try XCTUnwrap(stageFiles(in: store).first {
                    $0.lastPathComponent.hasSuffix(".\(suffix).stage")
                })
                if missing {
                    try FileManager.default.removeItem(at: target)
                } else {
                    var bytes = try Data(contentsOf: target)
                    bytes[bytes.count - 1] ^= 1
                    try bytes.write(to: target)
                }
                let restarted = DatabaseStore(root: directory)
                XCTAssertThrowsError(try restarted.load(name: "Alpha", password: "old"))
                XCTAssertThrowsError(try restarted.loadSyncState(for: "Alpha"))
                XCTAssertThrowsError(try restarted.save(database, name: "Alpha", vaultKey: key))
                XCTAssertThrowsError(try restarted.rename("Alpha", to: "Beta"))
                XCTAssertThrowsError(try restarted.delete(name: "Alpha"))
                XCTAssertTrue(FileManager.default.fileExists(atPath: journal(in: store).path))
            }
        }
    }

    func testCorruptJournalAndExistingSidecarAreNotTreatedAsEmptyState() throws {
        let store = DatabaseStore(root: root)
        _ = try initialSnapshot(in: store)
        try Data("invalid".utf8).write(to: journal(in: store))
        XCTAssertThrowsError(try store.load(name: "Alpha", password: "old"))
        XCTAssertThrowsError(try store.loadSyncState(for: "Alpha"))
        try FileManager.default.removeItem(at: journal(in: store))
        try Data("invalid".utf8).write(to: store.syncStateURL(for: "Alpha"))
        XCTAssertThrowsError(try store.loadSyncState(for: "Alpha"))
    }

    func testRenameAndDeleteRecoverPendingTransactionsBeforeChangingLifecycle() throws {
        for operation in ["rename", "delete"] {
            let directory = root.appendingPathComponent(operation)
            let store = DatabaseStore(root: directory)
            let (database, key) = try initialSnapshot(in: store)
            let expected = try state(for: database, cursor: 5)
            store.transactionFaultInjector = { if $0 == "body" { throw InjectedFailure.interrupted } }
            XCTAssertThrowsError(try store.commitSyncSnapshot(database, name: "Alpha",
                                                               vaultKey: key, state: expected))
            let restarted = DatabaseStore(root: directory)
            if operation == "rename" {
                try restarted.rename("Alpha", to: "Beta")
                XCTAssertEqual(try restarted.loadSyncState(for: "Beta"), expected)
                _ = try restarted.load(name: "Beta", password: "old")
            } else {
                try restarted.delete(name: "Alpha")
            }
            try restarted.recoverSyncTransaction(for: "Alpha")
            XCTAssertFalse(restarted.exists("Alpha"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: journal(in: restarted).path))
            XCTAssertTrue(try stageFiles(in: restarted).isEmpty)
        }
    }

    func testRecoveryCanBeInterruptedAgainAndStillFinish() throws {
        let store = DatabaseStore(root: root)
        var (database, key) = try initialSnapshot(in: store)
        let card = Card(title: "RestartedTwice")
        database.cards.append(card)
        let expected = try state(for: database, cursor: 11)
        store.transactionFaultInjector = { if $0 == "journal" { throw InjectedFailure.interrupted } }
        XCTAssertThrowsError(try store.commitSyncSnapshot(database, name: "Alpha",
                                                           vaultKey: key, state: expected))
        let firstRestart = DatabaseStore(root: root)
        firstRestart.transactionFaultInjector = { if $0 == "state" { throw InjectedFailure.interrupted } }
        XCTAssertThrowsError(try firstRestart.loadSyncState(for: "Alpha"))
        let secondRestart = DatabaseStore(root: root)
        XCTAssertNotNil(try secondRestart.load(name: "Alpha", password: "old").card(id: card.id))
        XCTAssertEqual(try secondRestart.loadSyncState(for: "Alpha"), expected)
        XCTAssertTrue(try stageFiles(in: secondRestart).isEmpty)
    }

    func testPendingTransactionDoesNotChangeAnotherDatabase() throws {
        let store = DatabaseStore(root: root)
        let (database, key) = try initialSnapshot(in: store)
        let envelope = try Data(contentsOf: store.keyURL(for: "Alpha"))
        let otherState = try state(for: database, cursor: 3)
        try store.commitSyncSnapshot(database, name: "Other", vaultKey: key,
                                     state: otherState, envelope: envelope)
        let otherBody = try Data(contentsOf: store.url(for: "Other"))
        store.transactionFaultInjector = { if $0 == "body" { throw InjectedFailure.interrupted } }
        XCTAssertThrowsError(try store.commitSyncSnapshot(database, name: "Alpha",
            vaultKey: key, state: try state(for: database, cursor: 12)))
        let restarted = DatabaseStore(root: root)
        XCTAssertEqual(try restarted.loadSyncState(for: "Other"), otherState)
        XCTAssertEqual(try Data(contentsOf: restarted.url(for: "Other")), otherBody)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal(in: restarted).path))
        try restarted.recoverSyncTransaction(for: "Alpha")
        XCTAssertEqual(try Data(contentsOf: restarted.url(for: "Other")), otherBody)
    }

    func testOrdinarySaveRecoversBeforeWritingNewLocalChanges() throws {
        let store = DatabaseStore(root: root)
        var (database, key) = try initialSnapshot(in: store)
        database.cards.append(Card(title: "Remote"))
        let expected = try state(for: database, cursor: 6)
        store.transactionFaultInjector = { if $0 == "body" { throw InjectedFailure.interrupted } }
        XCTAssertThrowsError(try store.commitSyncSnapshot(database, name: "Alpha",
                                                           vaultKey: key, state: expected))
        let localCard = Card(title: "Local")
        database.cards.append(localCard)
        let restarted = DatabaseStore(root: root)
        try restarted.save(database, name: "Alpha", vaultKey: key)
        XCTAssertEqual(try restarted.loadSyncState(for: "Alpha"), expected)
        XCTAssertNotNil(try restarted.load(name: "Alpha", password: "old").card(id: localCard.id))
        try restarted.recoverSyncTransaction(for: "Alpha")
        XCTAssertNotNil(try restarted.load(name: "Alpha", password: "old").card(id: localCard.id))
    }
}
