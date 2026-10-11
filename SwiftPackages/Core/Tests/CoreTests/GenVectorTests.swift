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
        try out.write(to: URL(fileURLWithPath: "/Users/lizhen/Projects/UPasswords/WebExtensions/shared/test/fixtures/vault-vector.json"))
        XCTAssertTrue(out.count > 200)
    }
}
