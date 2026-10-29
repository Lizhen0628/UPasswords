import XCTest
import UPasswordsCore
@testable import UPasswordsPersistence

/// 备份链路的精细化测试:清理(keep=10)、恢复到新库名、跨恢复读取。
/// DatabaseStore 在拆包时改动过(去 AppKit、public 化),此处钉住其行为。
final class BackupTests: XCTestCase {
    private var tempDir: URL!
    private var store: DatabaseStore!

    override func setUp() {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("upw-backup-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = DatabaseStore(root: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testPruneKeepsTenMostRecent() throws {
        try store.create(name: "Alpha", password: "pw", now: Date(timeIntervalSince1970: 0))
        for i in 0..<13 {
            try store.backup(name: "Alpha", now: Date(timeIntervalSince1970: Double(100 + i)))
        }
        let kept = store.backups(name: "Alpha")
        XCTAssertEqual(kept.count, 10, "keep limit is 10")
        // 最新备份排最前:最后一次(时间戳 112)对应的文件名必须保留
        let newest = DatabaseStore.backupStampFormatter.string(from: Date(timeIntervalSince1970: 112))
        XCTAssertTrue(kept.first?.lastPathComponent == "\(newest).upw", "newest backup must sort first and survive pruning")
        let backupFiles = try FileManager.default.contentsOfDirectory(
            at: store.backupDir(for: "Alpha"),
            includingPropertiesForKeys: nil)
        XCTAssertEqual(backupFiles.filter { $0.pathExtension == "upw" }.count, 10)
        XCTAssertEqual(backupFiles.filter { $0.pathExtension == "upwkey" }.count, 10)
        for backup in kept {
            let envelope = backup.deletingPathExtension().appendingPathExtension("upwkey")
            XCTAssertTrue(FileManager.default.fileExists(atPath: envelope.path))
        }
    }

    func testBackupsInSameSecondKeepDistinctBodyEnvelopePairs() throws {
        try store.create(name: "Alpha", password: "pw")
        let timestamp = Date(timeIntervalSince1970: 100)

        try store.backup(name: "Alpha", now: timestamp)
        try store.backup(name: "Alpha", now: timestamp)

        let backups = store.backups(name: "Alpha")
        XCTAssertEqual(backups.count, 2)
        XCTAssertNotEqual(backups[0].deletingPathExtension(), backups[1].deletingPathExtension())
        for backup in backups {
            let envelope = backup.deletingPathExtension().appendingPathExtension("upwkey")
            XCTAssertTrue(FileManager.default.fileExists(atPath: envelope.path))
        }
    }

    func testBackupRejectsMissingSourceEnvelope() throws {
        try store.create(name: "Alpha", password: "pw")
        try FileManager.default.removeItem(at: store.keyURL(for: "Alpha"))

        XCTAssertThrowsError(try store.backup(name: "Alpha"))
        XCTAssertTrue(store.backups(name: "Alpha").isEmpty)
    }

    func testRestoreBackupCreatesIndependentlyEncryptedCopyWithFreshSyncState() throws {
        try store.create(name: "Alpha", password: "pw", now: Date(timeIntervalSince1970: 0))
        let (loaded, sourceKey) = try store.loadUnlocked(name: "Alpha", password: "pw")
        var db = loaded
        let card = Card(title: "Restored")
        db.cards.append(card)
        try store.save(db, name: "Alpha", vaultKey: sourceKey)
        var sourceState = RowSyncState()
        sourceState.cursor = 42
        sourceState.revisions[card.id] = 3
        try store.saveSyncState(sourceState, for: "Alpha")
        try store.backup(name: "Alpha", now: Date(timeIntervalSince1970: 50))

        let backup = try XCTUnwrap(store.backups(name: "Alpha").first)
        let sourceEnvelope = backup.deletingPathExtension().appendingPathExtension("upwkey")
        let sourceBodyBytes = try Data(contentsOf: backup)
        let sourceEnvelopeBytes = try Data(contentsOf: sourceEnvelope)
        let restoredFile = try store.restoreBackupAsCopy(
            backup: backup,
            name: "Beta",
            sourcePassword: "pw",
            newPassword: "new-pw")
        XCTAssertTrue(store.exists("Beta"))
        XCTAssertFalse(restoredFile.isMain)
        let (restored, restoredKey) = try store.loadUnlocked(name: "Beta", password: "new-pw")
        XCTAssertEqual(restored.card(id: card.id)?.title, "Restored", "restored copy must contain pre-backup edits")
        let sourceKeyBytes = sourceKey.withUnsafeBytes { Data($0) }
        let restoredKeyBytes = restoredKey.withUnsafeBytes { Data($0) }
        XCTAssertNotEqual(
            sourceKeyBytes,
            restoredKeyBytes,
            "restored copies must use an independent vault key")
        XCTAssertThrowsError(try store.load(name: "Beta", password: "pw"))
        XCTAssertEqual(try store.loadSyncState(for: "Beta"), RowSyncState())
        XCTAssertEqual(try store.loadSyncState(for: "Alpha"), sourceState)
        XCTAssertEqual(try store.load(name: "Alpha", password: "pw").card(id: card.id)?.title, "Restored")
        XCTAssertEqual(try Data(contentsOf: backup), sourceBodyBytes)
        XCTAssertEqual(try Data(contentsOf: sourceEnvelope), sourceEnvelopeBytes)
        XCTAssertTrue(store.backups(name: "Beta").isEmpty)
    }

    /// v2 本体恢复必须连同信封备份;缺信封的备份拒绝恢复(恢复了也解不开)。
    func testRestoreRejectsMissingEnvelope() throws {
        try store.create(name: "Alpha", password: "pw", now: Date(timeIntervalSince1970: 0))
        try store.backup(name: "Alpha", now: Date(timeIntervalSince1970: 60))
        let backup = try XCTUnwrap(store.backups(name: "Alpha").first)
        // 删掉同时间戳的信封备份,模拟不完整备份集
        let keyBackup = backup.deletingPathExtension().appendingPathExtension("upwkey")
        try FileManager.default.removeItem(at: keyBackup)
        XCTAssertTrue(store.backups(name: "Alpha").isEmpty)
        XCTAssertThrowsError(try store.restoreBackupAsCopy(
            backup: backup,
            name: "Gamma",
            sourcePassword: "pw",
            newPassword: "new-pw"))
        XCTAssertFalse(store.exists("Gamma"), "rejected restore must not write the target")
    }

    func testRestoreRejectsMagicMismatch() throws {
        try store.create(name: "Alpha", password: "pw", now: Date(timeIntervalSince1970: 0))
        let foreign = tempDir.appendingPathComponent("foreign.upw")
        try Data("plaintext junk".utf8).write(to: foreign)
        XCTAssertThrowsError(try store.restoreBackupAsCopy(
            backup: foreign,
            name: "Alpha2",
            sourcePassword: "pw",
            newPassword: "new-pw"))
        XCTAssertFalse(store.exists("Alpha2"), "rejected restore must not write the target")
    }

    func testRestoreBackupRejectsWrongPasswordAndExistingTargetWithoutMutation() throws {
        try store.create(name: "Alpha", password: "pw")
        let original = try store.load(name: "Alpha", password: "pw")
        try store.backup(name: "Alpha", now: Date(timeIntervalSince1970: 60))
        let backup = try XCTUnwrap(store.backups(name: "Alpha").first)

        XCTAssertThrowsError(try store.restoreBackupAsCopy(
            backup: backup,
            name: "WrongPassword",
            sourcePassword: "wrong",
            newPassword: "new-pw"))
        XCTAssertFalse(store.exists("WrongPassword"))

        XCTAssertThrowsError(try store.restoreBackupAsCopy(
            backup: backup,
            name: "Alpha",
            sourcePassword: "pw",
            newPassword: "new-pw"))
        XCTAssertEqual(try store.load(name: "Alpha", password: "pw"), original)
    }

    func testDeleteBackupConfinedToOwnDirectory() throws {
        try store.create(name: "Alpha", password: "pw", now: Date(timeIntervalSince1970: 0))
        try store.backup(name: "Alpha", now: Date(timeIntervalSince1970: 1))
        let outside = tempDir.appendingPathComponent("outside.upw")
        try Data("x".utf8).write(to: outside)
        XCTAssertThrowsError(try store.deleteBackup(outside, name: "Alpha"),
                             "deleteBackup must reject paths outside the database's backup dir")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testDeleteDamagedBackupPackageWithinDatabaseDirectory() throws {
        try store.create(name: "Alpha", password: "pw", now: Date(timeIntervalSince1970: 0))
        try FileManager.default.createDirectory(
            at: store.backupDir(for: "Alpha"),
            withIntermediateDirectories: true)
        let damagedPackage = store.backupDir(for: "Alpha")
            .appendingPathComponent("20260101-000000.\(BackupPackage.fileExtension)", isDirectory: true)
        try FileManager.default.createDirectory(at: damagedPackage, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: damagedPackage.appendingPathComponent("Snapshot.upw"))

        let entries = try FileManager.default.contentsOfDirectory(
            at: store.backupDir(for: "Alpha"),
            includingPropertiesForKeys: nil)
        XCTAssertEqual(entries.map(\.lastPathComponent), [damagedPackage.lastPathComponent])
        XCTAssertEqual(entries.first?.pathExtension, BackupPackage.fileExtension)
        XCTAssertEqual(
            store.backups(name: "Alpha").map(\.lastPathComponent),
            [damagedPackage.lastPathComponent])
        try store.deleteBackup(damagedPackage, name: "Alpha")
        XCTAssertFalse(FileManager.default.fileExists(atPath: damagedPackage.path))
    }

    func testSelfContainedPackageAssessesAndRestoresAsIndependentCopy() async throws {
        try store.create(name: "Alpha", password: "source-pw")
        let (loadedDatabase, sourceKey) = try store.loadUnlocked(name: "Alpha", password: "source-pw")
        var database = loadedDatabase
        var card = Card(title: "Package restore")
        card.files = [Attachment(name: "local.txt", data: Data("local attachment".utf8))]
        database.cards.append(card)
        try store.save(database, name: "Alpha", vaultKey: sourceKey)

        let result = try await BackupPackage.capture(
            store: store,
            name: "Alpha",
            database: database,
            vaultKey: sourceKey,
            syncState: RowSyncState())
        XCTAssertTrue(result.assessment.isComplete)

        let assessment = try BackupPackage.assess(at: result.url, sourcePassword: "source-pw")
        XCTAssertTrue(assessment.isComplete)
        XCTAssertEqual(assessment.cardCount, database.cards.count)
        XCTAssertNotNil(assessment.verificationToken)
        let restored = try store.restoreBackupAsCopy(
            backup: result.url,
            name: "Beta",
            sourcePassword: "source-pw",
            newPassword: "copy-pw",
            expectedPackageVerificationToken: assessment.verificationToken)
        XCTAssertEqual(restored.name, "Beta")
        XCTAssertEqual(
            try store.load(name: "Beta", password: "copy-pw").card(id: card.id)?.files.first?.data,
            Data("local attachment".utf8))
        XCTAssertEqual(try store.loadSyncState(for: "Beta"), RowSyncState())
        let restoredKey = try store.loadUnlocked(name: "Beta", password: "copy-pw").1
        let history = try XCTUnwrap(store.loadBackupHistory(for: "Beta", vaultKey: restoredKey))
        XCTAssertTrue(history.attachmentVersions.isEmpty)
        XCTAssertTrue(history.conflicts.isEmpty)
        XCTAssertNotEqual(
            sourceKey.withUnsafeBytes { Data($0) },
            restoredKey.withUnsafeBytes { Data($0) })
        XCTAssertThrowsError(try store.loadBackupHistory(for: "Beta", vaultKey: sourceKey))
    }

    func testKeyRotationAbortsWithoutChangingSnapshotWhenHistoryCannotBeAuthenticated() async throws {
        try store.create(name: "Alpha", password: "source-pw")
        let (database, sourceKey) = try store.loadUnlocked(name: "Alpha", password: "source-pw")
        let capture = try await BackupPackage.capture(
            store: store,
            name: "Alpha",
            database: database,
            vaultKey: sourceKey,
            syncState: RowSyncState())
        let assessment = try BackupPackage.assess(at: capture.url, sourcePassword: "source-pw")
        _ = try store.restoreBackupAsCopy(
            backup: capture.url,
            name: "Beta",
            sourcePassword: "source-pw",
            newPassword: "copy-pw",
            expectedPackageVerificationToken: assessment.verificationToken)

        let (restored, oldKey) = try store.loadUnlocked(name: "Beta", password: "copy-pw")
        let bodyBefore = try Data(contentsOf: store.url(for: "Beta"))
        let envelopeBefore = try Data(contentsOf: store.keyURL(for: "Beta"))
        let stateBefore = try store.loadSyncState(for: "Beta")
        let damagedHistory = Data("damaged history".utf8)
        try damagedHistory.write(to: store.backupHistoryURL(for: "Beta"), options: .atomic)

        let newKey = DatabaseCipher.generateVaultKey()
        let newEnvelope = try DatabaseCipher.wrapVaultKey(newKey, password: "rotated-pw")
        XCTAssertThrowsError(try store.commitSyncSnapshot(
            restored,
            name: "Beta",
            vaultKey: newKey,
            state: stateBefore,
            envelope: newEnvelope,
            rekeyBackupHistoryFrom: oldKey))

        XCTAssertEqual(try Data(contentsOf: store.url(for: "Beta")), bodyBefore)
        XCTAssertEqual(try Data(contentsOf: store.keyURL(for: "Beta")), envelopeBefore)
        XCTAssertEqual(try Data(contentsOf: store.backupHistoryURL(for: "Beta")), damagedHistory)
        XCTAssertEqual(try store.load(name: "Beta", password: "copy-pw"), restored)
        XCTAssertEqual(try store.loadSyncState(for: "Beta"), stateBefore)
    }

    func testRestoredHistoryDecodesArchivesWithoutQuarantineCollections() throws {
        struct LegacyHistory: Encodable {
            let sourceCreatedAt: Date
            let attachmentVersions: [BackupPackage.HistoricalAttachment]
            let conflicts: [BackupPackage.HistoricalConflict]
            let issues: [BackupPackage.Issue]
        }

        let encoded = try JSONEncoder().encode(LegacyHistory(
            sourceCreatedAt: Date(timeIntervalSince1970: 1),
            attachmentVersions: [],
            conflicts: [],
            issues: []))
        let decoded = try JSONDecoder().decode(BackupPackage.RestoredHistory.self, from: encoded)

        XCTAssertTrue(decoded.quarantinedAttachments.isEmpty)
        XCTAssertTrue(decoded.quarantinedCandidates.isEmpty)
    }

    func testSelfContainedPackageRequiresReviewedIncompleteRestore() async throws {
        try store.create(name: "Alpha", password: "source-pw")
        let (database, sourceKey) = try store.loadUnlocked(name: "Alpha", password: "source-pw")
        var state = RowSyncState()
        state.cursor = 3
        let result = try await BackupPackage.capture(
            store: store,
            name: "Alpha",
            database: database,
            vaultKey: sourceKey,
            syncState: state)
        XCTAssertFalse(result.assessment.isComplete)

        let assessment = try BackupPackage.assess(at: result.url, sourcePassword: "source-pw")
        XCTAssertFalse(assessment.isComplete)
        XCTAssertEqual(assessment.issues, [.cloudInventoryUnavailable])
        XCTAssertThrowsError(try store.restoreBackupAsCopy(
            backup: result.url,
            name: "Rejected",
            sourcePassword: "source-pw",
            newPassword: "copy-pw",
            expectedPackageVerificationToken: assessment.verificationToken))
        XCTAssertFalse(store.exists("Rejected"))

        _ = try store.restoreBackupAsCopy(
            backup: result.url,
            name: "Accepted",
            sourcePassword: "source-pw",
            newPassword: "copy-pw",
            expectedPackageVerificationToken: assessment.verificationToken,
            allowIncompletePackage: true)
        XCTAssertTrue(store.exists("Accepted"))
    }

    func testPortableSelfContainedBackupRestoresAsIndependentCopy() async throws {
        try store.create(name: "Alpha", password: "source-pw")
        let (database, sourceKey) = try store.loadUnlocked(name: "Alpha", password: "source-pw")
        let card = Card(title: "Portable restore")
        var updatedDatabase = database
        updatedDatabase.cards.append(card)
        try store.save(updatedDatabase, name: "Alpha", vaultKey: sourceKey)

        var sourceState = RowSyncState()
        sourceState.cursor = 19
        sourceState.revisions[card.id] = 2
        try store.saveSyncState(sourceState, for: "Alpha")

        let captured = try await BackupPackage.capture(
            store: store,
            name: "Alpha",
            database: updatedDatabase,
            vaultKey: sourceKey,
            syncState: sourceState)
        let archive = tempDir.appendingPathComponent("portable.upwbackup")
        try BackupPackage.exportPortableArchive(from: captured.url, to: archive)

        let info = try BackupPackage.readInfo(at: archive)
        XCTAssertFalse(info.isComplete)
        let assessment = try BackupPackage.assess(at: archive, sourcePassword: "source-pw")
        XCTAssertEqual(assessment.cardCount, updatedDatabase.cards.count)
        XCTAssertEqual(assessment.issues, [.cloudInventoryUnavailable])

        let restoredFile = try store.restoreBackupAsCopy(
            backup: archive,
            name: "PortableCopy",
            sourcePassword: "source-pw",
            newPassword: "new-copy-pw",
            expectedPackageVerificationToken: assessment.verificationToken,
            allowIncompletePackage: true)

        XCTAssertFalse(restoredFile.isMain)
        XCTAssertEqual(
            try store.load(name: "PortableCopy", password: "new-copy-pw").card(id: card.id)?.title,
            "Portable restore")
        XCTAssertEqual(try store.loadSyncState(for: "PortableCopy"), RowSyncState())
        XCTAssertEqual(try store.loadSyncState(for: "Alpha"), sourceState)
        XCTAssertTrue(store.backups(name: "PortableCopy").isEmpty)
    }

    func testSelfContainedPackageMarksMissingLocalAttachmentIncomplete() async throws {
        try store.create(name: "Alpha", password: "source-pw")
        let (loadedDatabase, sourceKey) = try store.loadUnlocked(name: "Alpha", password: "source-pw")
        var database = loadedDatabase
        var card = Card(title: "Missing attachment")
        card.files = [Attachment(name: "remote-only.txt", data: nil)]
        database.cards.append(card)
        try store.save(database, name: "Alpha", vaultKey: sourceKey)

        let result = try await BackupPackage.capture(
            store: store,
            name: "Alpha",
            database: database,
            vaultKey: sourceKey,
            syncState: RowSyncState())

        XCTAssertFalse(result.assessment.isComplete)
        XCTAssertTrue(result.assessment.issues.contains {
            if case .attachmentVersionUnavailable = $0 { return true }
            return false
        })
        XCTAssertThrowsError(try BackupPackage.assess(at: result.url, sourcePassword: "wrong-pw"))
    }

    func testBoundVaultRequiresCloudInventoryEvenWithFreshLocalSyncState() async throws {
        try store.create(name: "Alpha", password: "source-pw")
        let (database, sourceKey) = try store.loadUnlocked(name: "Alpha", password: "source-pw")

        let result = try await BackupPackage.capture(
            store: store,
            name: "Alpha",
            database: database,
            vaultKey: sourceKey,
            syncState: RowSyncState(),
            cloudRequired: true)

        XCTAssertFalse(result.assessment.isComplete)
        XCTAssertEqual(result.assessment.issues, [.cloudInventoryUnavailable])
    }

    func testSelfContainedPackageRejectsTamperedSnapshot() async throws {
        try store.create(name: "Alpha", password: "source-pw")
        let (database, sourceKey) = try store.loadUnlocked(name: "Alpha", password: "source-pw")
        let result = try await BackupPackage.capture(
            store: store,
            name: "Alpha",
            database: database,
            vaultKey: sourceKey,
            syncState: RowSyncState())
        let snapshotURL = result.url.appendingPathComponent("Snapshot.upw")
        try Data("tampered".utf8).write(to: snapshotURL, options: .atomic)

        XCTAssertThrowsError(try BackupPackage.assess(at: result.url, sourcePassword: "source-pw"))
        XCTAssertThrowsError(try store.restoreBackupAsCopy(
            backup: result.url,
            name: "Rejected",
            sourcePassword: "source-pw",
            newPassword: "copy-pw",
            expectedPackageVerificationToken: result.assessment.verificationToken))
        XCTAssertFalse(store.exists("Rejected"))
    }
}
