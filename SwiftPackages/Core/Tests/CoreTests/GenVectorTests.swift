import XCTest
import UPasswordsCore
import CryptoKit

final class GenVectorTests: XCTestCase {
    func testGenerateCrossPlatformVector() throws {
        var db = PasswordDatabase()
        db.labels.append(CardLabel(id: 1, name: "工作"))
        var github = Card(id: 7, title: "GitHub")
        github.fields = [
            Field(name: "用户名", type: .login, value: "octocat"),
            Field(name: "密码", type: .password, value: "hunter2-example"),
            Field(name: "网址", type: .website, value: "github.com"),
        ]
        github.labelIds = [1]
        db.cards.append(github)
        var bank = Card(id: 8, title: "Bank")
        bank.fields = [
            Field(name: "login", type: .login, value: "alice"),
            Field(name: "pin", type: .pin, value: "4321"),
        ]
        bank.trashed = true
        db.cards.append(bank)

        let password = "correct horse battery staple"
        let vek = DatabaseCipher.generateVaultKey()
        let envelope = try DatabaseCipher.wrapVaultKey(vek, password: password)
        let body = try DatabaseCipher.encryptBody(db.xmlData(), vaultKey: vek)
        let vekRaw = vek.withUnsafeBytes { Data($0) }.base64EncodedString()

        let json: [String: Any] = [
            "password": password,
            "envelope": envelope.base64EncodedString(),
            "body": body.base64EncodedString(),
            "vek": vekRaw,
            "cardCount": 2,
        ]
        let out = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        // 向量供 WebExtensions/shared/test/vault-crypto.test.mjs 跨端解密对齐;
        // 路径从 #filePath 推导仓库根,任何 checkout(含 CI)都能重新生成。
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/CoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // Core
            .deletingLastPathComponent()  // SwiftPackages
            .deletingLastPathComponent()  // 仓库根
        let fixture = repoRoot
            .appendingPathComponent("WebExtensions/shared/test/fixtures/vault-vector.json")
        try out.write(to: fixture)
        XCTAssertTrue(out.count > 200)
    }
}
