import CryptoKit
import Foundation

import UPasswordsCore

/// A self-contained directory package containing an encrypted database snapshot and retained cloud data.
public enum BackupPackage {
    /// File extension used for local backup package directories.
    public static let fileExtension = "upwbackup"

    private static let formatVersion = 1
    private static let infoFileName = "Info.json"
    private static let manifestFileName = "Manifest.sealed"
    private static let historyAAD = Data("UPW-BACKUP-HISTORY-V1".utf8)
    private static let databaseFileName = "Snapshot.upw"
    private static let envelopeFileName = "Snapshot.upwkey"
    private static let manifestAAD = Data("UPW-BACKUP-MANIFEST-V1".utf8)
    private static let maximumInfoFileBytes = 1_048_576
    private static let legacyContentVersion = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    /// Non-sensitive package index used for listing backups before the user supplies a password.
    public struct Info: Codable, Equatable, Sendable {
        /// Supported package format version.
        public let version: Int
        /// Snapshot creation time.
        public let createdAt: Date
        /// Whether every known payload was captured and the remote inventory remained stable.
        public let isComplete: Bool
        /// Number of recoverable attachment versions captured.
        public let attachmentVersionCount: Int
        /// Number of conflict records captured, including retained resolved history.
        public let conflictCount: Int
        /// Number of candidate records captured, including delete markers.
        public let conflictCandidateCount: Int
        /// Number of known omissions or consistency problems.
        public let issueCount: Int

        /// Creates the package's non-sensitive listing index.
        public init(
            version: Int,
            createdAt: Date,
            isComplete: Bool,
            attachmentVersionCount: Int,
            conflictCount: Int,
            conflictCandidateCount: Int,
            issueCount: Int
        ) {
            self.version = version
            self.createdAt = createdAt
            self.isComplete = isComplete
            self.attachmentVersionCount = attachmentVersionCount
            self.conflictCount = conflictCount
            self.conflictCandidateCount = conflictCandidateCount
            self.issueCount = issueCount
        }
    }

    /// A known reason a package cannot claim complete recovery.
    public enum Issue: Codable, Equatable, Hashable, Sendable {
        case cloudInventoryUnavailable
        case cloudInventoryChanged
        case retainedConflictHistoryUnavailable
        case localSnapshotBehindCloud(localCursor: Int, cloudHead: Int)
        case localConflictUnavailable(itemID: UUID)
        case attachmentIdentityUnavailable(cardID: UUID)
        case attachmentVersionUnavailable(attachmentID: UUID, contentVersion: UUID)
        case conflictCandidateUnavailable(conflictID: String, candidateID: String)

        /// Localized non-secret explanation suitable for an incomplete-restore review.
        public var summary: String {
            switch self {
            case .cloudInventoryUnavailable:
                return L10n.t("backup_issue_cloud_unavailable")
            case .cloudInventoryChanged:
                return L10n.t("backup_issue_cloud_changed")
            case .retainedConflictHistoryUnavailable:
                return L10n.t("backup_issue_retained_conflicts_unavailable")
            case .localSnapshotBehindCloud(let localCursor, let cloudHead):
                return String(
                    format: L10n.t("backup_issue_snapshot_behind_fmt"),
                    localCursor,
                    cloudHead)
            case .localConflictUnavailable(let itemID):
                return String(format: L10n.t("backup_issue_conflict_unavailable_fmt"), itemID.uuidString)
            case .attachmentIdentityUnavailable(let cardID):
                return String(format: L10n.t("backup_issue_attachment_identity_fmt"), cardID.uuidString)
            case .attachmentVersionUnavailable(let attachmentID, let contentVersion):
                return String(
                    format: L10n.t("backup_issue_attachment_version_fmt"),
                    attachmentID.uuidString,
                    contentVersion.uuidString)
            case .conflictCandidateUnavailable(let conflictID, let candidateID):
                return String(
                    format: L10n.t("backup_issue_candidate_unavailable_fmt"),
                    conflictID,
                    candidateID)
            }
        }
    }

    /// Counts and issues presented before allowing an incomplete restore.
    public struct Assessment: Equatable, Sendable {
        /// Whether every known payload is present and authenticated.
        public let isComplete: Bool
        /// Number of cards in the database snapshot.
        public let cardCount: Int
        /// Number of attachment versions described by the package.
        public let attachmentVersionCount: Int
        /// Number of conflict records described by the package, including retained resolved history.
        public let conflictCount: Int
        /// Number of candidate records described by the package, including delete markers.
        public let conflictCandidateCount: Int
        /// Known omissions or consistency problems.
        public let issues: [Issue]
        /// Stable token binding the user-reviewed assessment to these package contents.
        public let verificationToken: String?

        init(
            isComplete: Bool,
            cardCount: Int,
            attachmentVersionCount: Int,
            conflictCount: Int,
            conflictCandidateCount: Int,
            issues: [Issue],
            verificationToken: String? = nil
        ) {
            self.isComplete = isComplete
            self.cardCount = cardCount
            self.attachmentVersionCount = attachmentVersionCount
            self.conflictCount = conflictCount
            self.conflictCandidateCount = conflictCandidateCount
            self.issues = issues
            self.verificationToken = verificationToken
        }
    }

    /// Read-only historical payloads preserved when a package is restored as a new database.
    /// The complete value is authenticated and encrypted under the restored database key.
    public struct RestoredHistory: Codable {
        /// Original package creation time.
        public let sourceCreatedAt: Date
        /// Historical and current attachment versions retained outside the active card snapshot.
        public let attachmentVersions: [HistoricalAttachment]
        /// Conflict records and candidates retained without registering them as active conflicts.
        public let conflicts: [HistoricalConflict]
        /// Ciphertext preserved as quarantined material without claiming successful authentication.
        public let quarantinedAttachments: [QuarantinedAttachment]
        /// Ciphertext preserved as quarantined material without claiming successful authentication.
        public let quarantinedCandidates: [QuarantinedCandidate]
        /// Missing or invalid source payloads preserved as omissions, not fabricated values.
        public let issues: [Issue]

        public init(
            sourceCreatedAt: Date,
            attachmentVersions: [HistoricalAttachment],
            conflicts: [HistoricalConflict],
            issues: [Issue],
            quarantinedAttachments: [QuarantinedAttachment] = [],
            quarantinedCandidates: [QuarantinedCandidate] = []
        ) {
            self.sourceCreatedAt = sourceCreatedAt
            self.attachmentVersions = attachmentVersions
            self.conflicts = conflicts
            self.quarantinedAttachments = quarantinedAttachments
            self.quarantinedCandidates = quarantinedCandidates
            self.issues = issues
        }

        private enum CodingKeys: String, CodingKey {
            case sourceCreatedAt, attachmentVersions, conflicts
            case quarantinedAttachments, quarantinedCandidates, issues
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            sourceCreatedAt = try container.decode(Date.self, forKey: .sourceCreatedAt)
            attachmentVersions = try container.decode([HistoricalAttachment].self, forKey: .attachmentVersions)
            conflicts = try container.decode([HistoricalConflict].self, forKey: .conflicts)
            quarantinedAttachments = try container.decodeIfPresent(
                [QuarantinedAttachment].self, forKey: .quarantinedAttachments) ?? []
            quarantinedCandidates = try container.decodeIfPresent(
                [QuarantinedCandidate].self, forKey: .quarantinedCandidates) ?? []
            issues = try container.decode([Issue].self, forKey: .issues)
        }
    }

    /// Unauthenticated attachment ciphertext retained under the history archive's outer encryption.
    public struct QuarantinedAttachment: Codable {
        public let attachmentID: UUID
        public let cardID: UUID
        public let contentVersion: UUID
        public let isCurrent: Bool
        public let sha256: String
        public let bytes: Int64
        public let dekWrapped: Data
        public let cipher: Data

        public init(
            attachmentID: UUID,
            cardID: UUID,
            contentVersion: UUID,
            isCurrent: Bool,
            sha256: String,
            bytes: Int64,
            dekWrapped: Data,
            cipher: Data
        ) {
            self.attachmentID = attachmentID
            self.cardID = cardID
            self.contentVersion = contentVersion
            self.isCurrent = isCurrent
            self.sha256 = sha256
            self.bytes = bytes
            self.dekWrapped = dekWrapped
            self.cipher = cipher
        }
    }

    /// Unauthenticated conflict ciphertext linked to its original conflict and candidate identities.
    public struct QuarantinedCandidate: Codable {
        public let conflictID: String
        public let candidateID: String
        public let sha256: String
        public let cipher: Data

        public init(conflictID: String, candidateID: String, sha256: String, cipher: Data) {
            self.conflictID = conflictID
            self.candidateID = candidateID
            self.sha256 = sha256
            self.cipher = cipher
        }
    }

    /// One separately encrypted attachment version in a restored history archive.
    public struct HistoricalAttachment: Codable {
        public let attachmentID: UUID
        public let cardID: UUID
        public let contentVersion: UUID
        public let isCurrent: Bool
        public let sha256: String
        public let bytes: Int64
        public let dekWrapped: Data?
        public let cipher: Data?

        public init(
            attachmentID: UUID,
            cardID: UUID,
            contentVersion: UUID,
            isCurrent: Bool,
            sha256: String,
            bytes: Int64,
            dekWrapped: Data?,
            cipher: Data?
        ) {
            self.attachmentID = attachmentID
            self.cardID = cardID
            self.contentVersion = contentVersion
            self.isCurrent = isCurrent
            self.sha256 = sha256
            self.bytes = bytes
            self.dekWrapped = dekWrapped
            self.cipher = cipher
        }
    }

    /// A historical conflict record retained separately from the restored database's live state.
    public struct HistoricalConflict: Codable {
        public let conflictID: String
        public let itemUUID: UUID
        public let baseRevision: UInt64
        public let currentRevision: UInt64
        public let currentDeletedSequence: Int
        public let generation: UInt64
        public let createdAt: Date
        public let updatedAt: Date
        public let resolvedAt: Date?
        public let expiresAt: Date?
        public let selectedCandidateID: String?
        public let candidates: [HistoricalCandidate]

        public init(
            conflictID: String,
            itemUUID: UUID,
            baseRevision: UInt64,
            currentRevision: UInt64,
            currentDeletedSequence: Int,
            generation: UInt64,
            createdAt: Date,
            updatedAt: Date,
            resolvedAt: Date? = nil,
            expiresAt: Date? = nil,
            selectedCandidateID: String? = nil,
            candidates: [HistoricalCandidate]
        ) {
            self.conflictID = conflictID
            self.itemUUID = itemUUID
            self.baseRevision = baseRevision
            self.currentRevision = currentRevision
            self.currentDeletedSequence = currentDeletedSequence
            self.generation = generation
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.resolvedAt = resolvedAt
            self.expiresAt = expiresAt
            self.selectedCandidateID = selectedCandidateID
            self.candidates = candidates
        }
    }

    /// One candidate retained as encrypted row data or an explicit delete marker.
    public struct HistoricalCandidate: Codable {
        public struct Source: Codable {
            public let deviceName: String
            public let platform: String

            public init(deviceName: String, platform: String) {
                self.deviceName = deviceName
                self.platform = platform
            }
        }

        public struct EncryptedContent: Codable {
            public let sha256: String?
            public let cipher: Data?

            public init(sha256: String?, cipher: Data?) {
                self.sha256 = sha256
                self.cipher = cipher
            }
        }

        public let candidateID: String
        public let kind: UInt8
        public let isDelete: Bool
        public let revision: UInt64
        public let modifiedAt: Date
        public let committedAt: Date
        public let deviceName: String
        public let platform: String
        public let sha256: String?
        public let cipher: Data?

        public init(
            candidateID: String,
            kind: UInt8,
            isDelete: Bool,
            revision: UInt64,
            modifiedAt: Date,
            committedAt: Date,
            source: Source,
            content: EncryptedContent
        ) {
            self.candidateID = candidateID
            self.kind = kind
            self.isDelete = isDelete
            self.revision = revision
            self.modifiedAt = modifiedAt
            self.committedAt = committedAt
            deviceName = source.deviceName
            platform = source.platform
            sha256 = content.sha256
            cipher = content.cipher
        }
    }

    struct PreparedRestore {
        let database: PasswordDatabase
        let vaultKey: SymmetricKey
        let envelope: Data
        let sealedHistory: Data
        let assessment: Assessment
    }

    /// Authenticated account access used to capture cloud-only attachment and conflict data.
    public struct CloudSource {
        /// Relay client configured for the current app environment.
        public let client: RelayClient
        /// Current account authorization token.
        public let token: String
        /// Cloud vault identity bound to the local database.
        public let vaultID: String

        /// Creates a cloud capture source.
        public init(client: RelayClient, token: String, vaultID: String) {
            self.client = client
            self.token = token
            self.vaultID = vaultID
        }
    }

    /// Result of creating a staged package and publishing it as one directory rename.
    public struct CaptureResult: Equatable {
        /// Published backup package directory.
        public let url: URL
        /// Captured completeness and item counts.
        public let assessment: Assessment
    }

    /// Captures the local snapshot and, when authorized, all retained cloud attachment and conflict payloads.
    ///
    /// The source database and its current session state are values, so later app edits cannot mutate
    /// this capture. Cloud endpoints are sampled before and after payload downloads; any change marks
    /// the package incomplete. Individual missing payloads are recorded without failing the local snapshot.
    ///
    /// - Parameters:
    ///   - store: Database store receiving the package.
    ///   - name: Existing local database name.
    ///   - database: Decrypted local snapshot to preserve.
    ///   - vaultKey: Current key used for the encrypted snapshot and manifest.
    ///   - syncState: Matching local cursor and pending-conflict state.
    ///   - cloud: Optional authorized cloud source.
    ///   - now: Package creation date, injectable for tests.
    /// - Returns: The published package and its completeness assessment.
    /// - Throws: Snapshot encryption, local file, or cancellation errors.
    public static func capture(
        store: DatabaseStore,
        name: String,
        database: PasswordDatabase,
        vaultKey: SymmetricKey,
        syncState: RowSyncState,
        cloud: CloudSource? = nil,
        cloudRequired: Bool = false,
        now: Date = Date()
    ) async throws -> CaptureResult {
        let startedAt = Date()
        let reservation = try store.reserveBackupPackage(name: name, now: now)
        let fileManager = FileManager.default
        let attachmentDirectory = reservation.stagingURL.appendingPathComponent("Attachments", isDirectory: true)
        let conflictDirectory = reservation.stagingURL.appendingPathComponent("Conflicts", isDirectory: true)
        do {
            try fileManager.createDirectory(at: attachmentDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: conflictDirectory, withIntermediateDirectories: true)

            let body = try DatabaseCipher.encryptBody(database.xmlData(), vaultKey: vaultKey)
            guard let envelope = store.envelopeData(for: name),
                  DatabaseCipher.envelopeChangedAt(envelope) != nil else {
                throw DatabaseStore.StoreError(L10n.t("envelope_missing_error"))
            }
            try body.write(
                to: reservation.stagingURL.appendingPathComponent(databaseFileName),
                options: .atomic)
            try envelope.write(
                to: reservation.stagingURL.appendingPathComponent(envelopeFileName),
                options: .atomic)

            var issues: [Issue] = []
            var attachments: [AttachmentDescriptor] = []
            var conflicts: [ConflictDescriptor] = []
            var initialInventory: BackupSnapshotInventory?
            let rowKey = RowSyncKey(raw: vaultKey.withUnsafeBytes { Data($0) })

            if let cloud {
                do {
                    initialInventory = try await cloud.client.getBackupSnapshotInventory(
                        token: cloud.token,
                        vaultId: cloud.vaultID)
                    if let initialInventory, syncState.cursor != initialInventory.headSequence {
                        issues.append(.localSnapshotBehindCloud(
                            localCursor: syncState.cursor,
                            cloudHead: initialInventory.headSequence))
                    }
                    try Task.checkCancellation()
                    if let initialInventory {
                        if !initialInventory.retainedHistoryAvailable {
                            issues.append(.retainedConflictHistoryUnavailable)
                        }
                        let knownConflictIDs = Set(
                            initialInventory.conflicts.map(\.conflictID)
                                + initialInventory.retainedConflicts.map(\.conflictID))
                        // Local markers are consistency evidence; encrypted candidate payloads come from inventory.
                        for (itemID, marker) in syncState.pendingConflicts
                            where !knownConflictIDs.contains(marker.conflictID) {
                            issues.append(.localConflictUnavailable(itemID: itemID))
                        }
                        attachments = try await captureAttachments(
                            initialInventory.attachmentVersions,
                            client: cloud.client,
                            token: cloud.token,
                            vaultID: cloud.vaultID,
                            key: rowKey,
                            destination: attachmentDirectory,
                            issues: &issues)
                        var conflictSources = initialInventory.conflicts.map { conflict in
                            ConflictCaptureSource(
                                conflictID: conflict.conflictID,
                                itemUUID: conflict.itemUUID,
                                baseRevision: conflict.baseRevision,
                                currentRevision: conflict.currentRevision,
                                currentDeletedSequence: conflict.currentDeletedSequence,
                                generation: conflict.generation,
                                createdAt: conflict.createdAt,
                                updatedAt: conflict.updatedAt,
                                resolvedAt: nil,
                                expiresAt: nil,
                                selectedCandidateID: nil,
                                candidates: conflict.candidates)
                        } + initialInventory.retainedConflicts.map { conflict in
                            ConflictCaptureSource(
                                conflictID: conflict.conflictID,
                                itemUUID: conflict.itemUUID,
                                baseRevision: conflict.baseRevision,
                                currentRevision: conflict.currentRevision,
                                currentDeletedSequence: conflict.currentDeletedSequence,
                                generation: conflict.generation,
                                createdAt: conflict.createdAt,
                                updatedAt: conflict.updatedAt,
                                resolvedAt: conflict.resolvedAt,
                                expiresAt: conflict.expiresAt,
                                selectedCandidateID: conflict.selectedCandidateID,
                                candidates: conflict.candidates)
                        }
                        let cloudCandidateIDs = Set(conflictSources.flatMap { conflict in
                            conflict.candidates.map {
                                "\(conflict.conflictID):\($0.candidateID)"
                            }
                        })
                        conflictSources.append(contentsOf: try localQuarantinedConflictSources(
                            syncState,
                            key: rowKey,
                            excluding: cloudCandidateIDs))
                        conflicts = try captureConflicts(
                            conflictSources,
                            key: rowKey,
                            destination: conflictDirectory,
                            issues: &issues)
                        appendMissingReferenceIssues(
                            for: database,
                            attachments: attachments,
                            inventory: initialInventory,
                            issues: &issues)
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    Log.error("backup", "cloud inventory capture failed for \"\(name)\": \(error)")
                    issues.append(.cloudInventoryUnavailable)
                }
            } else {
                if cloudRequired || syncState.cursor > 0 || !syncState.revisions.isEmpty
                    || !syncState.pendingConflicts.isEmpty
                    || !syncState.quarantinedCandidates.isEmpty {
                    issues.append(.cloudInventoryUnavailable)
                }
                for card in database.cards {
                    for attachment in card.images + card.files where attachment.data == nil {
                        if attachment.hasPersistentID, attachment.hasPersistentContentVersion {
                            issues.append(.attachmentVersionUnavailable(
                                attachmentID: attachment.id,
                                contentVersion: attachment.contentVersion))
                        } else {
                            issues.append(.attachmentIdentityUnavailable(cardID: card.id))
                        }
                    }
                }
                conflicts = try captureConflicts(
                    localQuarantinedConflictSources(
                        syncState,
                        key: rowKey,
                        excluding: []),
                    key: rowKey,
                    destination: conflictDirectory,
                    issues: &issues)
            }

            try Task.checkCancellation()
            if let cloud, let initialInventory {
                do {
                    let finalInventory = try await cloud.client.getBackupSnapshotInventory(
                        token: cloud.token,
                        vaultId: cloud.vaultID)
                    if !initialInventory.matches(finalInventory) {
                        issues.append(.cloudInventoryChanged)
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    Log.error("backup", "cloud inventory recheck failed for \"\(name)\": \(error)")
                    issues.append(.cloudInventoryChanged)
                }
            }

            let uniqueIssues = Array(Set(issues)).sorted { Self.issueSortKey($0) < Self.issueSortKey($1) }
            let manifest = Manifest(
                version: formatVersion,
                createdAt: now,
                bodyDigest: Data(SHA256.hash(data: body)),
                envelopeDigest: Data(SHA256.hash(data: envelope)),
                headSequence: initialInventory?.headSequence,
                attachments: attachments,
                conflicts: conflicts,
                issues: uniqueIssues)
            let sealedManifest = try sealManifest(manifest, key: vaultKey)
            try sealedManifest.write(
                to: reservation.stagingURL.appendingPathComponent(manifestFileName),
                options: .atomic)
            let info = Info(
                version: formatVersion,
                createdAt: now,
                isComplete: uniqueIssues.isEmpty,
                attachmentVersionCount: attachments.count,
                conflictCount: conflicts.count,
                conflictCandidateCount: conflicts.reduce(0) { $0 + $1.candidates.count },
                issueCount: uniqueIssues.count)
            try JSONEncoder().encode(info).write(
                to: reservation.stagingURL.appendingPathComponent(infoFileName),
                options: .atomic)
            try Task.checkCancellation()
            let published = try store.publishBackupPackage(reservation, name: name)
            let assessment = Assessment(
                isComplete: info.isComplete,
                cardCount: database.cards.count,
                attachmentVersionCount: info.attachmentVersionCount,
                conflictCount: info.conflictCount,
                conflictCandidateCount: info.conflictCandidateCount,
                issues: uniqueIssues)
            let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
            Log.info(
                "backup",
                "package capture finished \"\(name)\" complete=\(info.isComplete) attachments=\(info.attachmentVersionCount) conflicts=\(info.conflictCount) ms=\(elapsed)")
            return CaptureResult(url: published, assessment: assessment)
        } catch {
            try? fileManager.removeItem(at: reservation.stagingURL)
            Log.error("backup", "package capture failed for \"\(name)\": \(error)")
            throw error
        }
    }

    /// Reads the non-sensitive package index without unlocking its encrypted manifest.
    /// - Parameter url: Package directory or portable archive file.
    /// - Returns: Listing index when the package layout is recognized.
    /// - Throws: File access or unsupported format errors.
    public static func readInfo(at url: URL) throws -> Info {
        let isDirectory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        let data: Data
        if isDirectory {
            data = try Data(contentsOf: url.appendingPathComponent(infoFileName))
        } else {
            data = try PortableBackupArchive.readFile(
                at: url,
                path: infoFileName,
                maximumSize: maximumInfoFileBytes)
        }
        let info = try JSONDecoder().decode(Info.self, from: data)
        guard info.version == formatVersion,
              info.attachmentVersionCount >= 0,
              info.conflictCount >= 0,
              info.conflictCandidateCount >= 0,
              info.issueCount >= 0 else {
            throw BackupPackageError.unsupportedFormat
        }
        return info
    }

    /// Checks whether the package has the required top-level files and supported index.
    /// This is a structural check only; payload authenticity requires `assess(at:sourcePassword:)`.
    /// - Parameter url: Candidate package directory.
    /// - Returns: Whether the package layout is recognizable.
    public static func hasValidStructure(at url: URL) -> Bool {
        hasValidContents(at: url)
    }

    /// Exports a validated package directory as one portable USTAR file.
    ///
    /// - Parameters:
    ///   - package: Existing self-contained package directory.
    ///   - archive: Destination file URL that does not already exist.
    /// - Throws: Invalid package contents or archive I/O errors.
    public static func exportPortableArchive(from package: URL, to archive: URL) throws {
        guard package.pathExtension == fileExtension, hasValidContents(at: package) else {
            throw BackupPackageError.invalidPackage
        }
        try PortableBackupArchive.createArchive(from: package, to: archive)
    }

    /// Authenticates a package and every retained payload before presenting a restore decision.
    /// - Parameters:
    ///   - url: Self-contained backup directory or portable USTAR archive file.
    ///   - sourcePassword: Password used when the package snapshot was created.
    /// - Returns: Verified counts, omissions, and a token binding a later restore to this review.
    /// - Throws: Wrong password, unsupported format, or an unreadable snapshot/manifest.
    public static func assess(at url: URL, sourcePassword: String) throws -> Assessment {
        try loadVerifiedPackage(at: url, sourcePassword: sourcePassword).assessment
    }

    static func prepareRestore(
        at url: URL,
        sourcePassword: String,
        newPassword: String,
        expectedVerificationToken: String?,
        allowIncomplete: Bool
    ) throws -> PreparedRestore {
        let verified = try loadVerifiedPackage(at: url, sourcePassword: sourcePassword)
        guard let expectedVerificationToken,
              expectedVerificationToken == verified.assessment.verificationToken else {
            throw BackupPackageError.packageChanged
        }
        guard verified.assessment.isComplete || allowIncomplete else {
            throw BackupPackageError.incompleteRestoreRequiresConfirmation
        }

        var database = verified.database
        for cardIndex in database.cards.indices {
            for attachmentIndex in database.cards[cardIndex].images.indices {
                let attachment = database.cards[cardIndex].images[attachmentIndex]
                let identity = AttachmentIdentity(
                    attachmentID: attachment.id,
                    contentVersion: attachment.contentVersion)
                guard let data = verified.attachmentData[identity] else { continue }
                _ = database.cards[cardIndex].images[attachmentIndex]
                    .installDownloadedContent(data, for: attachment.contentVersion)
            }
            for attachmentIndex in database.cards[cardIndex].files.indices {
                let attachment = database.cards[cardIndex].files[attachmentIndex]
                let identity = AttachmentIdentity(
                    attachmentID: attachment.id,
                    contentVersion: attachment.contentVersion)
                guard let data = verified.attachmentData[identity] else { continue }
                _ = database.cards[cardIndex].files[attachmentIndex]
                    .installDownloadedContent(data, for: attachment.contentVersion)
            }
        }

        let vaultKey = DatabaseCipher.generateVaultKey()
        let envelope = try DatabaseCipher.wrapVaultKey(vaultKey, password: newPassword)
        let sealedHistory = try sealRestoredHistory(
            manifest: verified.manifest,
            attachmentData: verified.attachmentData,
            candidateData: verified.candidateData,
            quarantinedAttachmentCiphers: verified.quarantinedAttachmentCiphers,
            quarantinedCandidateCiphers: verified.quarantinedCandidateCiphers,
            issues: verified.assessment.issues,
            vaultKey: vaultKey)
        return PreparedRestore(
            database: database,
            vaultKey: vaultKey,
            envelope: envelope,
            sealedHistory: sealedHistory,
            assessment: verified.assessment)
    }

    static func openRestoredHistory(
        _ sealedData: Data,
        vaultKey: SymmetricKey
    ) throws -> RestoredHistory {
        do {
            let box = try AES.GCM.SealedBox(combined: sealedData)
            let plaintext = try AES.GCM.open(box, using: vaultKey, authenticating: historyAAD)
            return try JSONDecoder().decode(RestoredHistory.self, from: plaintext)
        } catch {
            throw BackupPackageError.invalidPackage
        }
    }

    /// Re-encrypts retained history when the owning vault key rotates.
    ///
    /// Authenticated payloads are re-encrypted under the new key. Quarantined source ciphertext stays
    /// opaque and is protected by the newly sealed history archive without being promoted to valid data.
    static func rekeyRestoredHistory(
        _ sealedData: Data,
        from oldVaultKey: SymmetricKey,
        to newVaultKey: SymmetricKey
    ) throws -> Data {
        let history = try openRestoredHistory(sealedData, vaultKey: oldVaultKey)
        let oldRowKey = RowSyncKey(raw: oldVaultKey.withUnsafeBytes { Data($0) })
        let newRowKey = RowSyncKey(raw: newVaultKey.withUnsafeBytes { Data($0) })
        let attachments = try history.attachmentVersions.map { attachment -> HistoricalAttachment in
            switch (attachment.dekWrapped, attachment.cipher) {
            case let (.some(dekWrapped), .some(cipher)):
                guard Int64(cipher.count) == attachment.bytes,
                      sha256(cipher) == attachment.sha256.lowercased() else {
                    throw BackupPackageError.invalidPackage
                }
                let plaintext = try AttachmentSyncCipher.decrypt(
                    cipher: cipher,
                    dekWrapped: dekWrapped,
                    key: oldRowKey,
                    attachmentID: attachment.attachmentID,
                    contentVersion: attachment.contentVersion)
                let encrypted = try AttachmentSyncCipher.encrypt(
                    data: plaintext,
                    key: newRowKey,
                    attachmentID: attachment.attachmentID,
                    contentVersion: attachment.contentVersion)
                return HistoricalAttachment(
                    attachmentID: attachment.attachmentID,
                    cardID: attachment.cardID,
                    contentVersion: attachment.contentVersion,
                    isCurrent: attachment.isCurrent,
                    sha256: sha256(encrypted.cipher),
                    bytes: Int64(encrypted.cipher.count),
                    dekWrapped: encrypted.dekWrapped,
                    cipher: encrypted.cipher)
            case (nil, nil):
                return attachment
            default:
                throw BackupPackageError.invalidPackage
            }
        }
        let conflicts = try history.conflicts.map { conflict -> HistoricalConflict in
            let candidates = try conflict.candidates.map { candidate -> HistoricalCandidate in
                guard let cipher = candidate.cipher else { return candidate }
                guard !candidate.isDelete,
                      let digest = candidate.sha256,
                      sha256(cipher) == digest.lowercased(),
                      let plaintext = RowSyncCipher.decrypt(
                        cipher,
                        key: oldRowKey,
                        uuid: conflict.itemUUID),
                      DatabaseItemCodec.parse(
                        kind: candidate.kind,
                        uuid: conflict.itemUUID,
                        data: plaintext) != nil else {
                    throw BackupPackageError.invalidPackage
                }
                let encrypted = try RowSyncCipher.encrypt(
                    plaintext,
                    key: newRowKey,
                    uuid: conflict.itemUUID)
                return HistoricalCandidate(
                    candidateID: candidate.candidateID,
                    kind: candidate.kind,
                    isDelete: candidate.isDelete,
                    revision: candidate.revision,
                    modifiedAt: candidate.modifiedAt,
                    committedAt: candidate.committedAt,
                    source: .init(deviceName: candidate.deviceName, platform: candidate.platform),
                    content: .init(sha256: sha256(encrypted), cipher: encrypted))
            }
            return HistoricalConflict(
                conflictID: conflict.conflictID,
                itemUUID: conflict.itemUUID,
                baseRevision: conflict.baseRevision,
                currentRevision: conflict.currentRevision,
                currentDeletedSequence: conflict.currentDeletedSequence,
                generation: conflict.generation,
                createdAt: conflict.createdAt,
                updatedAt: conflict.updatedAt,
                resolvedAt: conflict.resolvedAt,
                expiresAt: conflict.expiresAt,
                selectedCandidateID: conflict.selectedCandidateID,
                candidates: candidates)
        }
        let rekeyedHistory = RestoredHistory(
            sourceCreatedAt: history.sourceCreatedAt,
            attachmentVersions: attachments,
            conflicts: conflicts,
            issues: history.issues,
            quarantinedAttachments: history.quarantinedAttachments,
            quarantinedCandidates: history.quarantinedCandidates)
        return try sealRestoredHistory(rekeyedHistory, vaultKey: newVaultKey)
    }

    private static func sealRestoredHistory(
        manifest: Manifest,
        attachmentData: [AttachmentIdentity: Data],
        candidateData: [String: Data],
        quarantinedAttachmentCiphers: [AttachmentIdentity: Data],
        quarantinedCandidateCiphers: [String: Data],
        issues: [Issue],
        vaultKey: SymmetricKey
    ) throws -> Data {
        let rowKey = RowSyncKey(raw: vaultKey.withUnsafeBytes { Data($0) })
        let attachments = try manifest.attachments.map { descriptor -> HistoricalAttachment in
            let identity = AttachmentIdentity(
                attachmentID: descriptor.attachmentID,
                contentVersion: descriptor.contentVersion)
            let encrypted = try attachmentData[identity].map {
                try AttachmentSyncCipher.encrypt(
                    data: $0,
                    key: rowKey,
                    attachmentID: descriptor.attachmentID,
                    contentVersion: descriptor.contentVersion)
            }
            return HistoricalAttachment(
                attachmentID: descriptor.attachmentID,
                cardID: descriptor.cardID,
                contentVersion: descriptor.contentVersion,
                isCurrent: descriptor.isCurrent,
                sha256: encrypted.map { sha256($0.cipher) } ?? descriptor.sha256,
                bytes: encrypted.map { Int64($0.cipher.count) } ?? descriptor.bytes,
                dekWrapped: encrypted?.dekWrapped,
                cipher: encrypted?.cipher)
        }
        let quarantinedAttachments: [QuarantinedAttachment] = manifest.attachments.compactMap { descriptor in
            let identity = AttachmentIdentity(
                attachmentID: descriptor.attachmentID,
                contentVersion: descriptor.contentVersion)
            guard let cipher = quarantinedAttachmentCiphers[identity] else { return nil }
            return QuarantinedAttachment(
                attachmentID: descriptor.attachmentID,
                cardID: descriptor.cardID,
                contentVersion: descriptor.contentVersion,
                isCurrent: descriptor.isCurrent,
                sha256: sha256(cipher),
                bytes: Int64(cipher.count),
                dekWrapped: descriptor.dekWrapped,
                cipher: cipher)
        }
        let conflicts = try manifest.conflicts.map { conflict -> HistoricalConflict in
            let candidates = try conflict.candidates.map { candidate -> HistoricalCandidate in
                let key = "\(conflict.conflictID):\(candidate.candidateID)"
                let encrypted = try candidateData[key].map {
                    try RowSyncCipher.encrypt($0, key: rowKey, uuid: conflict.itemUUID)
                }
                return HistoricalCandidate(
                    candidateID: candidate.candidateID,
                    kind: candidate.kind,
                    isDelete: candidate.isDelete,
                    revision: candidate.revision,
                    modifiedAt: candidate.modifiedAt,
                    committedAt: candidate.committedAt,
                    source: .init(deviceName: candidate.deviceName, platform: candidate.platform),
                    content: .init(sha256: encrypted.map { sha256($0) }, cipher: encrypted))
            }
            return HistoricalConflict(
                conflictID: conflict.conflictID,
                itemUUID: conflict.itemUUID,
                baseRevision: conflict.baseRevision,
                currentRevision: conflict.currentRevision,
                currentDeletedSequence: conflict.currentDeletedSequence,
                generation: conflict.generation,
                createdAt: conflict.createdAt,
                updatedAt: conflict.updatedAt,
                resolvedAt: conflict.resolvedAt,
                expiresAt: conflict.expiresAt,
                selectedCandidateID: conflict.selectedCandidateID,
                candidates: candidates)
        }
        let quarantinedCandidates: [QuarantinedCandidate] = manifest.conflicts.flatMap { conflict in
            conflict.candidates.compactMap { candidate in
                let key = "\(conflict.conflictID):\(candidate.candidateID)"
                guard let cipher = quarantinedCandidateCiphers[key] else { return nil }
                return QuarantinedCandidate(
                    conflictID: conflict.conflictID,
                    candidateID: candidate.candidateID,
                    sha256: sha256(cipher),
                    cipher: cipher)
            }
        }
        let history = RestoredHistory(
            sourceCreatedAt: manifest.createdAt,
            attachmentVersions: attachments,
            conflicts: conflicts,
            issues: issues,
            quarantinedAttachments: quarantinedAttachments,
            quarantinedCandidates: quarantinedCandidates)
        return try sealRestoredHistory(history, vaultKey: vaultKey)
    }

    private static func sealRestoredHistory(
        _ history: RestoredHistory,
        vaultKey: SymmetricKey
    ) throws -> Data {
        let plaintext = try JSONEncoder().encode(history)
        let sealed = try AES.GCM.seal(plaintext, using: vaultKey, authenticating: historyAAD)
        guard let combined = sealed.combined else { throw BackupPackageError.encryptionFailed }
        return combined
    }

    private static func loadVerifiedPackage(
        at url: URL,
        sourcePassword: String
    ) throws -> VerifiedPackage {
        let isDirectory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        guard !isDirectory else {
            return try loadVerifiedDirectory(at: url, sourcePassword: sourcePassword)
        }

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("upw-backup-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try PortableBackupArchive.extractArchive(at: url, to: temporary)
        return try loadVerifiedDirectory(at: temporary, sourcePassword: sourcePassword)
    }

    private static func loadVerifiedDirectory(
        at url: URL,
        sourcePassword: String
    ) throws -> VerifiedPackage {
        guard hasValidContents(at: url) else { throw BackupPackageError.invalidPackage }
        let info = try readInfo(at: url)
        let bodyURL = url.appendingPathComponent(databaseFileName)
        let envelopeURL = url.appendingPathComponent(envelopeFileName)
        let manifestURL = url.appendingPathComponent(manifestFileName)
        let body = try Data(contentsOf: bodyURL)
        let envelope = try Data(contentsOf: envelopeURL)
        let sealedManifest = try Data(contentsOf: manifestURL)
        let sourceKey = try DatabaseCipher.unwrapVaultKey(envelope, password: sourcePassword)
        let bodyDigest = Data(SHA256.hash(data: body))
        let envelopeDigest = Data(SHA256.hash(data: envelope))
        let manifestPlaintext: Data
        do {
            let box = try AES.GCM.SealedBox(combined: sealedManifest)
            manifestPlaintext = try AES.GCM.open(
                box,
                using: sourceKey,
                authenticating: manifestAAD)
        } catch {
            throw BackupPackageError.invalidPackage
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestPlaintext)
        let expectedCandidateCount = manifest.conflicts.reduce(0) { $0 + $1.candidates.count }
        guard manifest.version == formatVersion,
              manifest.createdAt == info.createdAt,
              manifest.bodyDigest == bodyDigest,
              manifest.envelopeDigest == envelopeDigest,
              info.isComplete == manifest.issues.isEmpty,
              info.attachmentVersionCount == manifest.attachments.count,
              info.conflictCount == manifest.conflicts.count,
              info.conflictCandidateCount == expectedCandidateCount,
              info.issueCount == manifest.issues.count else {
            throw BackupPackageError.invalidPackage
        }

        let plaintext = try DatabaseCipher.decryptBody(body, vaultKey: sourceKey)
        let database = try PasswordDatabase.parse(plaintext)
        let rowKey = RowSyncKey(raw: sourceKey.withUnsafeBytes { Data($0) })
        var issues = manifest.issues
        var payloadDigests: [String: String] = [:]
        var attachmentData: [AttachmentIdentity: Data] = [:]
        var quarantinedAttachmentCiphers: [AttachmentIdentity: Data] = [:]
        var candidateData: [String: Data] = [:]
        var quarantinedCandidateCiphers: [String: Data] = [:]
        for attachment in manifest.attachments {
            let expectedName = attachmentFilename(
                attachmentID: attachment.attachmentID,
                contentVersion: attachment.contentVersion)
            let identity = AttachmentIdentity(
                attachmentID: attachment.attachmentID,
                contentVersion: attachment.contentVersion)
            let fileURL = url.appendingPathComponent("Attachments", isDirectory: true)
                .appendingPathComponent(expectedName)
            var rawCipher: Data?
            do {
                guard attachment.fileName == expectedName else {
                    throw BackupPackageError.invalidPackage
                }
                let cipher = try Data(contentsOf: fileURL)
                rawCipher = cipher
                let digest = sha256(cipher)
                payloadDigests["attachment:\(expectedName)"] = digest
                guard Int64(cipher.count) == attachment.bytes,
                      digest == attachment.sha256.lowercased() else {
                    throw RelayClient.RelayError.attachmentIntegrityFailure
                }
                attachmentData[identity] = try AttachmentSyncCipher.decrypt(
                    cipher: cipher,
                    dekWrapped: attachment.dekWrapped,
                    key: rowKey,
                    attachmentID: attachment.attachmentID,
                    contentVersion: attachment.contentVersion)
                if attachment.isCurrent,
                   !database.cards.contains(where: { card in
                       card.id == attachment.cardID
                           && (card.images + card.files).contains(where: {
                               $0.id == attachment.attachmentID
                                   && $0.contentVersion == attachment.contentVersion
                           })
                   }) {
                    issues.append(.attachmentVersionUnavailable(
                        attachmentID: attachment.attachmentID,
                        contentVersion: attachment.contentVersion))
                }
            } catch {
                if let rawCipher {
                    quarantinedAttachmentCiphers[identity] = rawCipher
                } else {
                    payloadDigests["attachment:\(expectedName)"] = "unavailable"
                }
                Log.error(
                    "backup",
                    "package attachment validation failed id=\(attachment.attachmentID.uuidString) version=\(attachment.contentVersion.uuidString): \(error)")
                issues.append(.attachmentVersionUnavailable(
                    attachmentID: attachment.attachmentID,
                    contentVersion: attachment.contentVersion))
            }
        }

        let capturedAttachments = Set(attachmentData.keys)
        for card in database.cards {
            for attachment in card.images + card.files where attachment.data == nil {
                guard attachment.hasPersistentID, attachment.hasPersistentContentVersion else {
                    issues.append(.attachmentIdentityUnavailable(cardID: card.id))
                    continue
                }
                let identity = AttachmentIdentity(
                    attachmentID: attachment.id,
                    contentVersion: attachment.contentVersion)
                if !capturedAttachments.contains(identity) {
                    issues.append(.attachmentVersionUnavailable(
                        attachmentID: attachment.id,
                        contentVersion: attachment.contentVersion))
                }
            }
        }

        for conflict in manifest.conflicts {
            for candidate in conflict.candidates {
                guard let fileName = candidate.fileName else { continue }
                let expectedName = "\(candidate.candidateID).cipher"
                let fileURL = url.appendingPathComponent("Conflicts", isDirectory: true)
                    .appendingPathComponent(conflict.conflictID, isDirectory: true)
                    .appendingPathComponent(expectedName)
                let payloadKey = "candidate:\(conflict.conflictID):\(fileName)"
                let candidateKey = "\(conflict.conflictID):\(candidate.candidateID)"
                var rawCipher: Data?
                do {
                    guard fileName == expectedName,
                          let declaredDigest = candidate.sha256 else {
                        throw BackupPackageError.invalidPackage
                    }
                    let cipher = try Data(contentsOf: fileURL)
                    rawCipher = cipher
                    let digest = sha256(cipher)
                    payloadDigests[payloadKey] = digest
                    guard digest == declaredDigest.lowercased(),
                          let itemData = RowSyncCipher.decrypt(
                            cipher,
                            key: rowKey,
                            uuid: conflict.itemUUID),
                          DatabaseItemCodec.parse(
                            kind: candidate.kind,
                            uuid: conflict.itemUUID,
                            data: itemData) != nil else {
                        throw BackupPackageError.invalidPackage
                    }
                    candidateData[candidateKey] = itemData
                } catch {
                    if let rawCipher {
                        quarantinedCandidateCiphers[candidateKey] = rawCipher
                    } else {
                        payloadDigests[payloadKey] = "unavailable"
                    }
                    Log.error(
                        "backup",
                        "package conflict candidate validation failed conflict=\(conflict.conflictID) candidate=\(candidate.candidateID): \(error)")
                    issues.append(.conflictCandidateUnavailable(
                        conflictID: conflict.conflictID,
                        candidateID: candidate.candidateID))
                }
            }
        }

        let uniqueIssues = Array(Set(issues)).sorted { issueSortKey($0) < issueSortKey($1) }
        let verificationToken = packageVerificationToken(
            bodyDigest: bodyDigest,
            envelopeDigest: envelopeDigest,
            manifestDigest: Data(SHA256.hash(data: sealedManifest)),
            payloadDigests: payloadDigests)
        let assessment = Assessment(
            isComplete: uniqueIssues.isEmpty && info.isComplete,
            cardCount: database.cards.count,
            attachmentVersionCount: manifest.attachments.count,
            conflictCount: manifest.conflicts.count,
            conflictCandidateCount: expectedCandidateCount,
            issues: uniqueIssues,
            verificationToken: verificationToken)
        return VerifiedPackage(
            database: database,
            manifest: manifest,
            attachmentData: attachmentData,
            quarantinedAttachmentCiphers: quarantinedAttachmentCiphers,
            candidateData: candidateData,
            quarantinedCandidateCiphers: quarantinedCandidateCiphers,
            assessment: assessment)
    }

    private static func packageVerificationToken(
        bodyDigest: Data,
        envelopeDigest: Data,
        manifestDigest: Data,
        payloadDigests: [String: String]
    ) -> String {
        struct Fingerprint: Encodable {
            let bodyDigest: Data
            let envelopeDigest: Data
            let manifestDigest: Data
            let payloadDigests: [String: String]
        }
        let fingerprint = Fingerprint(
            bodyDigest: bodyDigest,
            envelopeDigest: envelopeDigest,
            manifestDigest: manifestDigest,
            payloadDigests: payloadDigests)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(fingerprint) else { return "" }
        return sha256(data)
    }

    static func hasRecognizedHeader(at url: URL) -> Bool {
        url.pathExtension == fileExtension && hasValidContents(at: url)
    }

    static func hasValidContents(at url: URL) -> Bool {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let requiredFiles = [infoFileName, manifestFileName, databaseFileName, envelopeFileName]
        let availableFiles: Set<String>
        if isDirectory {
            availableFiles = Set(requiredFiles.filter {
                FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path)
            })
        } else {
            guard let entries = try? PortableBackupArchive.filePaths(in: url) else { return false }
            availableFiles = Set(entries.keys)
        }
        guard Set(requiredFiles).isSubset(of: availableFiles),
              let info = try? readInfo(at: url) else {
            return false
        }
        return info.version == formatVersion
    }

    private static func captureAttachments(
        _ versions: [RelayClient.AttachmentVersionMetadata],
        client: RelayClient,
        token: String,
        vaultID: String,
        key: RowSyncKey,
        destination: URL,
        issues: inout [Issue]
    ) async throws -> [AttachmentDescriptor] {
        var descriptors: [AttachmentDescriptor] = []
        for version in versions {
            try Task.checkCancellation()
            let contentVersion = version.contentVersion ?? legacyContentVersion
            let filename = attachmentFilename(
                attachmentID: version.attachmentID,
                contentVersion: contentVersion)
            let fileURL = destination.appendingPathComponent(filename)
            do {
                let downloaded: EncryptedAttachment
                if let versionID = version.contentVersion {
                    downloaded = try await client.getAttachment(
                        token: token,
                        vaultId: vaultID,
                        attachUuid: version.attachmentID,
                        contentVersion: versionID)
                } else {
                    let cipher = try await client.getAttachment(
                        token: token,
                        vaultId: vaultID,
                        attachUuid: version.attachmentID)
                    downloaded = EncryptedAttachment(cipher: cipher, dekWrapped: version.dekWrapped)
                }
                guard downloaded.dekWrapped == version.dekWrapped,
                      Int64(downloaded.cipher.count) == version.bytes,
                      Self.sha256(downloaded.cipher) == version.sha256.lowercased() else {
                    throw RelayClient.RelayError.attachmentIntegrityFailure
                }
                try downloaded.cipher.write(to: fileURL, options: .atomic)
                let descriptor = AttachmentDescriptor(
                    attachmentID: version.attachmentID,
                    cardID: version.cardID,
                    contentVersion: contentVersion,
                    isLegacyVersion: version.contentVersion == nil,
                    dekWrapped: version.dekWrapped,
                    sha256: version.sha256,
                    bytes: version.bytes,
                    isCurrent: version.isCurrent,
                    fileName: filename)
                do {
                    _ = try AttachmentSyncCipher.decrypt(
                        cipher: downloaded.cipher,
                        dekWrapped: downloaded.dekWrapped,
                        key: key,
                        attachmentID: version.attachmentID,
                        contentVersion: contentVersion)
                } catch {
                    Log.error(
                        "backup",
                        "attachment version quarantined after authentication failure attachment=\(version.attachmentID.uuidString) version=\(contentVersion.uuidString): \(error)")
                    issues.append(.attachmentVersionUnavailable(
                        attachmentID: version.attachmentID,
                        contentVersion: contentVersion))
                    descriptors.append(descriptor)
                    continue
                }
                descriptors.append(descriptor)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Log.error(
                    "backup",
                    "attachment version capture failed attachment=\(version.attachmentID.uuidString) version=\(contentVersion.uuidString): \(error)")
                issues.append(.attachmentVersionUnavailable(
                    attachmentID: version.attachmentID,
                    contentVersion: contentVersion))
            }
        }
        return descriptors
    }

    private static func captureConflicts(
        _ source: [ConflictCaptureSource],
        key: RowSyncKey,
        destination: URL,
        issues: inout [Issue]
    ) throws -> [ConflictDescriptor] {
        var conflicts: [ConflictDescriptor] = []
        for conflict in source {
            try Task.checkCancellation()
            let candidateDirectory = destination.appendingPathComponent(conflict.conflictID, isDirectory: true)
            try FileManager.default.createDirectory(at: candidateDirectory, withIntermediateDirectories: true)
            var candidates: [CandidateDescriptor] = []
            for candidate in conflict.candidates {
                try Task.checkCancellation()
                var fileName: String?
                if let bodyB64 = candidate.bodyB64 {
                    guard let cipher = Data(base64Encoded: bodyB64) else {
                        issues.append(.conflictCandidateUnavailable(
                            conflictID: conflict.conflictID,
                            candidateID: candidate.candidateID))
                        continue
                    }
                    let candidateFileName = "\(candidate.candidateID).cipher"
                    try cipher.write(
                        to: candidateDirectory.appendingPathComponent(candidateFileName),
                        options: .atomic)
                    fileName = candidateFileName
                    let parsed: DatabaseItem? = candidate.sha256 == Self.sha256(cipher)
                        ? RowSyncCipher.decrypt(cipher, key: key, uuid: conflict.itemUUID).flatMap {
                            DatabaseItemCodec.parse(
                                kind: candidate.kind,
                                uuid: conflict.itemUUID,
                                data: $0)
                        }
                        : nil
                    if parsed == nil {
                        Log.error(
                            "backup",
                            "conflict candidate capture rejected conflict=\(conflict.conflictID) candidate=\(candidate.candidateID): authentication or item parsing failed")
                        issues.append(.conflictCandidateUnavailable(
                            conflictID: conflict.conflictID,
                            candidateID: candidate.candidateID))
                    }
                }
                candidates.append(CandidateDescriptor(
                    candidateID: candidate.candidateID,
                    kind: candidate.kind,
                    isDelete: candidate.isDelete,
                    revision: candidate.revision,
                    modifiedAt: candidate.modifiedAt,
                    committedAt: candidate.committedAt,
                    deviceName: candidate.deviceName,
                    platform: candidate.platform,
                    sha256: candidate.sha256,
                    fileName: fileName))
            }
            conflicts.append(ConflictDescriptor(
                conflictID: conflict.conflictID,
                itemUUID: conflict.itemUUID,
                baseRevision: conflict.baseRevision,
                currentRevision: conflict.currentRevision,
                currentDeletedSequence: conflict.currentDeletedSequence,
                generation: conflict.generation,
                createdAt: conflict.createdAt,
                updatedAt: conflict.updatedAt,
                resolvedAt: conflict.resolvedAt,
                expiresAt: conflict.expiresAt,
                selectedCandidateID: conflict.selectedCandidateID,
                candidates: candidates))
        }
        return conflicts
    }

    /// Converts locally isolated candidates into backup sources when cloud retention has expired.
    private static func localQuarantinedConflictSources(
        _ state: RowSyncState,
        key: RowSyncKey,
        excluding knownIDs: Set<String>
    ) throws -> [ConflictCaptureSource] {
        var sources: [ConflictCaptureSource] = []
        for quarantined in state.quarantinedCandidates.values {
            guard !knownIDs.contains(quarantined.id) else { continue }
            let candidate = try RowSyncCipher.openQuarantineCandidate(quarantined, key: key)
            sources.append(ConflictCaptureSource(
                conflictID: quarantined.conflictID,
                itemUUID: quarantined.itemUUID,
                baseRevision: candidate.revision,
                currentRevision: candidate.revision,
                currentDeletedSequence: 0,
                generation: 0,
                createdAt: quarantined.capturedAt,
                updatedAt: quarantined.capturedAt,
                resolvedAt: nil,
                expiresAt: nil,
                selectedCandidateID: nil,
                candidates: [candidate]))
        }
        return sources
    }

    private static func appendMissingReferenceIssues(
        for database: PasswordDatabase,
        attachments: [AttachmentDescriptor],
        inventory: BackupSnapshotInventory,
        issues: inout [Issue]
    ) {
        let captured = Set(attachments.map {
            AttachmentIdentity(attachmentID: $0.attachmentID, contentVersion: $0.contentVersion)
        })
        let metadata = Dictionary(
            inventory.attachmentVersions.map {
                (AttachmentIdentity(
                    attachmentID: $0.attachmentID,
                    contentVersion: $0.contentVersion ?? legacyContentVersion), $0)
            },
            uniquingKeysWith: { first, _ in first })
        for card in database.cards {
            for attachment in card.images + card.files where attachment.data == nil {
                guard attachment.hasPersistentID, attachment.hasPersistentContentVersion else {
                    issues.append(.attachmentIdentityUnavailable(cardID: card.id))
                    continue
                }
                let identity = AttachmentIdentity(
                    attachmentID: attachment.id,
                    contentVersion: attachment.contentVersion)
                guard let version = metadata[identity], version.cardID == card.id,
                      captured.contains(identity) else {
                    issues.append(.attachmentVersionUnavailable(
                        attachmentID: attachment.id,
                        contentVersion: attachment.contentVersion))
                    continue
                }
            }
        }
    }

    private static func attachmentFilename(attachmentID: UUID, contentVersion: UUID) -> String {
        "\(attachmentID.uuidString.lowercased())-\(contentVersion.uuidString.lowercased()).cipher"
    }

    private static func sealManifest(_ manifest: Manifest, key: SymmetricKey) throws -> Data {
        let encoded = try JSONEncoder().encode(manifest)
        let sealed = try AES.GCM.seal(encoded, using: key, authenticating: manifestAAD)
        guard let combined = sealed.combined else { throw BackupPackageError.encryptionFailed }
        return combined
    }

    private static func issueSortKey(_ issue: Issue) -> String {
        (try? String(data: JSONEncoder().encode(issue), encoding: .utf8)) ?? ""
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct AttachmentIdentity: Hashable {
        let attachmentID: UUID
        let contentVersion: UUID
    }

    private struct VerifiedPackage {
        let database: PasswordDatabase
        let manifest: Manifest
        let attachmentData: [AttachmentIdentity: Data]
        let quarantinedAttachmentCiphers: [AttachmentIdentity: Data]
        let candidateData: [String: Data]
        let quarantinedCandidateCiphers: [String: Data]
        let assessment: Assessment
    }

    private struct Manifest: Codable {
        let version: Int
        let createdAt: Date
        let bodyDigest: Data
        let envelopeDigest: Data
        let headSequence: Int?
        let attachments: [AttachmentDescriptor]
        let conflicts: [ConflictDescriptor]
        let issues: [Issue]
    }

    private struct AttachmentDescriptor: Codable {
        let attachmentID: UUID
        let cardID: UUID
        let contentVersion: UUID
        let isLegacyVersion: Bool
        let dekWrapped: Data
        let sha256: String
        let bytes: Int64
        let isCurrent: Bool
        let fileName: String
    }

    private struct ConflictDescriptor: Codable {
        let conflictID: String
        let itemUUID: UUID
        let baseRevision: UInt64
        let currentRevision: UInt64
        let currentDeletedSequence: Int
        let generation: UInt64
        let createdAt: Date
        let updatedAt: Date
        let resolvedAt: Date?
        let expiresAt: Date?
        let selectedCandidateID: String?
        let candidates: [CandidateDescriptor]
    }

    private struct ConflictCaptureSource {
        let conflictID: String
        let itemUUID: UUID
        let baseRevision: UInt64
        let currentRevision: UInt64
        let currentDeletedSequence: Int
        let generation: UInt64
        let createdAt: Date
        let updatedAt: Date
        let resolvedAt: Date?
        let expiresAt: Date?
        let selectedCandidateID: String?
        let candidates: [RelayClient.ConflictCandidate]
    }

    private struct CandidateDescriptor: Codable {
        let candidateID: String
        let kind: UInt8
        let isDelete: Bool
        let revision: UInt64
        let modifiedAt: Date
        let committedAt: Date
        let deviceName: String
        let platform: String
        let sha256: String?
        let fileName: String?
    }
}

/// Errors that prevent publishing a trustworthy self-contained backup package.
public enum BackupPackageError: Error, LocalizedError, Equatable {
    case unsupportedFormat
    case encryptionFailed
    case invalidPackage
    case incompleteRestoreRequiresConfirmation
    case packageChanged

    /// User-safe explanation that does not reveal credential data.
    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return L10n.t("backup_package_unsupported", fallback: "This backup format is not supported.")
        case .encryptionFailed:
            return L10n.t("backup_package_encryption_failed", fallback: "The backup manifest could not be protected.")
        case .invalidPackage:
            return L10n.t("backup_package_invalid", fallback: "The backup package is incomplete or damaged.")
        case .incompleteRestoreRequiresConfirmation:
            return L10n.t(
                "backup_package_incomplete_confirmation_required",
                fallback: "Review the incomplete backup contents before restoring it.")
        case .packageChanged:
            return L10n.t(
                "backup_package_changed",
                fallback: "The backup changed after it was reviewed. Review it again before restoring.")
        }
    }
}
