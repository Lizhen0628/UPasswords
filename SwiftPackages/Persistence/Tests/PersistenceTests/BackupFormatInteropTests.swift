import Foundation
import XCTest

@testable import UPasswordsPersistence

final class BackupFormatInteropTests: XCTestCase {
    func testBrowserGeneratedPortablePackageAssessesNatively() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let packageURL = repositoryRoot
            .appendingPathComponent("Contracts/test-vectors/browser-incomplete-backup.ustar.b64")
        let vaultVectorURL = repositoryRoot
            .appendingPathComponent("WebExtensions/shared/test/fixtures/vault-vector.json")
        let encoded = try String(contentsOf: packageURL, encoding: .utf8)
        let archiveData = try XCTUnwrap(Data(base64Encoded: encoded, options: .ignoreUnknownCharacters))
        let vaultVectorData = try Data(contentsOf: vaultVectorURL)
        let vaultVector = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: vaultVectorData) as? [String: Any])
        let sourcePassword = try XCTUnwrap(vaultVector["password"] as? String)
        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("browser-backup-\(UUID().uuidString).upwbackup")
        try archiveData.write(to: archiveURL)
        defer { try? FileManager.default.removeItem(at: archiveURL) }

        let assessment = try BackupPackage.assess(at: archiveURL, sourcePassword: sourcePassword)

        XCTAssertFalse(assessment.isComplete)
        XCTAssertEqual(assessment.cardCount, 1)
        XCTAssertEqual(assessment.issues, [.retainedConflictHistoryUnavailable])
    }

    func testBackupIssueUsesStableSwiftCodableShape() throws {
        let data = try JSONEncoder().encode(BackupPackage.Issue.retainedConflictHistoryUnavailable)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertEqual(json, "{\"retainedConflictHistoryUnavailable\":{}}")
    }

    func testHistoricalConflictDecodesWhenResolutionMetadataIsAbsent() throws {
        let conflictID = String(repeating: "a", count: 32)
        let itemUUID = "123e4567-e89b-12d3-a456-426614174000"
        let json = """
        {
          "conflictID": "\(conflictID)",
          "itemUUID": "\(itemUUID)",
          "baseRevision": 1,
          "currentRevision": 2,
          "currentDeletedSequence": 0,
          "generation": 1,
          "createdAt": 0,
          "updatedAt": 1,
          "candidates": []
        }
        """

        let conflict = try JSONDecoder().decode(
            BackupPackage.HistoricalConflict.self,
            from: Data(json.utf8))

        XCTAssertEqual(conflict.conflictID, conflictID)
        XCTAssertNil(conflict.resolvedAt)
        XCTAssertNil(conflict.expiresAt)
        XCTAssertNil(conflict.selectedCandidateID)
    }

    func testBackupInfoUsesReferenceDateSecondsAndExactCounters() throws {
        let info = BackupPackage.Info(
            version: 1,
            createdAt: Date(timeIntervalSince1970: 978_307_200),
            isComplete: false,
            attachmentVersionCount: 2,
            conflictCount: 3,
            conflictCandidateCount: 4,
            issueCount: 1)
        let data = try JSONEncoder().encode(info)
        let value = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(value["createdAt"] as? Double, 0)
        XCTAssertEqual(value["version"] as? Int, 1)
        XCTAssertEqual(value["isComplete"] as? Bool, false)
        XCTAssertEqual(value["attachmentVersionCount"] as? Int, 2)
        XCTAssertEqual(value["conflictCount"] as? Int, 3)
        XCTAssertEqual(value["conflictCandidateCount"] as? Int, 4)
        XCTAssertEqual(value["issueCount"] as? Int, 1)
    }
}
