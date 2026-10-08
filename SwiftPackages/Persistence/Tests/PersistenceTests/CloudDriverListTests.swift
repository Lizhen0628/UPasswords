import XCTest
@testable import UPasswordsPersistence

final class CloudDriverListTests: XCTestCase {

    /// PROPFIND multistatus 解析:相对路径、完整 URL、百分号编码均提取;
    /// 目录项与非 .upw 文件忽略。
    func testWebDavPropfindParsing() {
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>/UPasswords/</D:href>
            <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat>
          </D:response>
          <D:response>
            <D:href>/UPasswords/Main.upw</D:href>
          </D:response>
          <D:response>
            <D:href>https://dav.example.com/UPasswords/My%20DB.upw</D:href>
          </D:response>
          <d:response>
            <d:href>/other/Folder/note.txt</d:href>
          </d:response>
        </D:multistatus>
        """
        XCTAssertEqual(WebDavDriver.databaseNames(propfindBody: body), ["Main", "My DB"])
    }

    /// 无匹配时返回空数组(容错:正文为空或结构异常不抛错)。
    func testWebDavPropfindParsingEmpty() {
        XCTAssertEqual(WebDavDriver.databaseNames(propfindBody: ""), [])
        XCTAssertEqual(WebDavDriver.databaseNames(propfindBody: "<html>not xml</html>"), [])
    }

    /// iCloud 目录枚举:.upw 与未下载占位 .upw.icloud 计入,其他文件/目录忽略。
    func testICloudListDatabases() async throws {
        let root = try tempRoot()
        let folder = root.appendingPathComponent("UPasswords", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([1]).write(to: folder.appendingPathComponent("Alpha.upw"))
        try Data([2]).write(to: folder.appendingPathComponent("Beta.upw.icloud"))
        try Data([3]).write(to: folder.appendingPathComponent("note.txt"))

        let driver = ICloudDriver(databaseName: "Alpha", cloudRoot: root)
        let names = try await driver.listDatabases()
        XCTAssertEqual(names, ["Alpha", "Beta"])
    }

    /// 容器目录不存在时返回空数组(新装 iCloud 云盘尚未同步)。
    func testICloudListDatabasesMissingFolder() async throws {
        let root = try tempRoot()
        let driver = ICloudDriver(databaseName: "Any", cloudRoot: root)
        let names = try await driver.listDatabases()
        XCTAssertTrue(names.isEmpty)
    }

    // MARK: - 夹具

    /// 独立临时目录充当 iCloud 云盘根;测试结束自动清理。
    private func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("upw-cloudlist-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }
}
