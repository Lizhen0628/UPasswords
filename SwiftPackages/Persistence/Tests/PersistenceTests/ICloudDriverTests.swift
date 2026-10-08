import XCTest
@testable import UPasswordsPersistence
import UPasswordsCore

final class ICloudDriverTests: XCTestCase {

    /// 上传后能原样读回(经 NSFileCoordinator 协调读写)。
    func testUploadDownloadRoundTrip() async throws {
        let root = try tempRoot()
        let driver = ICloudDriver(databaseName: "RoundTrip", cloudRoot: root)
        try await driver.testConnection()
        // 驱动对读取内容做 UPWDB 魔数校验,测试载荷须为真实容器
        let payload = try DatabaseCipher.encryptedData(Data("upw-container".utf8), password: "t")
        try await driver.upload(payload)
        let downloaded = try await driver.download()
        XCTAssertEqual(downloaded, payload)
    }

    /// 远端尚无文件时 download 返回 nil(等同 WebDAV 404 语义)。
    func testDownloadMissingFileReturnsNil() async throws {
        let root = try tempRoot()
        let driver = ICloudDriver(databaseName: "Missing", cloudRoot: root)
        try await driver.testConnection()
        let downloaded = try await driver.download()
        XCTAssertNil(downloaded)
    }

    /// testConnection 自动创建容器目录,文件落在 UPasswords/<数据库名>.upw。
    func testFolderLayout() async throws {
        let root = try tempRoot()
        let driver = ICloudDriver(databaseName: "Layout", cloudRoot: root)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("UPasswords").path))
        try await driver.testConnection()
        try await driver.upload(try DatabaseCipher.encryptedData(Data([1, 2, 3]), password: "t"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("UPasswords/Layout.upw").path))
    }

    /// 覆盖上传后读取到的是新内容(原子替换语义)。
    func testUploadReplacesPreviousContent() async throws {
        let root = try tempRoot()
        let driver = ICloudDriver(databaseName: "Replace", cloudRoot: root)
        try await driver.testConnection()
        // 驱动对读取内容做 UPWDB 魔数校验,测试载荷须为真实容器
        try await driver.upload(try DatabaseCipher.encryptedData(Data("old".utf8), password: "t"))
        let newer = try DatabaseCipher.encryptedData(Data("new-and-longer".utf8), password: "t")
        try await driver.upload(newer)
        let downloaded = try await driver.download()
        XCTAssertEqual(downloaded, newer)
    }

    // MARK: - 夹具

    /// 独立临时目录充当 iCloud 云盘根;测试结束自动清理。
    private func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("upw-icloud-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }
}
