import Foundation
import XCTest

@testable import UPasswordsPersistence

final class PortableBackupArchiveTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUp() {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("upw-portable-archive-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testArchiveRoundTripPreservesPackageFiles() throws {
        let package = try makePackage()
        let archive = temporaryDirectory.appendingPathComponent("copy.upwbackup")
        let restored = temporaryDirectory.appendingPathComponent("restored", isDirectory: true)

        try PortableBackupArchive.createArchive(from: package, to: archive)

        let entries = try PortableBackupArchive.filePaths(in: archive)
        XCTAssertEqual(entries.count, 6)
        XCTAssertEqual(
            try PortableBackupArchive.readFile(at: archive, path: "Info.json", maximumSize: 1024),
            Data("index".utf8))
        try PortableBackupArchive.extractArchive(at: archive, to: restored)

        for path in entries.keys {
            let original = package.appendingPathComponent(path)
            let copy = restored.appendingPathComponent(path)
            XCTAssertEqual(try Data(contentsOf: original), try Data(contentsOf: copy))
        }
    }

    func testExtensionUSTARFixtureMatchesNativeReader() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixtureURL = repositoryRoot
            .appendingPathComponent("Contracts/test-vectors/browser-empty-backup.ustar.b64")
        let encoded = try String(contentsOf: fixtureURL, encoding: .utf8)
        let archiveData = try XCTUnwrap(Data(base64Encoded: encoded, options: .ignoreUnknownCharacters))
        let archive = temporaryDirectory.appendingPathComponent("extension.upwbackup")
        try archiveData.write(to: archive)

        let entries = try PortableBackupArchive.filePaths(in: archive)

        XCTAssertEqual(Set(entries.keys), Set([
            "Info.json",
            "Manifest.sealed",
            "Snapshot.upw",
            "Snapshot.upwkey",
        ]))
        XCTAssertTrue(entries.values.allSatisfy { $0 == 0 })
    }

    func testArchiveRejectsUnsupportedSourceFiles() throws {
        let package = try makePackage()
        try Data("unexpected".utf8).write(to: package.appendingPathComponent("extra.txt"))
        let archive = temporaryDirectory.appendingPathComponent("copy.upwbackup")

        XCTAssertThrowsError(try PortableBackupArchive.createArchive(from: package, to: archive))
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
    }

    func testArchiveRejectsInvalidChecksumAndTruncatedEndMarker() throws {
        let package = try makePackage()
        let archive = temporaryDirectory.appendingPathComponent("copy.upwbackup")
        try PortableBackupArchive.createArchive(from: package, to: archive)
        let original = try Data(contentsOf: archive)

        var invalidHeader = original
        invalidHeader[0] ^= 1
        let invalidHeaderURL = temporaryDirectory.appendingPathComponent("invalid.upwbackup")
        try invalidHeader.write(to: invalidHeaderURL)
        XCTAssertThrowsError(try PortableBackupArchive.filePaths(in: invalidHeaderURL))

        let truncatedURL = temporaryDirectory.appendingPathComponent("truncated.upwbackup")
        try original.dropLast().write(to: truncatedURL)
        XCTAssertThrowsError(try PortableBackupArchive.filePaths(in: truncatedURL))
    }

    func testReadFileEnforcesDeclaredSizeLimit() throws {
        let package = try makePackage()
        let archive = temporaryDirectory.appendingPathComponent("copy.upwbackup")
        try PortableBackupArchive.createArchive(from: package, to: archive)

        XCTAssertThrowsError(
            try PortableBackupArchive.readFile(at: archive, path: "Info.json", maximumSize: 2))
    }

    private func makePackage() throws -> URL {
        let package = temporaryDirectory.appendingPathComponent("package", isDirectory: true)
        let attachments = package.appendingPathComponent("Attachments", isDirectory: true)
        let conflictDirectory = package.appendingPathComponent(
            "Conflicts/\(String(repeating: "a", count: 32))",
            isDirectory: true)
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: conflictDirectory, withIntermediateDirectories: true)

        try Data("index".utf8).write(to: package.appendingPathComponent("Info.json"))
        try Data("manifest".utf8).write(to: package.appendingPathComponent("Manifest.sealed"))
        try Data("snapshot".utf8).write(to: package.appendingPathComponent("Snapshot.upw"))
        try Data("envelope".utf8).write(to: package.appendingPathComponent("Snapshot.upwkey"))
        let attachmentName = "123e4567-e89b-12d3-a456-426614174000-123e4567-e89b-12d3-a456-426614174001.cipher"
        try Data(repeating: 4, count: 2049).write(to: attachments.appendingPathComponent(attachmentName))
        try Data("candidate".utf8).write(
            to: conflictDirectory.appendingPathComponent("\(String(repeating: "b", count: 32)).cipher"))
        return package
    }
}
