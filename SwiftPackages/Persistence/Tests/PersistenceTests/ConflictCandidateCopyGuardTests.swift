import Foundation
import XCTest
@testable import UPasswordsPersistence

final class ConflictCandidateCopyGuardTests: XCTestCase {
    private let operationID = UUID()
    private let sessionID = UUID()
    private let vaultKey = Data(repeating: 7, count: 32)
    private let databaseSnapshot = Data("database".utf8)

    func testStableSessionSnapshotAndCandidateSetPassValidation() throws {
        let conflict = makeConflict()
        let guardState = makeGuard(conflict: conflict)

        XCTAssertNoThrow(try validate(guardState, conflict: conflict))
    }

    func testChangedCandidateSetIsRejected() throws {
        let conflict = makeConflict()
        let guardState = makeGuard(conflict: conflict)
        let changed = makeConflict(candidateIDs: ["candidate-a", "candidate-c"])

        XCTAssertThrowsError(try validate(guardState, conflict: changed)) { error in
            XCTAssertEqual(error as? RelayClient.RelayError, .conflictCandidatesChanged)
        }
    }

    func testChangedLocalSnapshotIsRejected() throws {
        let conflict = makeConflict()
        let guardState = makeGuard(conflict: conflict)

        XCTAssertThrowsError(try guardState.validate(
            operationID: operationID,
            sessionID: sessionID,
            vaultKey: vaultKey,
            databaseSnapshot: Data("changed".utf8),
            rowSync: RowSyncState(),
            isSyncing: true,
            conflict: conflict)) { error in
            XCTAssertEqual(error as? CrossDatabaseCardImporter.ImportError, .destinationChanged)
        }
    }

    func testChangedVaultKeyAndSyncStateAreRejected() throws {
        let conflict = makeConflict()
        let guardState = makeGuard(conflict: conflict)
        var changedState = RowSyncState()
        changedState.cursor = 1

        XCTAssertThrowsError(try guardState.validate(
            operationID: operationID,
            sessionID: sessionID,
            vaultKey: Data(repeating: 8, count: 32),
            databaseSnapshot: databaseSnapshot,
            rowSync: RowSyncState(),
            isSyncing: true,
            conflict: conflict)) { error in
            XCTAssertEqual(error as? CrossDatabaseCardImporter.ImportError, .destinationChanged)
        }
        XCTAssertThrowsError(try guardState.validate(
            operationID: operationID,
            sessionID: sessionID,
            vaultKey: vaultKey,
            databaseSnapshot: databaseSnapshot,
            rowSync: changedState,
            isSyncing: true,
            conflict: conflict)) { error in
            XCTAssertEqual(error as? CrossDatabaseCardImporter.ImportError, .destinationChanged)
        }
    }

    func testSwitchedSessionOrOperationOwnerIsCancelled() throws {
        let conflict = makeConflict()
        let guardState = makeGuard(conflict: conflict)

        XCTAssertThrowsError(try guardState.validate(
            operationID: UUID(),
            sessionID: sessionID,
            vaultKey: vaultKey,
            databaseSnapshot: databaseSnapshot,
            rowSync: RowSyncState(),
            isSyncing: true,
            conflict: conflict)) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertThrowsError(try guardState.validate(
            operationID: operationID,
            sessionID: UUID(),
            vaultKey: vaultKey,
            databaseSnapshot: databaseSnapshot,
            rowSync: RowSyncState(),
            isSyncing: true,
            conflict: conflict)) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    private func validate(
        _ guardState: ConflictCandidateCopyGuard,
        conflict: RelayClient.ConflictRecord
    ) throws {
        try guardState.validate(
            operationID: operationID,
            sessionID: sessionID,
            vaultKey: vaultKey,
            databaseSnapshot: databaseSnapshot,
            rowSync: RowSyncState(),
            isSyncing: true,
            conflict: conflict)
    }

    private func makeGuard(conflict: RelayClient.ConflictRecord) -> ConflictCandidateCopyGuard {
        ConflictCandidateCopyGuard(
            operationID: operationID,
            sessionID: sessionID,
            vaultKey: vaultKey,
            databaseSnapshot: databaseSnapshot,
            rowSync: RowSyncState(),
            conflict: conflict)
    }

    private func makeConflict(candidateIDs: [String] = ["candidate-a", "candidate-b"])
        -> RelayClient.ConflictRecord {
        let candidates = candidateIDs.map { id in
            RelayClient.ConflictCandidate(
                candidateID: id,
                kind: 1,
                isDelete: false,
                revision: 1,
                modifiedAt: Date(timeIntervalSince1970: 1),
                committedAt: Date(timeIntervalSince1970: 2),
                deviceName: "Device",
                platform: "macos",
                bodyB64: "",
                sha256: nil)
        }
        return RelayClient.ConflictRecord(
            conflictID: "conflict",
            itemUUID: UUID(),
            baseRevision: 1,
            currentRevision: 2,
            currentDeletedSequence: 0,
            generation: 3,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            candidates: candidates)
    }
}
