import Foundation

import UPasswordsCore

/// Durable, non-secret download policy for one local database, independent of cloud cursors.
public struct AttachmentDownloadLedger: Codable, Equatable {
    /// Stable attachment identity within its parent card.
    public struct Identity: Codable, Hashable {
        public let cardID: UUID
        public let attachmentID: UUID

        /// Creates the identity used by offline retention across content replacements.
        public init(cardID: UUID, attachmentID: UUID) {
            self.cardID = cardID
            self.attachmentID = attachmentID
        }
    }

    /// Exact content version to which retries and cache suppression belong.
    public struct Version: Codable, Hashable {
        public let identity: Identity
        public let contentVersion: UUID

        /// Creates a task identity without retaining names, content, or credentials.
        public init(cardID: UUID, attachmentID: UUID, contentVersion: UUID) {
            identity = Identity(cardID: cardID, attachmentID: attachmentID)
            self.contentVersion = contentVersion
        }
    }

    /// Reasons background work cannot continue without a change in conditions.
    public enum Failure: String, Codable {
        case transient
        case authorization
        case integrity
        case unavailable
        case storage
        case permanent
    }

    /// Retry and local cache history for one exact attachment version.
    public struct Record: Codable, Equatable {
        public internal(set) var failure: Failure?
        public internal(set) var failureCount = 0
        public internal(set) var retryAt: Date?
        public internal(set) var isEvicted = false
        public internal(set) var lastAccess: Date?

        init() {}
    }

    /// Backoff after the first failure: at most five automatic retries per round.
    public static let retryDelays: [TimeInterval] = [2, 5, 15, 30, 60]
    public private(set) var records: [Version: Record] = [:]
    public private(set) var offlineAttachments: Set<Identity> = []
    private var authorizationFingerprint: Data?
    private let formatVersion: Int

    /// Creates a fresh ledger for a new or previously untracked local database.
    public init() { formatVersion = 1 }

    private enum CodingKeys: CodingKey {
        case formatVersion, records, offlineAttachments, authorizationFingerprint
    }

    /// Rejects damaged or unknown state instead of silently restarting failed downloads.
    /// - Parameter decoder: Local ledger decoder.
    /// - Throws: Invalid format, counters, timestamps, or retry state.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try values.decode(Int.self, forKey: .formatVersion)
        authorizationFingerprint = try values.decodeIfPresent(Data.self, forKey: .authorizationFingerprint)
        records = try values.decode([Version: Record].self, forKey: .records)
        offlineAttachments = try values.decode(Set<Identity>.self, forKey: .offlineAttachments)
        guard formatVersion == 1, records.values.allSatisfy({ record in
            (0...Self.retryDelays.count + 1).contains(record.failureCount)
                && ((record.failure == nil) == (record.failureCount == 0))
                && ((record.retryAt != nil) == (record.failure == .transient
                    && (1...Self.retryDelays.count).contains(record.failureCount)))
                && (record.retryAt?.timeIntervalSince1970.isFinite ?? true)
                && (record.lastAccess?.timeIntervalSince1970.isFinite ?? true)
        }) else {
            throw DecodingError.dataCorruptedError(
                forKey: .records, in: values, debugDescription: "Invalid attachment download ledger.")
        }
    }

    /// Whether this version can start without user intervention or a new retry round.
    public func isReady(_ version: Version, now: Date = Date()) -> Bool {
        guard let record = records[version] else { return true }
        guard !record.isEvicted else { return false }
        guard let failure = record.failure else { return true }
        return failure == .transient && record.retryAt.map { $0 <= now } == true
    }

    /// Records a failed GET; cancellation and policy pauses must not call this method.
    /// - Parameters:
    ///   - version: Exact failed content reference.
    ///   - failure: Classified failure; only transient failures retry automatically.
    ///   - now: Failure time, injectable in tests.
    ///   - minimumDelay: Server Retry-After lower bound when present.
    public mutating func recordFailure(
        for version: Version, failure: Failure, now: Date = Date(), minimumDelay: TimeInterval = 0
    ) {
        var record = records[version] ?? Record()
        record.failure = failure
        record.failureCount = min(record.failureCount + 1, Self.retryDelays.count + 1)
        record.retryAt = nil
        if failure == .transient, record.failureCount <= Self.retryDelays.count {
            let serverDelay = minimumDelay.isFinite ? max(0, minimumDelay) : 0
            let delay = max(Self.retryDelays[record.failureCount - 1], serverDelay)
            record.retryAt = now.addingTimeInterval(delay)
        }
        records[version] = record
    }

    /// Clears failures only after verified content has been installed and persisted.
    public mutating func recordSuccess(for version: Version, now: Date = Date()) {
        records[version] = Record()
        records[version]?.lastAccess = now
    }

    /// Explicit requests resume a cache-suppressed version; retry reset requires a manual retry.
    public mutating func request(_ version: Version, resetFailures: Bool) {
        var record = records[version] ?? Record()
        record.isEvicted = false
        if resetFailures {
            record.failure = nil
            record.failureCount = 0
            record.retryAt = nil
        }
        records[version] = record
    }

    /// Protects an attachment across content version changes until the user releases retention.
    public mutating func setKeptOffline(_ isKeptOffline: Bool, for identity: Identity) {
        if isKeptOffline {
            offlineAttachments.insert(identity)
        } else {
            offlineAttachments.remove(identity)
        }
    }

    /// Marks cache eviction before removing bytes, preventing automatic download/eviction loops.
    public mutating func recordEviction(of version: Version) {
        records[version, default: Record()].isEvicted = true
    }

    /// Records access to a locally available version without changing retry or retention policy.
    public mutating func recordAccess(to version: Version, now: Date = Date()) {
        records[version, default: Record()].lastAccess = now
    }

    /// Network recovery starts a fresh round only for transient failures, preserving all other pauses.
    public mutating func restartTransientFailures() {
        for version in records.keys where records[version]?.failure == .transient {
            records[version]?.failure = nil
            records[version]?.failureCount = 0
            records[version]?.retryAt = nil
        }
    }

    /// A new authorization can resume requests blocked by an expired account session.
    public mutating func resumeAfterAuthorization(fingerprint: Data) {
        guard fingerprint != authorizationFingerprint else { return }
        authorizationFingerprint = fingerprint
        for version in records.keys where records[version]?.failure == .authorization {
            request(version, resetFailures: true)
        }
    }

    /// Drops obsolete version history after a successful metadata refresh; offline choices remain.
    public mutating func reconcile(with database: PasswordDatabase) {
        let versions = Set(Self.versions(in: database))
        records = records.filter { versions.contains($0.key) }
    }

    /// Finds the earliest automatic retry among the current missing versions.
    public func nextRetry(in database: PasswordDatabase, now: Date = Date()) -> Date? {
        Self.versions(in: database, missingOnly: true).compactMap { version -> Date? in
            guard let record = records[version], !record.isEvicted,
                  record.failure == .transient, let retryAt = record.retryAt, retryAt > now else {
                return nil
            }
            return retryAt
        }.min()
    }

    /// Enumerates exact identities in display order, omitting untrusted legacy references.
    public static func versions(
        in database: PasswordDatabase, cardID: UUID? = nil, missingOnly: Bool = false
    ) -> [Version] {
        database.cards.filter { cardID == nil || $0.id == cardID }.flatMap { card in
            (card.images + card.files).compactMap { attachment in
                guard attachment.hasPersistentID, attachment.hasPersistentContentVersion,
                      !missingOnly || !attachment.hasContent else { return nil }
                return Version(cardID: card.id, attachmentID: attachment.id,
                               contentVersion: attachment.contentVersion)
            }
        }
    }
}
