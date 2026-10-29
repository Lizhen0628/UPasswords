import CryptoKit
import Foundation
import XCTest
import UPasswordsCore
@testable import UPasswordsPersistence

final class BackupCloudCaptureTests: XCTestCase {
    func testCapturePreservesLocallyQuarantinedCandidateAfterCloudRetention() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("upw-backup-local-quarantine-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = DatabaseStore(root: root)
        try store.create(name: "Alpha", password: "source-password")
        let (database, vaultKey) = try store.loadUnlocked(
            name: "Alpha", password: "source-password")
        let rowKey = RowSyncKey(raw: vaultKey.withUnsafeBytes { Data($0) })
        let itemID = UUID()
        let candidateCipher = Data("permanently-unreadable-candidate".utf8)
        let candidate = RelayClient.ConflictCandidate(
            candidateID: String(repeating: "a", count: 32),
            kind: 1,
            isDelete: false,
            revision: 3,
            modifiedAt: Date(timeIntervalSince1970: 100),
            committedAt: Date(timeIntervalSince1970: 101),
            deviceName: "Mac",
            platform: "macos",
            bodyB64: candidateCipher.base64EncodedString(),
            sha256: Self.sha256(candidateCipher))
        let conflict = RelayClient.ConflictRecord(
            conflictID: String(repeating: "c", count: 32),
            itemUUID: itemID,
            baseRevision: 2,
            currentRevision: 3,
            currentDeletedSequence: 0,
            generation: 1,
            createdAt: Date(timeIntervalSince1970: 90),
            updatedAt: Date(timeIntervalSince1970: 91),
            candidates: [candidate])
        var syncState = RowSyncState()
        let quarantined = try RowSyncCipher.quarantineCandidate(
            candidate,
            conflict: conflict,
            reason: .authenticationFailed,
            key: rowKey)
        syncState.quarantinedCandidates[quarantined.id] = quarantined

        let captured = try await BackupPackage.capture(
            store: store,
            name: "Alpha",
            database: database,
            vaultKey: vaultKey,
            syncState: syncState)
        XCTAssertFalse(captured.assessment.isComplete)
        XCTAssertTrue(captured.assessment.issues.contains(.cloudInventoryUnavailable))
        XCTAssertTrue(captured.assessment.issues.contains(
            .conflictCandidateUnavailable(conflictID: conflict.conflictID, candidateID: candidate.candidateID)))
        XCTAssertEqual(captured.assessment.conflictCandidateCount, 1)

        let assessment = try BackupPackage.assess(
            at: captured.url,
            sourcePassword: "source-password")
        _ = try store.restoreBackupAsCopy(
            backup: captured.url,
            name: "Beta",
            sourcePassword: "source-password",
            newPassword: "copy-password",
            expectedPackageVerificationToken: assessment.verificationToken,
            allowIncompletePackage: true)
        let (restoredDatabase, restoredKey) = try store.loadUnlocked(
            name: "Beta", password: "copy-password")
        let history = try XCTUnwrap(store.loadBackupHistory(for: "Beta", vaultKey: restoredKey))
        XCTAssertEqual(history.quarantinedCandidates.count, 1)
        XCTAssertEqual(history.quarantinedCandidates[0].conflictID, conflict.conflictID)
        XCTAssertEqual(history.quarantinedCandidates[0].candidateID, candidate.candidateID)
        XCTAssertEqual(history.quarantinedCandidates[0].cipher, candidateCipher)
        _ = restoredDatabase
    }

    func testCaptureMarksCloudInventoryChangesDuringPayloadWindowIncomplete() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("upw-backup-inventory-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = DatabaseStore(root: root)
        try store.create(name: "Alpha", password: "source-password")
        let (database, vaultKey) = try store.loadUnlocked(name: "Alpha", password: "source-password")
        let vaultReadCount = SynchronizedCounter()
        BackupCloudURLProtocol.install { request in
            switch request.url?.path {
            case "/v1/vaults/vault-test":
                let headSequence = vaultReadCount.increment() == 1 ? 0 : 1
                return Self.jsonResponse(
                    "{\"vaultId\":\"vault-test\",\"name\":\"Main\",\"passwordVersion\":1,\"hasEnvelope\":false,\"headSeq\":\(headSequence),\"itemCount\":0}",
                    request: request)
            case "/v1/vaults/vault-test/attachment-versions":
                return Self.jsonResponse(
                    #"{"versions":[],"nextOffset":0,"hasMore":false}"#,
                    request: request)
            case "/v1/vaults/vault-test/conflicts":
                return Self.jsonResponse(#"{"conflicts":[]}"#, request: request)
            default:
                throw URLError(.unsupportedURL)
            }
        }
        defer { BackupCloudURLProtocol.clear() }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BackupCloudURLProtocol.self]
        let client = RelayClient(
            baseURL: URL(string: "https://backup.test")!,
            session: URLSession(configuration: configuration))
        let result = try await BackupPackage.capture(
            store: store,
            name: "Alpha",
            database: database,
            vaultKey: vaultKey,
            syncState: RowSyncState(),
            cloud: .init(client: client, token: "test-token", vaultID: "vault-test"),
            cloudRequired: true)

        XCTAssertFalse(result.assessment.isComplete)
        XCTAssertTrue(result.assessment.issues.contains(.cloudInventoryChanged))
        XCTAssertEqual(vaultReadCount.value, 2)
    }

    func testCloudCaptureRestoresRetainedConflictsAsReadOnlyHistory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("upw-backup-retained-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = DatabaseStore(root: root)
        try store.create(name: "Alpha", password: "source-password")
        let (database, sourceKey) = try store.loadUnlocked(name: "Alpha", password: "source-password")
        let itemID = UUID()
        let historicalCard = Card(id: itemID, title: "Historical candidate")
        let candidateCipher = try RowSyncCipher.encrypt(
            DatabaseItemCodec.xmlData(.card(historicalCard)),
            key: RowSyncKey(raw: sourceKey.withUnsafeBytes { Data($0) }),
            uuid: itemID)
        let conflictID = String(repeating: "d", count: 32)
        let selectedCandidateID = String(repeating: "e", count: 32)
        let deleteCandidateID = String(repeating: "f", count: 32)
        let candidateDigest = Self.sha256(candidateCipher)

        BackupCloudURLProtocol.install { request in
            switch request.url?.path {
            case "/v1/vaults/vault-test":
                return Self.jsonResponse(
                    #"{"vaultId":"vault-test","name":"Main","passwordVersion":1,"hasEnvelope":false,"headSeq":0,"itemCount":0}"#,
                    request: request)
            case "/v1/vaults/vault-test/attachment-versions":
                return Self.jsonResponse(
                    #"{"versions":[],"nextOffset":0,"hasMore":false}"#,
                    request: request)
            case "/v1/vaults/vault-test/conflicts":
                return Self.jsonResponse(#"{"conflicts":[]}"#, request: request)
            case "/v1/vaults/vault-test/conflict-history":
                return Self.jsonResponse(
                    """
                    {"snapshotMs":1800000000000,"totalCandidates":2,"nextCursor":null,"candidates":[
                      {"conflictId":"\(conflictID)","itemUuid":"\(itemID.uuidString)","baseRevision":1,"currentRevision":2,"currentDeletedSeq":0,"generation":1,"createdMs":1600000000000,"updatedMs":1650000000000,"resolvedMs":1700000000000,"expiresMs":1900000000000,"selectedCandidateId":"\(selectedCandidateID)","candidate":{"candidateId":"\(selectedCandidateID)","kind":1,"op":"upsert","revision":1,"modifiedMs":1600000000000,"committedMs":1650000000000,"deviceName":"Mac","platform":"macos","bodyB64":"\(candidateCipher.base64EncodedString())","sha256":"\(candidateDigest)"}},
                      {"conflictId":"\(conflictID)","itemUuid":"\(itemID.uuidString)","baseRevision":1,"currentRevision":2,"currentDeletedSeq":0,"generation":1,"createdMs":1600000000000,"updatedMs":1650000000000,"resolvedMs":1700000000000,"expiresMs":1900000000000,"selectedCandidateId":"\(selectedCandidateID)","candidate":{"candidateId":"\(deleteCandidateID)","kind":1,"op":"delete","revision":2,"modifiedMs":1650000000000,"committedMs":1660000000000,"deviceName":"iPhone","platform":"ios"}}
                    ]}
                    """,
                    request: request)
            default:
                throw URLError(.unsupportedURL)
            }
        }
        defer { BackupCloudURLProtocol.clear() }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BackupCloudURLProtocol.self]
        let client = RelayClient(
            baseURL: URL(string: "https://backup.test")!,
            session: URLSession(configuration: configuration))
        let result = try await BackupPackage.capture(
            store: store,
            name: "Alpha",
            database: database,
            vaultKey: sourceKey,
            syncState: RowSyncState(),
            cloud: .init(client: client, token: "test-token", vaultID: "vault-test"),
            cloudRequired: true,
            now: Date(timeIntervalSince1970: 1_800_000_000))

        XCTAssertTrue(result.assessment.isComplete)
        XCTAssertEqual(result.assessment.conflictCount, 1)
        XCTAssertEqual(result.assessment.conflictCandidateCount, 2)
        XCTAssertFalse(result.assessment.issues.contains(.retainedConflictHistoryUnavailable))
        let candidateFile = result.url
            .appendingPathComponent("Conflicts", isDirectory: true)
            .appendingPathComponent(conflictID, isDirectory: true)
            .appendingPathComponent("\(selectedCandidateID).cipher")
        XCTAssertEqual(try Data(contentsOf: candidateFile), candidateCipher)

        let assessment = try BackupPackage.assess(at: result.url, sourcePassword: "source-password")
        try store.restoreBackupAsCopy(
            backup: result.url,
            name: "Beta",
            sourcePassword: "source-password",
            newPassword: "copy-password",
            expectedPackageVerificationToken: assessment.verificationToken,
            allowIncompletePackage: false)
        let (_, restoredKey) = try store.loadUnlocked(name: "Beta", password: "copy-password")
        let history = try XCTUnwrap(store.loadBackupHistory(for: "Beta", vaultKey: restoredKey))
        let retained = try XCTUnwrap(history.conflicts.first)
        XCTAssertEqual(retained.conflictID, conflictID)
        XCTAssertEqual(retained.resolvedAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(retained.selectedCandidateID, selectedCandidateID)
        XCTAssertEqual(
            Set(retained.candidates.map(\.candidateID)),
            Set([selectedCandidateID, deleteCandidateID]))
    }

    func testCloudCapturePreservesAuthenticatedAndQuarantinedPayloadsAcrossRestoreAndRekey() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("upw-backup-cloud-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = DatabaseStore(root: root)
        try store.create(name: "Alpha", password: "source-password")
        let (database, sourceKey) = try store.loadUnlocked(name: "Alpha", password: "source-password")
        let sourceRowKey = RowSyncKey(raw: sourceKey.withUnsafeBytes { Data($0) })
        let attachmentID = UUID()
        let currentVersion = UUID()
        let retainedVersion = UUID()
        let currentAttachment = try AttachmentSyncCipher.encrypt(
            data: Data("current attachment".utf8),
            key: sourceRowKey,
            attachmentID: attachmentID,
            contentVersion: currentVersion)
        let unrelatedKey = RowSyncKey(raw: Data(repeating: 0xA5, count: 32))
        let retainedAttachment = try AttachmentSyncCipher.encrypt(
            data: Data("retained attachment".utf8),
            key: unrelatedKey,
            attachmentID: attachmentID,
            contentVersion: retainedVersion)

        let conflictID = String(repeating: "a", count: 32)
        let itemID = UUID()
        let firstCandidateID = String(repeating: "b", count: 32)
        let quarantinedCandidateID = String(repeating: "c", count: 32)
        let candidateCard = Card(id: itemID, title: "Authenticated candidate")
        let candidatePlaintext = DatabaseItemCodec.xmlData(.card(candidateCard))
        let candidateCipher = try RowSyncCipher.encrypt(
            candidatePlaintext,
            key: sourceRowKey,
            uuid: itemID)
        let quarantinedCandidateCipher = Data("not-a-valid-row-cipher".utf8)
        let versions = [
            VersionFixture(
                attachmentID: attachmentID,
                cardID: try XCTUnwrap(database.cards.first?.id),
                contentVersion: currentVersion,
                encrypted: currentAttachment,
                isCurrent: true),
            VersionFixture(
                attachmentID: attachmentID,
                cardID: try XCTUnwrap(database.cards.first?.id),
                contentVersion: retainedVersion,
                encrypted: retainedAttachment,
                isCurrent: false),
        ]

        BackupCloudURLProtocol.install { request in
            guard let path = request.url?.path else {
                throw URLError(.badURL)
            }
            switch path {
            case "/v1/vaults/vault-test":
                return Self.jsonResponse(
                    #"{"vaultId":"vault-test","name":"Main","passwordVersion":1,"hasEnvelope":false,"headSeq":42,"itemCount":1}"#,
                    request: request)
            case "/v1/vaults/vault-test/attachment-versions":
                let entries = versions.map { version in
                    """
                    {"attachmentId":"\(version.attachmentID.uuidString)","cardUuid":"\(version.cardID.uuidString)","contentVersion":"\(version.contentVersion.uuidString)","dekWrapped":"\(version.encrypted.dekWrapped.base64EncodedString())","sha256":"\(Self.sha256(version.encrypted.cipher))","bytes":\(version.encrypted.cipher.count),"isCurrent":\(version.isCurrent)}
                    """
                }.joined(separator: ",")
                return Self.jsonResponse(
                    "{\"versions\":[\(entries)],\"nextOffset\":2,\"hasMore\":false}",
                    request: request)
            case "/v1/vaults/vault-test/conflicts":
                let body = """
                {"conflicts":[{"conflictId":"\(conflictID)","itemUuid":"\(itemID.uuidString)","baseRevision":1,"currentRevision":2,"currentDeletedSeq":0,"generation":1,"createdMs":1000,"updatedMs":2000,"candidates":[
                  {"candidateId":"\(firstCandidateID)","kind":1,"op":"upsert","revision":1,"modifiedMs":1000,"committedMs":1100,"deviceName":"Mac","platform":"macos","bodyB64":"\(candidateCipher.base64EncodedString())","sha256":"\(Self.sha256(candidateCipher))"},
                  {"candidateId":"\(quarantinedCandidateID)","kind":1,"op":"upsert","revision":2,"modifiedMs":1200,"committedMs":1300,"deviceName":"iPhone","platform":"ios","bodyB64":"\(quarantinedCandidateCipher.base64EncodedString())","sha256":"\(Self.sha256(quarantinedCandidateCipher))"}
                ]}]}
                """
                return Self.jsonResponse(body, request: request)
            case "/v1/vaults/vault-test/conflict-history":
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 503,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data(#"{"error":"temporarily_unavailable"}"#.utf8))
            case "/v1/vaults/vault-test/attachments/\(attachmentID.uuidString)":
                guard let versionText = request.url?.query?.split(separator: "=").last,
                      let requestedVersion = UUID(uuidString: String(versionText)),
                      let version = versions.first(where: { $0.contentVersion == requestedVersion }) else {
                    throw URLError(.badURL)
                }
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "X-Content-Version": version.contentVersion.uuidString,
                        "X-Dek-Wrapped": version.encrypted.dekWrapped.base64EncodedString(),
                        "X-Bytes": String(version.encrypted.cipher.count),
                        "Content-Length": String(version.encrypted.cipher.count),
                        "X-Sha256": Self.sha256(version.encrypted.cipher),
                    ])!
                return (response, version.encrypted.cipher)
            default:
                throw URLError(.unsupportedURL)
            }
        }
        defer { BackupCloudURLProtocol.clear() }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BackupCloudURLProtocol.self]
        let client = RelayClient(
            baseURL: URL(string: "https://backup.test")!,
            session: URLSession(configuration: configuration))
        var syncState = RowSyncState()
        syncState.cursor = 42
        syncState.pendingConflicts[itemID] = RowSyncPendingConflict(
            conflictID: conflictID,
            candidateID: firstCandidateID,
            fingerprint: "reviewed-fingerprint",
            baseRevision: 1,
            kind: 1,
            isDelete: false)

        let captured = try await BackupPackage.capture(
            store: store,
            name: "Alpha",
            database: database,
            vaultKey: sourceKey,
            syncState: syncState,
            cloud: .init(client: client, token: "test-token", vaultID: "vault-test"),
            cloudRequired: true,
            now: Date(timeIntervalSince1970: 1_800_000_000))

        XCTAssertFalse(captured.assessment.isComplete)
        XCTAssertEqual(captured.assessment.attachmentVersionCount, 2)
        XCTAssertEqual(captured.assessment.conflictCount, 1)
        XCTAssertEqual(captured.assessment.conflictCandidateCount, 2)
        XCTAssertTrue(captured.assessment.issues.contains(
            .conflictCandidateUnavailable(conflictID: conflictID, candidateID: quarantinedCandidateID)))
        XCTAssertTrue(captured.assessment.issues.contains(.retainedConflictHistoryUnavailable))
        XCTAssertTrue(captured.assessment.issues.contains(
            .attachmentVersionUnavailable(attachmentID: attachmentID, contentVersion: retainedVersion)))

        let candidateFile = captured.url
            .appendingPathComponent("Conflicts", isDirectory: true)
            .appendingPathComponent(conflictID, isDirectory: true)
            .appendingPathComponent("\(quarantinedCandidateID).cipher")
        let reviewedCandidateBytes = try Data(contentsOf: candidateFile)
        let reviewedAssessment = try BackupPackage.assess(
            at: captured.url,
            sourcePassword: "source-password")
        try Data("changed-invalid-cipher".utf8).write(to: candidateFile, options: .atomic)
        let changedAssessment = try BackupPackage.assess(
            at: captured.url,
            sourcePassword: "source-password")
        XCTAssertNotEqual(reviewedAssessment.verificationToken, changedAssessment.verificationToken)
        try reviewedCandidateBytes.write(to: candidateFile, options: .atomic)

        let finalAssessment = try BackupPackage.assess(
            at: captured.url,
            sourcePassword: "source-password")
        _ = try store.restoreBackupAsCopy(
            backup: captured.url,
            name: "Beta",
            sourcePassword: "source-password",
            newPassword: "copy-password",
            expectedPackageVerificationToken: finalAssessment.verificationToken,
            allowIncompletePackage: true)
        let (restoredDatabase, restoredKey) = try store.loadUnlocked(
            name: "Beta",
            password: "copy-password")
        var history = try XCTUnwrap(store.loadBackupHistory(for: "Beta", vaultKey: restoredKey))
        XCTAssertEqual(history.quarantinedAttachments.count, 1)
        XCTAssertEqual(history.quarantinedAttachments[0].cipher, retainedAttachment.cipher)
        XCTAssertEqual(history.quarantinedCandidates.count, 1)
        XCTAssertEqual(history.quarantinedCandidates[0].candidateID, quarantinedCandidateID)
        XCTAssertEqual(history.quarantinedCandidates[0].cipher, quarantinedCandidateCipher)
        XCTAssertEqual(history.conflicts[0].candidates.filter { $0.cipher != nil }.count, 1)

        let newKey = DatabaseCipher.generateVaultKey()
        let newEnvelope = try DatabaseCipher.wrapVaultKey(newKey, password: "rotated-password")
        try store.commitSyncSnapshot(
            restoredDatabase,
            name: "Beta",
            vaultKey: newKey,
            state: try store.loadSyncState(for: "Beta"),
            envelope: newEnvelope,
            rekeyBackupHistoryFrom: restoredKey)
        history = try XCTUnwrap(store.loadBackupHistory(for: "Beta", vaultKey: newKey))
        XCTAssertThrowsError(try store.loadBackupHistory(for: "Beta", vaultKey: restoredKey))
        XCTAssertEqual(history.quarantinedAttachments[0].cipher, retainedAttachment.cipher)
        XCTAssertEqual(history.quarantinedCandidates[0].cipher, quarantinedCandidateCipher)

        let rekeyedAttachment = try XCTUnwrap(history.attachmentVersions.first {
            $0.contentVersion == currentVersion
        })
        let rekeyedAttachmentPlaintext = try AttachmentSyncCipher.decrypt(
            cipher: XCTUnwrap(rekeyedAttachment.cipher),
            dekWrapped: XCTUnwrap(rekeyedAttachment.dekWrapped),
            key: RowSyncKey(raw: newKey.withUnsafeBytes { Data($0) }),
            attachmentID: attachmentID,
            contentVersion: currentVersion)
        XCTAssertEqual(rekeyedAttachmentPlaintext, Data("current attachment".utf8))
        let rekeyedCandidate = try XCTUnwrap(history.conflicts[0].candidates.first {
            $0.candidateID == firstCandidateID
        })
        let rekeyedCandidatePlaintext = try XCTUnwrap(RowSyncCipher.decrypt(
            XCTUnwrap(rekeyedCandidate.cipher),
            key: RowSyncKey(raw: newKey.withUnsafeBytes { Data($0) }),
            uuid: itemID))
        XCTAssertNotNil(DatabaseItemCodec.parse(kind: 1, uuid: itemID, data: rekeyedCandidatePlaintext))
        XCTAssertEqual(try store.load(name: "Beta", password: "rotated-password"), restoredDatabase)
    }

    private static func jsonResponse(
        _ body: String,
        request: URLRequest
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        return (response, Data(body.utf8))
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct VersionFixture {
    let attachmentID: UUID
    let cardID: UUID
    let contentVersion: UUID
    let encrypted: EncryptedAttachment
    let isCurrent: Bool
}

private final class SynchronizedCounter {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}

private final class BackupCloudURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    private static var handler: Handler?

    static func install(_ handler: @escaping Handler) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    static func clear() {
        lock.lock()
        handler = nil
        lock.unlock()
    }

    private static func currentHandler() -> Handler? {
        lock.lock()
        defer { lock.unlock() }
        return handler
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.currentHandler() else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
