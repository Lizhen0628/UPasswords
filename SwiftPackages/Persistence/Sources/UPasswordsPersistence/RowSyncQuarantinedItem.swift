import Foundation

/// A remote sync payload retained locally when its contents cannot be safely applied.
public struct RowSyncQuarantinedItem: Codable, Equatable, Identifiable {
    /// Where the unreadable payload was encountered.
    public enum Source: String, Codable {
        case change
        case snapshot
    }

    /// Why the payload was isolated.
    public enum Reason: String, Codable {
        case authenticationFailed
        case unsupportedFormat
    }

    enum Payload: Codable {
        case change(RelayClient.ChangeEntry)
        case snapshot(RelayClient.ListedItem)
    }

    /// Stable local identity; it is not a password-item identity.
    public var id: String {
        switch source {
        case .change: "change:\(sequence ?? -1)"
        case .snapshot: "snapshot:\(uuid.uuidString.lowercased()):\(revision)"
        }
    }

    /// Source item UUID, used only to preserve matching local content.
    public let uuid: UUID
    /// Change sequence, or nil when captured from a full snapshot.
    public let sequence: Int?
    /// Cloud item revision captured with the payload.
    public let revision: UInt64
    /// Payload source.
    public let source: Source
    /// Authentication or format failure category.
    public let reason: Reason
    /// Local capture time, not used to resolve conflicts.
    public let capturedAt: Date

    let encryptedPayload: Data

    init(uuid: UUID, sequence: Int?, revision: UInt64, source: Source, reason: Reason,
         capturedAt: Date = Date(), encryptedPayload: Data) {
        self.uuid = uuid
        self.sequence = sequence
        self.revision = revision
        self.source = source
        self.reason = reason
        self.capturedAt = capturedAt
        self.encryptedPayload = encryptedPayload
    }
}

/// A conflict candidate retained locally when its server ciphertext cannot be safely read.
public struct RowSyncQuarantinedCandidate: Codable, Equatable, Identifiable {
    /// Why the candidate was isolated.
    public enum Reason: String, Codable {
        case authenticationFailed
        case unsupportedFormat
    }

    /// Stable local identity bound to the original server identity.
    public var id: String { "\(conflictID):\(candidateID)" }
    /// Original conflict group identity.
    public let conflictID: String
    /// Original candidate identity.
    public let candidateID: String
    /// Source item UUID, also used as candidate ciphertext AAD.
    public let itemUUID: UUID
    /// Candidate sync kind (card, label, or user profile).
    public let kind: UInt8
    /// Candidate revision captured from the server.
    public let revision: UInt64
    /// Local capture time, not used to resolve the conflict.
    public let capturedAt: Date
    /// Authentication or format failure category.
    public let reason: Reason

    let encryptedPayload: Data

    init(
        conflictID: String,
        candidateID: String,
        itemUUID: UUID,
        kind: UInt8,
        revision: UInt64,
        capturedAt: Date = Date(),
        reason: Reason,
        encryptedPayload: Data
    ) {
        self.conflictID = conflictID
        self.candidateID = candidateID
        self.itemUUID = itemUUID
        self.kind = kind
        self.revision = revision
        self.capturedAt = capturedAt
        self.reason = reason
        self.encryptedPayload = encryptedPayload
    }
}
