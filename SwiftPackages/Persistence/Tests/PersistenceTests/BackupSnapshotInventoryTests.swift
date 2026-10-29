import CryptoKit
import Foundation
import Testing

@testable import UPasswordsPersistence

@Suite("Backup snapshot inventory")
struct BackupSnapshotInventoryTests {
    @Test("Fingerprint ignores API ordering")
    func fingerprintIgnoresResponseOrdering() throws {
        let firstAttachment = attachment(id: UUID())
        let secondAttachment = attachment(id: UUID())
        let firstConflict = conflict(id: String(repeating: "a", count: 32))
        let secondConflict = conflict(id: String(repeating: "b", count: 32))

        let first = try BackupSnapshotInventory(
            headSequence: 5,
            attachmentVersions: [firstAttachment, secondAttachment],
            conflicts: [firstConflict, secondConflict])
        let reordered = try BackupSnapshotInventory(
            headSequence: 5,
            attachmentVersions: [secondAttachment, firstAttachment],
            conflicts: [secondConflict, firstConflict])

        #expect(first.matches(reordered))
        #expect(first.attachmentVersionCount == 2)
        #expect(first.conflictCount == 2)
        #expect(first.conflictCandidateCount == 4)
    }

    @Test("Fingerprint changes when retained attachment metadata changes")
    func fingerprintChangesForAttachmentVersionChanges() throws {
        let id = UUID()
        let original = try BackupSnapshotInventory(
            headSequence: 5,
            attachmentVersions: [attachment(id: id)], conflicts: [])
        let changed = RelayClient.AttachmentVersionMetadata(
            attachmentID: id,
            cardID: UUID(),
            contentVersion: UUID(),
            dekWrapped: Data(repeating: 3, count: 40),
            sha256: String(repeating: "b", count: 64),
            bytes: 21,
            isCurrent: false)
        let later = try BackupSnapshotInventory(
            headSequence: 5,
            attachmentVersions: [changed],
            conflicts: [])

        #expect(!original.matches(later))
    }

    @Test("Fingerprint includes retained conflict history and availability")
    func fingerprintIncludesRetainedConflictHistory() throws {
        let retained = retainedConflict(id: String(repeating: "f", count: 32))
        let complete = try BackupSnapshotInventory(
            headSequence: 5,
            attachmentVersions: [],
            conflicts: [],
            retainedConflicts: [retained])
        let unavailable = try BackupSnapshotInventory(
            headSequence: 5,
            attachmentVersions: [],
            conflicts: [],
            retainedHistoryAvailable: false)
        let changedResolution = RelayClient.RetainedConflictRecord(
            conflictID: retained.conflictID,
            itemUUID: retained.itemUUID,
            baseRevision: retained.baseRevision,
            currentRevision: retained.currentRevision,
            currentDeletedSequence: retained.currentDeletedSequence,
            generation: retained.generation,
            createdAt: retained.createdAt,
            updatedAt: retained.updatedAt,
            resolvedAt: retained.resolvedAt,
            expiresAt: retained.expiresAt,
            selectedCandidateID: retained.candidates[1].candidateID,
            candidates: retained.candidates)
        let changed = try BackupSnapshotInventory(
            headSequence: 5,
            attachmentVersions: [],
            conflicts: [],
            retainedConflicts: [changedResolution])

        #expect(complete.retainedConflictCount == 1)
        #expect(complete.retainedConflictCandidateCount == 2)
        #expect(!complete.matches(unavailable))
        #expect(!complete.matches(changed))
        #expect(unavailable.retainedConflictCount == 0)
        #expect(!unavailable.retainedHistoryAvailable)
    }

    @Test("Fingerprint changes when a conflict generation or candidate set changes")
    func fingerprintChangesForConflictUpdates() throws {
        let original = try BackupSnapshotInventory(
            headSequence: 5,
            attachmentVersions: [],
            conflicts: [conflict(id: String(repeating: "c", count: 32))])
        let base = conflict(id: String(repeating: "c", count: 32))
        let changedGeneration = RelayClient.ConflictRecord(
            conflictID: base.conflictID,
            itemUUID: base.itemUUID,
            baseRevision: base.baseRevision,
            currentRevision: base.currentRevision,
            currentDeletedSequence: base.currentDeletedSequence,
            generation: base.generation + 1,
            createdAt: base.createdAt,
            updatedAt: base.updatedAt,
            candidates: base.candidates)
        let changed = try BackupSnapshotInventory(
            headSequence: 5,
            attachmentVersions: [],
            conflicts: [changedGeneration])
        let advancedHead = try BackupSnapshotInventory(
            headSequence: 6,
            attachmentVersions: [],
            conflicts: [base])
        let originalDelete = base.candidates[1]
        let replacementDelete = RelayClient.ConflictCandidate(
            candidateID: String(repeating: "f", count: 32),
            kind: originalDelete.kind,
            isDelete: originalDelete.isDelete,
            revision: originalDelete.revision,
            modifiedAt: originalDelete.modifiedAt,
            committedAt: originalDelete.committedAt,
            deviceName: originalDelete.deviceName,
            platform: originalDelete.platform,
            bodyB64: originalDelete.bodyB64,
            sha256: originalDelete.sha256)
        let changedCandidates = RelayClient.ConflictRecord(
            conflictID: base.conflictID,
            itemUUID: base.itemUUID,
            baseRevision: base.baseRevision,
            currentRevision: base.currentRevision,
            currentDeletedSequence: base.currentDeletedSequence,
            generation: base.generation,
            createdAt: base.createdAt,
            updatedAt: base.updatedAt,
            candidates: [base.candidates[0], replacementDelete])
        let candidateSetChanged = try BackupSnapshotInventory(
            headSequence: 5,
            attachmentVersions: [],
            conflicts: [changedCandidates])

        #expect(!original.matches(changed))
        #expect(!original.matches(advancedHead))
        #expect(!original.matches(candidateSetChanged))
    }

    @Test("Duplicate attachment versions are rejected")
    func duplicateAttachmentVersionsAreRejected() {
        let version = attachment(id: UUID())

        #expect(throws: RowSyncSafetyError.invalidResponse) {
            try BackupSnapshotInventory(
                headSequence: 0,
                attachmentVersions: [version, version],
                conflicts: [])
        }
    }

    @Test("Candidate ciphertext must match its declared digest")
    func candidateDigestMismatchIsRejected() {
        let original = conflict(id: String(repeating: "c", count: 32))
        let candidate = original.candidates[0]
        let damagedCandidate = RelayClient.ConflictCandidate(
            candidateID: candidate.candidateID,
            kind: candidate.kind,
            isDelete: candidate.isDelete,
            revision: candidate.revision,
            modifiedAt: candidate.modifiedAt,
            committedAt: candidate.committedAt,
            deviceName: candidate.deviceName,
            platform: candidate.platform,
            bodyB64: candidate.bodyB64,
            sha256: String(repeating: "0", count: 64))
        let damagedConflict = RelayClient.ConflictRecord(
            conflictID: original.conflictID,
            itemUUID: original.itemUUID,
            baseRevision: original.baseRevision,
            currentRevision: original.currentRevision,
            currentDeletedSequence: original.currentDeletedSequence,
            generation: original.generation,
            createdAt: original.createdAt,
            updatedAt: original.updatedAt,
            candidates: [damagedCandidate, original.candidates[1]])

        #expect(throws: RowSyncSafetyError.invalidResponse) {
            try BackupSnapshotInventory(
                headSequence: 0,
                attachmentVersions: [],
                conflicts: [damagedConflict])
        }
    }

    @Test("Selected retained candidate must belong to the retained set")
    func selectedRetainedCandidateMustExist() {
        let original = retainedConflict(id: String(repeating: "c", count: 32))
        let invalid = RelayClient.RetainedConflictRecord(
            conflictID: original.conflictID,
            itemUUID: original.itemUUID,
            baseRevision: original.baseRevision,
            currentRevision: original.currentRevision,
            currentDeletedSequence: original.currentDeletedSequence,
            generation: original.generation,
            createdAt: original.createdAt,
            updatedAt: original.updatedAt,
            resolvedAt: original.resolvedAt,
            expiresAt: original.expiresAt,
            selectedCandidateID: String(repeating: "f", count: 32),
            candidates: original.candidates)

        #expect(throws: RowSyncSafetyError.invalidResponse) {
            try BackupSnapshotInventory(
                headSequence: 0,
                attachmentVersions: [],
                conflicts: [],
                retainedConflicts: [invalid])
        }
    }

    private func attachment(id: UUID) -> RelayClient.AttachmentVersionMetadata {
        RelayClient.AttachmentVersionMetadata(
            attachmentID: id,
            cardID: UUID(),
            contentVersion: UUID(),
            dekWrapped: Data(repeating: 1, count: 40),
            sha256: String(repeating: "a", count: 64),
            bytes: 20,
            isCurrent: true)
    }

    private func conflict(id: String) -> RelayClient.ConflictRecord {
        let body = Data("sealed candidate".utf8)
        let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let candidate = RelayClient.ConflictCandidate(
            candidateID: String(repeating: "d", count: 32),
            kind: 1,
            isDelete: false,
            revision: 2,
            modifiedAt: Date(timeIntervalSince1970: 10),
            committedAt: Date(timeIntervalSince1970: 11),
            deviceName: "Device",
            platform: "macos",
            bodyB64: body.base64EncodedString(),
            sha256: digest)
        let deleteCandidate = RelayClient.ConflictCandidate(
            candidateID: String(repeating: "e", count: 32),
            kind: 1,
            isDelete: true,
            revision: 2,
            modifiedAt: Date(timeIntervalSince1970: 12),
            committedAt: Date(timeIntervalSince1970: 13),
            deviceName: "Device",
            platform: "ios",
            bodyB64: nil,
            sha256: nil)
        return RelayClient.ConflictRecord(
            conflictID: id,
            itemUUID: UUID(),
            baseRevision: 1,
            currentRevision: 2,
            currentDeletedSequence: 0,
            generation: 1,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            candidates: [candidate, deleteCandidate])
    }

    private func retainedConflict(id: String) -> RelayClient.RetainedConflictRecord {
        let open = conflict(id: id)
        return RelayClient.RetainedConflictRecord(
            conflictID: open.conflictID,
            itemUUID: open.itemUUID,
            baseRevision: open.baseRevision,
            currentRevision: open.currentRevision,
            currentDeletedSequence: open.currentDeletedSequence,
            generation: open.generation,
            createdAt: open.createdAt,
            updatedAt: open.updatedAt,
            resolvedAt: Date(timeIntervalSince1970: 20),
            expiresAt: Date(timeIntervalSince1970: 50),
            selectedCandidateID: open.candidates[0].candidateID,
            candidates: open.candidates)
    }
}
