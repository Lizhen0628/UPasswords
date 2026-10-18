import XCTest
import CryptoKit

@testable import UPasswordsCore
@testable import UPasswordsPersistence

/// 行级条目密文的跨端向量:Swift RowSyncCipher(AES-GCM,AAD=uuid)加密
/// 一个 card 片段,落盘供 WebExtensions/shared/test 的 TS 侧解密对齐。
/// uuid 写入服务端归一化形态(小写)——TS 解密须还原大写作 AAD。
final class ItemVectorTests: XCTestCase {
    func testGenerateRowSyncItemVector() throws {
        var github = Card(title: "GitHub")
        github.fields = [
            Field(name: "用户名", type: .login, value: "octocat"),
            Field(name: "密码", type: .password, value: "hunter2-example"),
            Field(name: "网址", type: .website, value: "github.com"),
        ]
        let fragment = String(data: DatabaseItemCodec.xmlData(.card(github)), encoding: .utf8)!
        let vek = DatabaseCipher.generateVaultKey()
        let key = RowSyncKey(raw: vek.withUnsafeBytes { Data($0) })
        let sealed = try RowSyncCipher.encrypt(Data(fragment.utf8), key: key, uuid: github.id)

        let json: [String: Any] = [
            "uuid": github.id.uuidString.lowercased(),
            "fragment": fragment,
            "body": sealed.base64EncodedString(),
            "vek": vek.withUnsafeBytes { Data($0) }.base64EncodedString(),
        ]
        let out = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        // 路径从 #filePath 推导仓库根,任何 checkout(含 CI)都能重新生成。
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/PersistenceTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // Persistence
            .deletingLastPathComponent()  // SwiftPackages
            .deletingLastPathComponent()  // 仓库根
        let fixture = repoRoot
            .appendingPathComponent("WebExtensions/shared/test/fixtures/item-vector.json")
        try out.write(to: fixture)
        XCTAssertGreaterThan(out.count, 200)
    }
}
