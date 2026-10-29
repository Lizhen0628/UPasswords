import CryptoKit
import Foundation

import UPasswordsCore
import UPasswordsPersistence

extension Vault {
    /// Lists encrypted conflicts for the currently unlocked, bound vault.
    func syncConflicts() async throws -> [RelayClient.ConflictRecord] {
        guard !locked, let vaultKey else {
            throw SyncError.notConfigured
        }
        guard let binding = relay.binding(database: databaseName),
              let token = relay.token(database: databaseName) else {
            return []
        }
        let name = databaseName
        let sessionID = syncSessionID
        let key = vaultKey
        let conflicts = try await relayClient.listConflicts(token: token, vaultId: binding.vaultId)
        try validateSyncSession(name: name, key: key, sessionID: sessionID)
        return conflicts
    }

    /// Preserves an unreadable encrypted candidate locally without changing its conflict.
    func quarantineUnreadableSyncConflictCandidate(
        _ candidate: RelayClient.ConflictCandidate,
        conflict: RelayClient.ConflictRecord
    ) {
        guard !locked, let vaultKey else { return }
        let key = RowSyncKey(raw: vaultKey.withUnsafeBytes { Data($0) })
        guard let reason = Self.candidateReason(candidate, conflict: conflict, key: key) else { return }
        guard let quarantined = try? RowSyncCipher.quarantineCandidate(
            candidate,
            conflict: conflict,
            reason: reason,
            key: key) else {
            Log.error("sync", "ios candidate quarantine failed id=\(candidate.candidateID)")
            return
        }
        var state = rowSync
        if state.quarantinedCandidates[quarantined.id] == quarantined { return }
        state.quarantinedCandidates[quarantined.id] = quarantined
        do {
            try commitSyncSnapshot(database, name: databaseName, vaultKey: vaultKey, state: state)
            rowSync = state
            Log.warn("sync", "ios candidate quarantined id=\(quarantined.id)")
        } catch {
            Log.error("sync", "ios candidate quarantine commit failed id=\(quarantined.id)")
        }
    }

    /// Refreshes isolated candidates, discarding entries only after the server copy is gone or readable.
    func retryQuarantinedSyncConflictCandidates() async {
        guard !locked, !syncInFlight, !rowSync.quarantinedCandidates.isEmpty else { return }
        let name = databaseName
        let sessionID = syncSessionID
        let keyData = vaultKey?.withUnsafeBytes { Data($0) }
        guard let vaultKey, let keyData else { return }
        let key = RowSyncKey(raw: keyData)
        syncInFlight = true
        syncState = .syncing
        defer {
            syncInFlight = false
            if syncSessionID == sessionID, syncState == .syncing { syncState = .idle }
        }
        do {
            let conflicts = try await syncConflicts()
            try validateSyncSession(name: name, key: vaultKey, sessionID: sessionID)
            let active = conflicts.reduce(into: [String: RelayClient.ConflictCandidate]()) {
                for candidate in $1.candidates {
                    $0["\($1.conflictID):\(candidate.candidateID)"] = candidate
                }
            }
            var state = rowSync
            var recovered = 0
            for quarantined in state.quarantinedCandidates.values {
                guard let current = active[quarantined.id] else {
                    state.quarantinedCandidates.removeValue(forKey: quarantined.id)
                    recovered += 1
                    continue
                }
                guard let conflict = conflicts.first(where: { $0.conflictID == quarantined.conflictID }) else {
                    continue
                }
                if Self.candidateReason(current, conflict: conflict, key: key) == nil {
                    state.quarantinedCandidates.removeValue(forKey: quarantined.id)
                    recovered += 1
                } else {
                    state.quarantinedCandidates[quarantined.id] = try RowSyncCipher.quarantineCandidate(
                        current,
                        conflict: conflict,
                        reason: quarantined.reason,
                        key: key)
                }
            }
            try validateSyncSession(name: name, key: vaultKey, sessionID: sessionID)
            try commitSyncSnapshot(database, name: name, vaultKey: vaultKey, state: state)
            rowSync = state
            showToast(String(format: L10n.t("sync_candidate_quarantine_retry_fmt"), recovered))
            Log.info("sync", "ios candidate quarantine retry committed recovered=\(recovered)")
        } catch {
            if syncSessionID == sessionID, databaseName == name {
                syncState = .failed(error.localizedDescription)
            }
            Log.error("sync", "ios candidate quarantine retry failed: \(error)")
            showToast(error.localizedDescription)
        }
    }

    /// Saves a readable conflict card as an independent card without resolving its source conflict.
    func saveSyncConflictCandidateAsNewItem(
        _ conflict: RelayClient.ConflictRecord,
        candidateID: String
    ) async throws {
        guard !locked, let vaultKey else {
            throw CrossDatabaseCardImporter.ImportError.destinationUnavailable
        }
        guard !syncInFlight else {
            throw CrossDatabaseCardImporter.ImportError.destinationSyncing
        }
        let name = databaseName
        let sessionID = syncSessionID
        let operationID = UUID()
        conflictCandidateCopyOperationID = operationID
        syncInFlight = true
        syncState = .syncing
        let snapshot = database
        let snapshotData = snapshot.xmlData()
        let state = rowSync
        let keyData = vaultKey.withUnsafeBytes { Data($0) }
        let copyGuard = ConflictCandidateCopyGuard(
            operationID: operationID,
            sessionID: sessionID,
            vaultKey: keyData,
            databaseSnapshot: snapshotData,
            rowSync: state,
            conflict: conflict)
        defer {
            if conflictCandidateCopyOperationID == operationID {
                conflictCandidateCopyOperationID = nil
                syncInFlight = false
                if syncSessionID == sessionID, syncState == .syncing {
                    syncState = .idle
                }
            }
        }
        let validateCopy: (RelayClient.ConflictRecord?) throws -> Void = { [weak self] currentConflict in
            guard let self, let currentKey = self.vaultKey else { throw CancellationError() }
            try self.validateSyncSession(name: name, key: vaultKey, sessionID: sessionID)
            try copyGuard.validate(
                operationID: self.conflictCandidateCopyOperationID,
                sessionID: self.syncSessionID,
                vaultKey: currentKey.withUnsafeBytes { Data($0) },
                databaseSnapshot: self.database.xmlData(),
                rowSync: self.rowSync,
                isSyncing: self.syncInFlight && self.syncState == .syncing,
                conflict: currentConflict)
        }
        let latestConflicts = try await syncConflicts()
        let latest = latestConflicts.first(where: { $0.conflictID == conflict.conflictID })
        try validateCopy(latest)
        guard let latest,
              let candidate = latest.candidates.first(where: { $0.candidateID == candidateID }),
              let decoded = Self.decode(candidate, conflict: latest, key: RowSyncKey(
                raw: vaultKey.withUnsafeBytes { Data($0) })) else {
            throw RowSyncSafetyError.unreadableItem
        }
        guard case .card = decoded,
              let body = candidate.bodyB64.flatMap({ Data(base64Encoded: $0) }) else {
            throw CrossDatabaseCardImporter.ImportError.selectionBlocked
        }
        guard let token = relay.token(database: name),
              let binding = relay.binding(database: name) else {
            throw CrossDatabaseCardImporter.ImportError.destinationUnavailable
        }
        let item = try await Self.materializeAttachments(
            in: decoded,
            token: token,
            vaultId: binding.vaultId,
            vaultKey: vaultKey,
            client: relayClient,
            validate: { [weak self] in
                guard self != nil else { throw CancellationError() }
                try validateCopy(latest)
            })
        let confirmedConflicts = try await syncConflicts()
        let confirmed = confirmedConflicts.first(where: { $0.conflictID == conflict.conflictID })
        try validateCopy(confirmed)
        guard case .card(let card) = item else { throw RowSyncSafetyError.invalidResponse }

        var sourceDatabase = PasswordDatabase()
        sourceDatabase.cards = [card]
        sourceDatabase.labels = snapshot.labels.filter { card.labelIds.contains($0.id) }
        let source = CrossDatabaseCardImporter.SourceSnapshot(
            database: sourceDatabase,
            fingerprint: Data(SHA256.hash(data: body)))
        let plan = try CrossDatabaseCardImporter.makePlan(
            from: source,
            into: snapshot,
            syncState: state,
            selecting: [card.id])
        guard let newID = plan.importedCardIDs.first else {
            showToast(L10n.t("ios_sync_conflict_copy_already_saved"))
            return
        }

        try commitSyncSnapshot(plan.database, name: name, vaultKey: vaultKey, state: plan.syncState)
        database = plan.database
        rowSync = plan.syncState
        showToast(L10n.t("ios_sync_conflict_copy_saved"))
        Log.info("sync", "ios conflict candidate copied as new card source=\(conflict.itemUUID.uuidString.prefix(8)) new=\(newID.uuidString.prefix(8))")
        if relay.binding(database: name) != nil {
            Task { [weak self] in await self?.sync(auto: true) }
        }
    }

    private static func materializeAttachments(
        in item: DatabaseItem,
        token: String,
        vaultId: String,
        vaultKey: SymmetricKey,
        client: RelayClient,
        validate: () async throws -> Void
    ) async throws -> DatabaseItem {
        guard case .card(var card) = item else { return item }
        let rowKey = RowSyncKey(raw: vaultKey.withUnsafeBytes { Data($0) })
        for index in card.images.indices where card.images[index].data == nil {
            let attachment = card.images[index]
            let encrypted = try await client.getAttachment(
                token: token,
                vaultId: vaultId,
                attachUuid: attachment.id,
                contentVersion: attachment.contentVersion)
            try await validate()
            let data = try AttachmentSyncCipher.decrypt(
                cipher: encrypted.cipher,
                dekWrapped: encrypted.dekWrapped,
                key: rowKey,
                attachmentID: attachment.id,
                contentVersion: attachment.contentVersion)
            guard card.images[index].installDownloadedContent(data, for: attachment.contentVersion) else {
                throw RowSyncSafetyError.invalidResponse
            }
        }
        for index in card.files.indices where card.files[index].data == nil {
            let attachment = card.files[index]
            let encrypted = try await client.getAttachment(
                token: token,
                vaultId: vaultId,
                attachUuid: attachment.id,
                contentVersion: attachment.contentVersion)
            try await validate()
            let data = try AttachmentSyncCipher.decrypt(
                cipher: encrypted.cipher,
                dekWrapped: encrypted.dekWrapped,
                key: rowKey,
                attachmentID: attachment.id,
                contentVersion: attachment.contentVersion)
            guard card.files[index].installDownloadedContent(data, for: attachment.contentVersion) else {
                throw RowSyncSafetyError.invalidResponse
            }
        }
        return .card(card)
    }

    /// Resolves one reviewed candidate, then pulls the server's atomic resolution event.
    func resolveSyncConflict(
        _ conflict: RelayClient.ConflictRecord,
        candidateID: String,
        fieldSelections: [UUID: String]? = nil,
        notesCandidateID: String? = nil
    ) async throws {
        guard !locked, let vaultKey else {
            throw SyncError.notConfigured
        }
        guard !syncInFlight,
              let binding = relay.binding(database: databaseName),
              let token = relay.token(database: databaseName),
              let candidate = conflict.candidates.first(where: { $0.candidateID == candidateID }) else {
            throw RowSyncSafetyError.invalidResponse
        }

        let name = databaseName
        let sessionID = syncSessionID
        let rowKey = RowSyncKey(raw: vaultKey.withUnsafeBytes { Data($0) })
        var restoreUUID: UUID?
        var restoredBody: Data?
        var composedBody: Data?
        var composedModifiedMs: Int64?
        var selectedItem: DatabaseItem?
        if let fieldSelections {
            guard conflict.currentDeletedSequence == 0, !candidate.isDelete else {
                throw RowSyncSafetyError.invalidResponse
            }
            let composerCandidates = conflict.candidates.compactMap { source -> ConflictComposer.Candidate? in
                guard !source.isDelete,
                      let item = Self.decode(source, conflict: conflict, key: rowKey) else {
                    return nil
                }
                return ConflictComposer.Candidate(candidateID: source.candidateID, item: item)
            }
            guard composerCandidates.count == conflict.candidates.count,
                  let mergedItem = ConflictComposer.compose(
                    baseCandidateID: candidateID,
                    candidates: composerCandidates,
                    fieldSelections: fieldSelections,
                    notesCandidateID: notesCandidateID),
                  mergedItem.uuid == conflict.itemUUID,
                  mergedItem.syncKind == candidate.kind,
                  let modifiedMs = Int64(exactly: mergedItem.modifiedMs),
                  (0...253_402_300_799_999).contains(modifiedMs) else {
                throw RowSyncSafetyError.invalidResponse
            }
            selectedItem = mergedItem
            let labelNames = Dictionary(uniqueKeysWithValues: database.labels.map { ($0.id, $0.name) })
            let plaintext = DatabaseItemCodec.xmlData(mergedItem, labelNames: labelNames)
            composedBody = try RowSyncCipher.encrypt(plaintext, key: rowKey, uuid: conflict.itemUUID)
            composedModifiedMs = modifiedMs
        } else if !candidate.isDelete {
            guard let item = Self.decode(candidate, conflict: conflict, key: rowKey) else {
                throw RowSyncSafetyError.unreadableItem
            }
            selectedItem = item
        }
        let attachmentReferences: [RelayClient.AttachmentReference]
        if let selectedItem {
            attachmentReferences = try Self.attachmentReferences(for: selectedItem)
        } else {
            attachmentReferences = []
        }
        if conflict.currentDeletedSequence > 0 && !candidate.isDelete {
            guard let item = selectedItem else {
                throw RowSyncSafetyError.unreadableItem
            }
            let newUUID = UUID()
            let restoredItem = Self.reidentified(item, as: newUUID)
            let labelNames = Dictionary(uniqueKeysWithValues: database.labels.map { ($0.id, $0.name) })
            let restoredPlaintext = DatabaseItemCodec.xmlData(restoredItem, labelNames: labelNames)
            restoredBody = try RowSyncCipher.encrypt(
                restoredPlaintext,
                key: rowKey,
                uuid: newUUID)
            restoreUUID = newUUID
        }

        _ = try await relayClient.resolveConflict(
            token: token,
            vaultId: binding.vaultId,
            conflict: conflict,
            winningCandidateID: candidateID,
            attachmentReferences: attachmentReferences,
            restoreItemUUID: restoreUUID,
            restoredBody: restoredBody,
            composedBody: composedBody,
            composedModifiedMs: composedModifiedMs)
        Log.info(
            "sync",
            "ios conflict resolution committed for \(conflict.itemUUID.uuidString.prefix(8)) (\(composedBody == nil ? "candidate" : "composed"))")
        try validateSyncSession(name: name, key: vaultKey, sessionID: sessionID)
        guard await sync(auto: true) != nil else {
            Log.warn(
                "sync",
                "ios conflict resolution follow-up sync pending for \(conflict.itemUUID.uuidString.prefix(8))")
            showToast(L10n.t("ios_sync_conflict_resolution_sync_pending"))
            return
        }
    }

    private static func decode(
        _ candidate: RelayClient.ConflictCandidate,
        conflict: RelayClient.ConflictRecord,
        key: RowSyncKey
    ) -> DatabaseItem? {
        guard !candidate.isDelete,
              let bodyB64 = candidate.bodyB64,
              let ciphertext = Data(base64Encoded: bodyB64),
              let plaintext = RowSyncCipher.decrypt(ciphertext, key: key, uuid: conflict.itemUUID) else {
            return nil
        }
        return DatabaseItemCodec.parse(kind: candidate.kind, uuid: conflict.itemUUID, data: plaintext)
    }

    private static func candidateReason(
        _ candidate: RelayClient.ConflictCandidate,
        conflict: RelayClient.ConflictRecord,
        key: RowSyncKey
    ) -> RowSyncQuarantinedCandidate.Reason? {
        guard !candidate.isDelete,
              let bodyB64 = candidate.bodyB64,
              let ciphertext = Data(base64Encoded: bodyB64) else { return nil }
        guard let plaintext = RowSyncCipher.decrypt(
            ciphertext, key: key, uuid: conflict.itemUUID) else {
            return .authenticationFailed
        }
        guard DatabaseItemCodec.parse(
            kind: candidate.kind, uuid: conflict.itemUUID, data: plaintext) != nil else {
            return .unsupportedFormat
        }
        return nil
    }

    private static func attachmentReferences(
        for item: DatabaseItem
    ) throws -> [RelayClient.AttachmentReference] {
        guard case let .card(card) = item else { return [] }
        let attachments = card.images + card.files
        guard attachments.count <= 500,
              attachments.allSatisfy({ $0.hasPersistentID && $0.hasPersistentContentVersion }),
              Set(attachments.map(\.id)).count == attachments.count else {
            throw RowSyncSafetyError.invalidResponse
        }
        return attachments.map {
            RelayClient.AttachmentReference(
                attachmentID: $0.id,
                contentVersion: $0.contentVersion,
                restoreDeleted: true)
        }
    }

    private static func reidentified(_ item: DatabaseItem, as id: UUID) -> DatabaseItem {
        let now = Date().millis
        switch item {
        case .card(var card):
            card.id = id
            card.modified = max(now, card.modified + 1)
            return .card(card)
        case .label(var label):
            label.id = id
            label.timeStamp = max(now, label.timeStamp + 1)
            return .label(label)
        case .userProfile(var profile):
            profile.id = id
            profile.modified = max(now, profile.modified + 1)
            return .userProfile(profile)
        }
    }
}
