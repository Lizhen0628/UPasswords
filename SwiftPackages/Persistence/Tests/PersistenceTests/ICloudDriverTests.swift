import XCTest
@testable import UPasswordsPersistence
import UPasswordsCore

final class ICloudDriverTests: XCTestCase {

    /// 上传后能原样读回(经 NSFileCoordinator 协调读写)。
    func testUploadDownloadRoundTrip() async throws {
        let root = try tempRoot()
        let driver = ICloudDriver(databaseName: "RoundTrip", cloudRoot: root)
        try await driver.testConnection()
        // 驱动对读取内容做 v2 魔数校验,测试载荷须为真实容器
        let payload = try DatabaseCipher.encryptBody(Data("upw-container".utf8),
                                                     vaultKey: DatabaseCipher.generateVaultKey())
        try await driver.upload(payload)
        let downloaded = try await driver.download()
        XCTAssertEqual(downloaded, payload)
    }

    /// 非 v2 内容(垃圾/半截写入)读回时按「未就绪」抛错,而不是交给上层
    /// 误判为「解不开」。回归:v2 迁移后魔数校验曾只认旧格式导致同步卡死。
    func testDownloadRejectsNonV2Content() async throws {
        let root = try tempRoot()
        let driver = ICloudDriver(databaseName: "Junk", cloudRoot: root)
        try await driver.testConnection()
        // 绕过上传路径直写垃圾内容,模拟半截下载的残体
        try Data("not-a-container-with-enough-bytes".utf8).write(
            to: root.appendingPathComponent("UPasswords/Junk.upw"))
        do {
            _ = try await driver.download()
            XCTFail("non-v2 content must be rejected")
        } catch {
            XCTAssertEqual(error as? SyncError, .notDownloaded)
        }
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
        try await driver.upload(try DatabaseCipher.encryptBody(Data([1, 2, 3]),
                                                               vaultKey: DatabaseCipher.generateVaultKey()))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("UPasswords/Layout.upw").path))
    }

    /// 覆盖上传后读取到的是新内容(原子替换语义)。
    func testUploadReplacesPreviousContent() async throws {
        let root = try tempRoot()
        let driver = ICloudDriver(databaseName: "Replace", cloudRoot: root)
        try await driver.testConnection()
        // 驱动对读取内容做 v2 魔数校验,测试载荷须为真实容器
        try await driver.upload(try DatabaseCipher.encryptBody(Data("old".utf8),
                                                               vaultKey: DatabaseCipher.generateVaultKey()))
        let newer = try DatabaseCipher.encryptBody(Data("new-and-longer".utf8),
                                                   vaultKey: DatabaseCipher.generateVaultKey())
        try await driver.upload(newer)
        let downloaded = try await driver.download()
        XCTAssertEqual(downloaded, newer)
    }

    /// 信封往返;只有占位符(未物化)时必须抛错而不是静默返回 nil——
    /// 回归:新装设备上信封未下载时返回 nil,恢复流程误判「远端无信封」失败。
    func testKeyRoundTripAndPlaceholder() async throws {
        let root = try tempRoot()
        let driver = ICloudDriver(databaseName: "Keyed", cloudRoot: root)
        try await driver.testConnection()
        // 无信封也无占位符 → nil(远端确实没有)
        let noKey = try await driver.downloadKey()
        XCTAssertNil(noKey)
        // 上传后原样读回
        let envelope = try DatabaseCipher.wrapVaultKey(DatabaseCipher.generateVaultKey(), password: "pw")
        try await driver.uploadKey(envelope)
        let fetched = try await driver.downloadKey()
        XCTAssertEqual(fetched, envelope)
        // 只有占位符:抛错(本地假根下物化不会发生,读取失败即符合预期)
        let datalessDriver = ICloudDriver(databaseName: "Dataless", cloudRoot: root)
        try Data("placeholder".utf8).write(
            to: root.appendingPathComponent("UPasswords/.Dataless.upwkey.icloud"))
        do {
            _ = try await datalessDriver.downloadKey()
            XCTFail("dataless placeholder envelope must throw, not silently return nil")
        } catch { /* 符合预期:物化失败即抛错 */ }
    }

    /// CloudDocs 根缺失按沙盒与否映射不同错误:沙盒引导选文件夹授权，
    /// 非沙盒(目录缺失多为 iCloud Drive 未开启)沿用「登录/开启」提示。
    func testMissingCloudDocsRootErrorMapping() {
        XCTAssertEqual(ICloudDriver.missingCloudDocsRootError(sandboxed: true),
                       SyncError.icloudFolderInaccessible)
        XCTAssertEqual(ICloudDriver.missingCloudDocsRootError(sandboxed: false),
                       SyncError.icloudUnavailable)
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
