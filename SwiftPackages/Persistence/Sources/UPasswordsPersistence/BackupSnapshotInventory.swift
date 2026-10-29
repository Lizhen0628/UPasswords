import CryptoKit
import Foundation

/// Stable fingerprint of cloud attachment history and conflict candidates.
public struct BackupSnapshotInventory: Equatable {
    /// SHA-256 fingerprint of canonicalized inventory metadata.
    public let fingerprint: String
    /// Highest committed row-change sequence observed with this inventory.
    public let headSequence: Int
    /// Number of retained attachment content versions.
    public let attachmentVersionCount: Int
    /// Number of unresolved row conflicts.
    public let conflictCount: Int
    /// Number of encrypted candidates across unresolved conflicts.
    public let conflictCandidateCount: Int
    /// Number of resolved conflicts with retained candidates.
    public let retainedConflictCount: Int
    /// Number of retained candidates from resolved conflicts.
    public let retainedConflictCandidateCount: Int
    /// Whether the service exposed the complete retained conflict history.
    public let retainedHistoryAvailable: Bool
    /// All validated attachment versions observed by the inventory request.
    public let attachmentVersions: [RelayClient.AttachmentVersionMetadata]
    /// All validated unresolved conflicts and encrypted candidates observed by the inventory request.
    public let conflicts: [RelayClient.ConflictRecord]
    /// Resolved conflict candidates still within their server retention period.
    public let retainedConflicts: [RelayClient.RetainedConflictRecord]

    /// Creates a canonical fingerprint from cloud attachment and conflict inventory responses.
    ///
    /// - Parameters:
    ///   - attachmentVersions: Current and retained attachment versions.
    ///   - conflicts: Unresolved conflicts with their complete candidate sets.
    ///   - retainedConflicts: Resolved conflicts whose candidates remain in retention.
    ///   - retainedHistoryAvailable: Whether all retained history pages were read successfully.
    /// - Throws: `RowSyncSafetyError.invalidResponse` for duplicate or malformed inventory.
    public init(
        headSequence: Int,
        attachmentVersions: [RelayClient.AttachmentVersionMetadata],
        conflicts: [RelayClient.ConflictRecord],
        retainedConflicts: [RelayClient.RetainedConflictRecord] = [],
        retainedHistoryAvailable: Bool = true
    ) throws {
        guard headSequence >= 0,
              retainedHistoryAvailable || retainedConflicts.isEmpty else {
            throw RowSyncSafetyError.invalidResponse
        }
        var attachmentKeys = Set<String>()
        var currentAttachmentIDs = Set<UUID>()
        let attachments = try attachmentVersions.map { version -> AttachmentEntry in
            let contentVersion = version.contentVersion?.uuidString.lowercased() ?? Self.legacyVersion
            let identity = "\(version.attachmentID.uuidString.lowercased()):\(contentVersion)"
            guard attachmentKeys.insert(identity).inserted,
                  version.bytes > 0,
                  Self.isSHA256(version.sha256),
                  (28...256).contains(version.dekWrapped.count),
                  !version.isCurrent || currentAttachmentIDs.insert(version.attachmentID).inserted else {
                throw RowSyncSafetyError.invalidResponse
            }
            return AttachmentEntry(
                identity: identity,
                cardID: version.cardID.uuidString.lowercased(),
                digest: version.sha256.lowercased(),
                bytes: version.bytes,
                wrappedKeyDigest: Self.sha256(version.dekWrapped),
                isCurrent: version.isCurrent)
        }.sorted { $0.identity < $1.identity }

        var conflictIDs = Set<String>()
        var candidateCount = 0
        var retainedCandidateCount = 0
        func candidateEntries(
            _ source: [RelayClient.ConflictCandidate],
            currentRevision: UInt64
        ) throws -> [CandidateEntry] {
            var candidateIDs = Set<String>()
            let result = try source.map { candidate -> CandidateEntry in
                guard Self.isIdentifier(candidate.candidateID),
                      candidateIDs.insert(candidate.candidateID).inserted,
                      candidate.revision <= currentRevision,
                      candidate.modifiedAt.timeIntervalSince1970.isFinite,
                      candidate.committedAt.timeIntervalSince1970.isFinite else {
                    throw RowSyncSafetyError.invalidResponse
                }
                let bodyDigest: String?
                if let bodyB64 = candidate.bodyB64 {
                    guard let body = Data(base64Encoded: bodyB64), !body.isEmpty else {
                        throw RowSyncSafetyError.invalidResponse
                    }
                    let actualDigest = Self.sha256(body)
                    guard !candidate.isDelete,
                          (1...3).contains(candidate.kind),
                          candidate.sha256 == actualDigest else {
                        throw RowSyncSafetyError.invalidResponse
                    }
                    bodyDigest = actualDigest
                } else {
                    guard candidate.isDelete,
                          candidate.sha256 == nil,
                          (1...3).contains(candidate.kind) else {
                        throw RowSyncSafetyError.invalidResponse
                    }
                    bodyDigest = nil
                }
                return CandidateEntry(
                    candidateID: candidate.candidateID,
                    kind: candidate.kind,
                    isDelete: candidate.isDelete,
                    revision: candidate.revision,
                    modifiedAt: candidate.modifiedAt.timeIntervalSince1970,
                    committedAt: candidate.committedAt.timeIntervalSince1970,
                    deviceName: candidate.deviceName,
                    platform: candidate.platform,
                    bodyDigest: bodyDigest,
                    declaredDigest: candidate.sha256)
            }.sorted { $0.candidateID < $1.candidateID }
            return result
        }
        let openEntries = try conflicts.map { conflict -> ConflictEntry in
            guard Self.isIdentifier(conflict.conflictID),
                  conflictIDs.insert(conflict.conflictID).inserted,
                  (2...32).contains(conflict.candidates.count),
                  conflict.baseRevision < conflict.currentRevision,
                  conflict.currentDeletedSequence >= 0,
                  conflict.generation > 0,
                  conflict.createdAt.timeIntervalSince1970.isFinite,
                  conflict.updatedAt.timeIntervalSince1970.isFinite else {
                throw RowSyncSafetyError.invalidResponse
            }
            let candidates = try candidateEntries(
                conflict.candidates,
                currentRevision: conflict.currentRevision)
            candidateCount += candidates.count
            return ConflictEntry(
                state: "open",
                conflictID: conflict.conflictID,
                itemUUID: conflict.itemUUID.uuidString.lowercased(),
                baseRevision: conflict.baseRevision,
                currentRevision: conflict.currentRevision,
                currentDeletedSequence: conflict.currentDeletedSequence,
                generation: conflict.generation,
                createdAt: conflict.createdAt.timeIntervalSince1970,
                updatedAt: conflict.updatedAt.timeIntervalSince1970,
                resolvedAt: nil,
                expiresAt: nil,
                selectedCandidateID: nil,
                candidates: candidates)
        }
        let retainedEntries = try retainedConflicts.map { conflict -> ConflictEntry in
            let resolvedAt = conflict.resolvedAt.timeIntervalSince1970
            let expiresAt = conflict.expiresAt.timeIntervalSince1970
            guard Self.isIdentifier(conflict.conflictID),
                  conflictIDs.insert(conflict.conflictID).inserted,
                  (1...32).contains(conflict.candidates.count),
                  conflict.baseRevision < conflict.currentRevision,
                  conflict.currentDeletedSequence >= 0,
                  conflict.generation > 0,
                  conflict.createdAt.timeIntervalSince1970.isFinite,
                  conflict.updatedAt.timeIntervalSince1970.isFinite,
                  resolvedAt.isFinite, resolvedAt > 0,
                  expiresAt.isFinite, expiresAt > resolvedAt,
                  conflict.selectedCandidateID.map(Self.isIdentifier) ?? true else {
                throw RowSyncSafetyError.invalidResponse
            }
            let candidates = try candidateEntries(
                conflict.candidates,
                currentRevision: conflict.currentRevision)
            let candidateIDs = Set(candidates.map(\.candidateID))
            guard conflict.selectedCandidateID.map(candidateIDs.contains) ?? true else {
                throw RowSyncSafetyError.invalidResponse
            }
            retainedCandidateCount += candidates.count
            return ConflictEntry(
                state: "retained",
                conflictID: conflict.conflictID,
                itemUUID: conflict.itemUUID.uuidString.lowercased(),
                baseRevision: conflict.baseRevision,
                currentRevision: conflict.currentRevision,
                currentDeletedSequence: conflict.currentDeletedSequence,
                generation: conflict.generation,
                createdAt: conflict.createdAt.timeIntervalSince1970,
                updatedAt: conflict.updatedAt.timeIntervalSince1970,
                resolvedAt: resolvedAt,
                expiresAt: expiresAt,
                selectedCandidateID: conflict.selectedCandidateID,
                candidates: candidates)
        }
        let conflictEntries = (openEntries + retainedEntries).sorted { $0.conflictID < $1.conflictID }

        let canonical = CanonicalInventory(
            headSequence: headSequence,
            attachments: attachments,
            conflicts: conflictEntries,
            retainedHistoryAvailable: retainedHistoryAvailable)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded = try encoder.encode(canonical)
        fingerprint = Self.sha256(encoded)
        self.headSequence = headSequence
        attachmentVersionCount = attachments.count
        conflictCount = openEntries.count
        conflictCandidateCount = candidateCount
        retainedConflictCount = retainedEntries.count
        retainedConflictCandidateCount = retainedCandidateCount
        self.retainedHistoryAvailable = retainedHistoryAvailable
        self.attachmentVersions = attachmentVersions
        self.conflicts = conflicts
        self.retainedConflicts = retainedConflicts
    }

    /// Compares two inventories captured at different points in a backup operation.
    /// - Parameter other: Later inventory.
    /// - Returns: True when both describe the same row, attachment, and conflict snapshot.
    public func matches(_ other: Self) -> Bool {
        fingerprint == other.fingerprint
    }

    private static let legacyVersion = "00000000-0000-0000-0000-000000000000"

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }

    private static func isIdentifier(_ value: String) -> Bool {
        value.count == 32 && value == value.lowercased() && value.allSatisfy(\.isHexDigit)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct CanonicalInventory: Encodable {
        let headSequence: Int
        let attachments: [AttachmentEntry]
        let conflicts: [ConflictEntry]
        let retainedHistoryAvailable: Bool
    }

    private struct AttachmentEntry: Encodable {
        let identity: String
        let cardID: String
        let digest: String
        let bytes: Int64
        let wrappedKeyDigest: String
        let isCurrent: Bool
    }

    private struct ConflictEntry: Encodable {
        let state: String
        let conflictID: String
        let itemUUID: String
        let baseRevision: UInt64
        let currentRevision: UInt64
        let currentDeletedSequence: Int
        let generation: UInt64
        let createdAt: TimeInterval
        let updatedAt: TimeInterval
        let resolvedAt: TimeInterval?
        let expiresAt: TimeInterval?
        let selectedCandidateID: String?
        let candidates: [CandidateEntry]
    }

    private struct CandidateEntry: Encodable {
        let candidateID: String
        let kind: UInt8
        let isDelete: Bool
        let revision: UInt64
        let modifiedAt: TimeInterval
        let committedAt: TimeInterval
        let deviceName: String
        let platform: String
        let bodyDigest: String?
        let declaredDigest: String?
    }
}
