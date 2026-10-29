import CryptoKit
import Foundation

import UPasswordsCore

/// Plans complete, non-destructive imports of selected cards between local databases.
public enum CrossDatabaseCardImporter {
    /// Maximum original size of an attachment accepted by a cross-database import.
    public static let maximumAttachmentBytes = AttachmentPolicy.maximumOriginalBytes

    /// An authenticated source database snapshot identified by its encrypted body.
    public struct SourceSnapshot {
        /// The decrypted source database used only during the local import flow.
        public let database: PasswordDatabase
        /// SHA-256 digest of the exact encrypted source body reviewed by the user.
        public let fingerprint: Data

        /// Creates a source snapshot for a reviewed encrypted database body.
        /// - Parameters:
        ///   - database: Decrypted database parsed from the source body.
        ///   - fingerprint: SHA-256 digest of that encrypted body.
        public init(database: PasswordDatabase, fingerprint: Data) {
            self.database = database
            self.fingerprint = fingerprint
        }
    }

    /// Reasons a source card cannot be imported without losing or misrepresenting data.
    public enum Rejection: Hashable {
        case alreadyImported
        case template
        case trashed
        case missingLabel
        case unavailableAttachment
        case attachmentTooLarge
    }

    /// A source card and the reasons it is or is not eligible for import.
    public struct Assessment: Identifiable {
        /// The source card being reviewed.
        public let card: Card
        /// All eligibility reasons found for this card.
        public let rejections: Set<Rejection>

        /// The source card identity used by the review list.
        public var id: UUID { card.id }
        /// Whether this card can be imported without dropping referenced data.
        public var isEligible: Bool { rejections.isEmpty }

        init(card: Card, rejections: Set<Rejection>) {
            self.card = card
            self.rejections = rejections
        }
    }

    /// The destination snapshot and sync state produced by one atomic import plan.
    public struct Plan {
        /// The destination database with new card and label identities.
        public let database: PasswordDatabase
        /// The destination sync state with new rows marked dirty and retry receipts stored.
        public let syncState: RowSyncState
        /// Destination identities of cards newly added by this plan.
        public let importedCardIDs: [UUID]
        /// Number of selected cards already imported from this exact source snapshot.
        public let alreadyImportedCount: Int
        /// Number of new source labels copied for this plan.
        public let createdLabelCount: Int

        init(database: PasswordDatabase, syncState: RowSyncState, importedCardIDs: [UUID],
             alreadyImportedCount: Int, createdLabelCount: Int) {
            self.database = database
            self.syncState = syncState
            self.importedCardIDs = importedCardIDs
            self.alreadyImportedCount = alreadyImportedCount
            self.createdLabelCount = createdLabelCount
        }
    }

    /// Errors raised when the reviewed source snapshot or selection is no longer usable.
    public enum ImportError: LocalizedError, Equatable {
        case invalidSourceSnapshot
        case noSelection
        case selectionChanged
        case selectionBlocked
        case sameDatabase
        case destinationUnavailable
        case destinationChanged
        case destinationSyncing

        public var errorDescription: String? {
            switch self {
            case .invalidSourceSnapshot:
                return L10n.t("database_card_import_fingerprint_error")
            case .noSelection:
                return L10n.t("database_card_import_no_selection")
            case .selectionChanged:
                return L10n.t("database_card_import_source_changed")
            case .selectionBlocked:
                return L10n.t("database_card_import_selection_blocked")
            case .sameDatabase:
                return L10n.t("database_card_import_same_database")
            case .destinationUnavailable:
                return L10n.t("database_card_import_unavailable")
            case .destinationChanged:
                return L10n.t("database_card_import_destination_changed")
            case .destinationSyncing:
                return L10n.t("database_card_import_syncing")
            }
        }
    }

    /// Reviews source cards against labels, attachments, and destination import receipts.
    /// - Parameters:
    ///   - source: Authenticated source snapshot shown to the user.
    ///   - syncState: Current destination sync state.
    /// - Returns: Assessments in source database order.
    /// - Throws: An invalid source fingerprint or duplicate source row identity.
    public static func assess(
        source: SourceSnapshot,
        syncState: RowSyncState
    ) throws -> [Assessment] {
        try validate(source)
        let sourceLabelIDs = Set(source.database.labels.map(\.id))
        return source.database.cards.map { card in
            Assessment(card: card, rejections: rejectionReasons(
                for: card,
                sourceFingerprint: source.fingerprint,
                sourceLabelIDs: sourceLabelIDs,
                syncState: syncState))
        }
    }

    /// Creates a new-identity import plan without mutating either input snapshot.
    /// - Parameters:
    ///   - source: Authenticated source snapshot reviewed by the user.
    ///   - destination: Current destination database.
    ///   - syncState: Current destination sync state.
    ///   - selectedCardIDs: Source card identities selected for import.
    ///   - now: Timestamp assigned to newly created destination rows.
    /// - Returns: Destination snapshot and sync state to commit atomically.
    /// - Throws: Invalid source snapshot, empty or stale selection, or an ineligible selected card.
    public static func makePlan(
        from source: SourceSnapshot,
        into destination: PasswordDatabase,
        syncState: RowSyncState,
        selecting selectedCardIDs: Set<UUID>,
        now: Date = Date()
    ) throws -> Plan {
        guard !selectedCardIDs.isEmpty else { throw ImportError.noSelection }

        let assessments = try assess(source: source, syncState: syncState)
        let assessmentByID = Dictionary(uniqueKeysWithValues: assessments.map { ($0.id, $0) })
        guard selectedCardIDs.allSatisfy({ assessmentByID[$0] != nil }) else {
            throw ImportError.selectionChanged
        }

        let selected = assessments.filter { selectedCardIDs.contains($0.id) }
        let alreadyImportedCount = selected.filter { $0.rejections == [.alreadyImported] }.count
        let newSelections = selected.filter { !$0.rejections.contains(.alreadyImported) }
        guard newSelections.allSatisfy(\.isEligible) else { throw ImportError.selectionBlocked }

        var nextDatabase = destination
        var nextState = syncState
        var itemIDs = identities(in: destination)
            .union(identities(in: source.database))
            .union(syncState.revisions.keys)
            .union(syncState.syncedMtimes.keys)
            .union(syncState.dirtyUpserts.keys)
            .union(syncState.dirtyDeletes.keys)
            .union(syncState.pendingConflicts.keys)
            .union(syncState.encryptedItemBaselines.keys)
        var importedCardIDs: [UUID] = []
        var labelIDs: [UUID: UUID] = [:]
        var sourceLabels: [UUID: CardLabel] = [:]
        for label in source.database.labels {
            guard sourceLabels.updateValue(label, forKey: label.id) == nil else {
                throw ImportError.invalidSourceSnapshot
            }
        }

        let modifiedAt = now.timeIntervalSince1970 * 1000
        for assessment in newSelections {
            var importedCard = assessment.card
            let importedID = Self.nextIdentity(avoiding: &itemIDs)
            importedCard.id = importedID
            importedCard.created = importedCard.created > 0 ? importedCard.created : modifiedAt
            importedCard.modified = modifiedAt

            var remappedLabelIDs: [UUID] = []
            for sourceLabelID in assessment.card.labelIds {
                if let importedLabelID = labelIDs[sourceLabelID] {
                    remappedLabelIDs.append(importedLabelID)
                    continue
                }
                guard let sourceLabel = sourceLabels[sourceLabelID] else {
                    throw ImportError.selectionBlocked
                }
                let importedLabel = CardLabel(
                    id: Self.nextIdentity(avoiding: &itemIDs),
                    name: sourceLabel.name,
                    color: sourceLabel.color,
                    type: sourceLabel.type,
                    pinToTop: sourceLabel.pinToTop,
                    timeStamp: modifiedAt)
                labelIDs[sourceLabelID] = importedLabel.id
                remappedLabelIDs.append(importedLabel.id)
                nextDatabase.labels.append(importedLabel)
                nextState.markDirty(uuid: importedLabel.id, modifiedMs: importedLabel.timeStamp)
            }
            importedCard.labelIds = remappedLabelIDs
            importedCard.fields = assessment.card.fields.map { field in
                Field(
                    id: Self.nextIdentity(avoiding: &itemIDs),
                    name: field.name,
                    type: field.type,
                    value: field.value,
                    autofill: field.autofill,
                    history: field.history)
            }
            importedCard.images = try assessment.card.images.map { try Self.copy($0, avoiding: &itemIDs) }
            importedCard.files = try assessment.card.files.map { try Self.copy($0, avoiding: &itemIDs) }

            nextDatabase.cards.append(importedCard)
            nextState.markDirty(uuid: importedID, modifiedMs: modifiedAt)
            nextState.importedSourceKeys.insert(sourceKey(fingerprint: source.fingerprint, cardID: assessment.id))
            importedCardIDs.append(importedID)
        }

        return Plan(
            database: nextDatabase,
            syncState: nextState,
            importedCardIDs: importedCardIDs,
            alreadyImportedCount: alreadyImportedCount,
            createdLabelCount: labelIDs.count)
    }

    private static func rejectionReasons(
        for card: Card,
        sourceFingerprint: Data,
        sourceLabelIDs: Set<UUID>,
        syncState: RowSyncState
    ) -> Set<Rejection> {
        let key = sourceKey(fingerprint: sourceFingerprint, cardID: card.id)
        if syncState.importedSourceKeys.contains(key) { return [.alreadyImported] }
        var reasons = Set<Rejection>()
        if card.template { reasons.insert(.template) }
        if card.trashed { reasons.insert(.trashed) }
        if card.labelIds.contains(where: { !sourceLabelIDs.contains($0) }) {
            reasons.insert(.missingLabel)
        }
        for attachment in card.images + card.files {
            guard let data = attachment.data else {
                reasons.insert(.unavailableAttachment)
                continue
            }
            if data.count > maximumAttachmentBytes {
                reasons.insert(.attachmentTooLarge)
            }
        }
        return reasons
    }

    private static func validate(_ source: SourceSnapshot) throws {
        let rowIDs = source.database.cards.map(\.id)
            + source.database.labels.map(\.id)
            + source.database.userProfiles.map(\.id)
        guard source.fingerprint.count == SHA256.Digest.byteCount,
              Set(rowIDs).count == rowIDs.count else {
            throw ImportError.invalidSourceSnapshot
        }
    }

    private static func identities(in database: PasswordDatabase) -> Set<UUID> {
        var ids = Set(database.cards.map(\.id))
            .union(database.labels.map(\.id))
            .union(database.userProfiles.map(\.id))
        for card in database.cards {
            ids.formUnion(card.fields.map(\.id))
            ids.formUnion((card.images + card.files).flatMap { [$0.id, $0.contentVersion] })
        }
        return ids
    }

    private static func copy(_ attachment: Attachment, avoiding usedIDs: inout Set<UUID>) throws -> Attachment {
        guard let data = attachment.data else { throw ImportError.selectionBlocked }
        return Attachment(
            id: nextIdentity(avoiding: &usedIDs),
            contentVersion: nextIdentity(avoiding: &usedIDs),
            name: attachment.name,
            data: data)
    }

    private static func sourceKey(fingerprint: Data, cardID: UUID) -> String {
        let input = fingerprint + Data(cardID.uuidString.lowercased().utf8)
        return Data(SHA256.hash(data: input)).base64EncodedString()
    }

    private static func nextIdentity(avoiding usedIDs: inout Set<UUID>) -> UUID {
        while true {
            let candidate = UUID()
            if usedIDs.insert(candidate).inserted { return candidate }
        }
    }
}
