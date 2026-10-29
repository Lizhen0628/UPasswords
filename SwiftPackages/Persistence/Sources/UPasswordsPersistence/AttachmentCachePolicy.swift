import Foundation

import UPasswordsCore

/// Plans byte-cache eviction while preserving metadata and all locally protected data.
public enum AttachmentCachePolicy {
    /// Initial per-database native cache budget; cloud quota is a separate server-side limit.
    public static let defaultBudgetBytes = 256 * 1024 * 1024

    /// A conservative cache plan. Persist its suppression ledger before committing removed bytes.
    public struct Plan {
        public let database: PasswordDatabase
        public let ledger: AttachmentDownloadLedger
        public let evictedVersions: Set<AttachmentDownloadLedger.Version>
        public let cachedBytes: Int
        public let hasCapacity: Bool
    }

    /// Evicts least-recently-used, verified synchronized cards only as much as the budget requires.
    ///
    /// Pending rows, conflict candidates, retained attachments, legacy identities, and requested
    /// versions are protected. Invalid baselines throw before either input is mutated.
    /// - Parameters:
    ///   - database: Current decrypted database snapshot.
    ///   - state: Matching row revisions and encrypted common baselines.
    ///   - key: Current vault key used to authenticate common baselines.
    ///   - ledger: Durable retry, retention, and access policy.
    ///   - budgetBytes: Maximum cached original bytes for this local database.
    ///   - incomingBytes: Space reserved for the next verified download.
    ///   - protectedVersions: Versions in use by a download, preview, export, or backup.
    /// - Returns: Unmodified inputs when there is no safe candidate, with capacity reported false.
    /// - Throws: Invalid budget or unavailable/invalid encrypted baseline.
    public static func makePlan(
        database: PasswordDatabase,
        state: RowSyncState,
        key: RowSyncKey,
        ledger: AttachmentDownloadLedger,
        budgetBytes: Int = defaultBudgetBytes,
        incomingBytes: Int = 0,
        protectedVersions: Set<AttachmentDownloadLedger.Version> = []
    ) throws -> Plan {
        guard budgetBytes >= 0, incomingBytes >= 0 else { throw RowSyncSafetyError.invalidResponse }
        let baselineByID = try state.validatedBaselines(key: key)
        var cachedBytes = 0
        var candidates: [(version: AttachmentDownloadLedger.Version, bytes: Int, access: Date)] = []
        for card in database.cards {
            let isSafe = state.revisions[card.id].map { $0 > 0 } == true
                && state.dirtyUpserts[card.id] == nil && state.dirtyDeletes[card.id] == nil
                && state.pendingConflicts[card.id] == nil
                && baselineByID[card.id]?.matches(.card(card)) == true
            for attachment in card.images + card.files {
                guard let data = attachment.data else { continue }
                let total = cachedBytes.addingReportingOverflow(data.count)
                guard !total.overflow else { throw RowSyncSafetyError.invalidResponse }
                cachedBytes = total.partialValue
                let version = AttachmentDownloadLedger.Version(
                    cardID: card.id, attachmentID: attachment.id, contentVersion: attachment.contentVersion)
                guard isSafe, attachment.hasPersistentID, attachment.hasPersistentContentVersion,
                      !ledger.offlineAttachments.contains(version.identity),
                      !protectedVersions.contains(version), !ledger.downloadAllVersions.contains(version),
                      !data.isEmpty else { continue }
                candidates.append((version, data.count, ledger.records[version]?.lastAccess ?? .distantPast))
            }
        }
        let targetBytes = max(0, budgetBytes - min(budgetBytes, incomingBytes))
        var evicted = Set<AttachmentDownloadLedger.Version>()
        for candidate in candidates.sorted(by: { left, right in
            if left.access != right.access { return left.access < right.access }
            let leftKey = left.version.identity.cardID.uuidString + left.version.identity.attachmentID.uuidString
            let rightKey = right.version.identity.cardID.uuidString + right.version.identity.attachmentID.uuidString
            return leftKey < rightKey
        }) where cachedBytes > targetBytes {
            evicted.insert(candidate.version)
            cachedBytes -= candidate.bytes
        }
        // Do not destroy useful caches when even all eligible evictions cannot make space.
        guard incomingBytes <= budgetBytes, cachedBytes <= targetBytes else {
            return Plan(database: database, ledger: ledger, evictedVersions: [],
                        cachedBytes: byteCount(in: database), hasCapacity: false)
        }
        var nextDatabase = database
        var nextLedger = ledger
        for index in nextDatabase.cards.indices {
            let cardID = nextDatabase.cards[index].id
            discard(evicted, from: &nextDatabase.cards[index].images, cardID: cardID)
            discard(evicted, from: &nextDatabase.cards[index].files, cardID: cardID)
        }
        for version in evicted { nextLedger.recordEviction(of: version) }
        return Plan(database: nextDatabase, ledger: nextLedger, evictedVersions: evicted,
                    cachedBytes: cachedBytes, hasCapacity: true)
    }

    private static func byteCount(in database: PasswordDatabase) -> Int {
        database.cards.reduce(0) { sum, card in
            sum + (card.images + card.files).reduce(0) { $0 + $1.length }
        }
    }

    private static func discard(
        _ versions: Set<AttachmentDownloadLedger.Version>, from attachments: inout [Attachment], cardID: UUID
    ) {
        for index in attachments.indices {
            let version = AttachmentDownloadLedger.Version(
                cardID: cardID, attachmentID: attachments[index].id,
                contentVersion: attachments[index].contentVersion)
            if versions.contains(version) { attachments[index].discardLocalContent() }
        }
    }
}
