import XCTest
@testable import UPasswordsCore

/// 本地化字符串表的结构性测试:重构后 lproj 表随 Core 包分发,
/// 双表键齐平与基础取词是跨包 UI 文案正确性的地基。
final class L10nParityTests: XCTestCase {
    private func tableKeys(table: String) throws -> Set<String> {
        let path = L10n.bundle.path(forResource: table, ofType: "strings")
        let url = try XCTUnwrap(path, "\(table).strings missing from bundle")
        let dict = try XCTUnwrap(NSDictionary(contentsOfFile: url) as? [String: String])
        return Set(dict.keys)
    }

    /// en 与 zh-Hans 的键集合必须一致(规范 14.3:禁止单边加键)。
    func testLocalizableKeyParity() throws {
        let en = try tableKeys(table: "en.lproj/Localizable")
        let zh = try tableKeys(table: "zh-Hans.lproj/Localizable")
        XCTAssertTrue(en.intersection(zh).count > 50, "smoke: table should be substantial")
        XCTAssertEqual(en.subtracting(zh).sorted(), [], "keys only in en.lproj")
        XCTAssertEqual(zh.subtracting(en).sorted(), [], "keys only in zh-Hans.lproj")
    }

    func testDatabaseTableKeyParity() throws {
        let en = try tableKeys(table: "en.lproj/Database")
        let zh = try tableKeys(table: "zh-Hans.lproj/Database")
        XCTAssertTrue(en.intersection(zh).count > 20, "smoke: table should be substantial")
        XCTAssertEqual(en.subtracting(zh).sorted(), [], "keys only in en.lproj/Database")
        XCTAssertEqual(zh.subtracting(en).sorted(), [], "keys only in zh-Hans.lproj/Database")
    }

    /// 基础取词:已知键返回非空且不回显键名本身。
    func testKnownLookups() {
        XCTAssertEqual(L10n.t("app_title"), "UPasswords")
        XCTAssertNotEqual(L10n.db("login_type"), "login_type", "db() must resolve, not echo the key")
        XCTAssertEqual(L10n.t("definitely_missing_key_xyz", fallback: "FB"), "FB")
    }

    /// 模板字符串引用解析(@string/ 前缀)。
    func testResolveStringReference() {
        XCTAssertEqual(L10n.resolve("@string/login_type"), L10n.db("login_type"))
        XCTAssertEqual(L10n.resolve("plain text"), "plain text")
    }
}
