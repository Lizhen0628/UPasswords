import CryptoKit
import Foundation

/// Captures the local and remote identities that must remain stable while a
/// conflict candidate is copied into the current vault.
public struct ConflictCandidateCopyGuard {
    private let operationID: UUID
    private let sessionID: UUID
    private let vaultKeyDigest: Data
    private let databaseDigest: Data
    private let rowSync: RowSyncState
    private let conflictID: String
    private let generation: UInt64
    private let candidateIDs: Set<String>

    /// Creates an in-memory guard for one candidate-copy operation.
    /// - Parameters:
    ///   - operationID: Unique owner token for the operation.
    ///   - sessionID: Current unlocked-vault session generation.
    ///   - vaultKey: Raw vault key, used only to compute a non-reversible digest.
    ///   - databaseSnapshot: Serialized local database snapshot.
    ///   - rowSync: Synchronization state captured with the database snapshot.
    ///   - conflict: Conflict generation and complete candidate set being reviewed.
    public init(
        operationID: UUID,
        sessionID: UUID,
        vaultKey: Data,
        databaseSnapshot: Data,
        rowSync: RowSyncState,
        conflict: RelayClient.ConflictRecord
    ) {
        self.operationID = operationID
        self.sessionID = sessionID
        vaultKeyDigest = Data(SHA256.hash(data: vaultKey))
        databaseDigest = Data(SHA256.hash(data: databaseSnapshot))
        self.rowSync = rowSync
        conflictID = conflict.conflictID
        generation = conflict.generation
        candidateIDs = Set(conflict.candidates.map(\.candidateID))
    }

    /// Validates that no session, local snapshot, sync state, or candidate set changed.
    /// - Throws: Cancellation when ownership/session changed, a destination error when
    ///   local state changed, or a conflict error when the candidate set changed.
    public func validate(
        operationID currentOperationID: UUID?,
        sessionID currentSessionID: UUID,
        vaultKey: Data,
        databaseSnapshot: Data,
        rowSync currentRowSync: RowSyncState,
        isSyncing: Bool,
        conflict: RelayClient.ConflictRecord?
    ) throws {
        guard currentOperationID == operationID, currentSessionID == sessionID else {
            throw CancellationError()
        }
        let currentKeyDigest = Data(SHA256.hash(data: vaultKey))
        let currentDatabaseDigest = Data(SHA256.hash(data: databaseSnapshot))
        guard isSyncing,
              currentKeyDigest == vaultKeyDigest,
              currentDatabaseDigest == databaseDigest,
              currentRowSync == rowSync else {
            throw CrossDatabaseCardImporter.ImportError.destinationChanged
        }
        guard let conflict,
              conflict.conflictID == conflictID,
              conflict.generation == generation,
              Set(conflict.candidates.map(\.candidateID)) == candidateIDs else {
            throw RelayClient.RelayError.conflictCandidatesChanged
        }
    }
}
