import XCTest
@testable import UPasswords

final class BreachListTests: XCTestCase {

    override func tearDown() {
        // 清理测试写入的 UserDefaults(测试进程与 App 的 defaults 域相互独立)
        UserDefaults.standard.removeObject(forKey: CompromisedService.dynamicHashesKey)
        super.tearDown()
    }

    /// SHA-1 已知向量(小写十六进制)。
    func testSha1HexKnownVector() {
        XCTAssertEqual(CompromisedService.sha1Hex("password"), "5baa61e4c9b93f3f0682250b6cf8331b7ee68fd8")
        XCTAssertEqual(CompromisedService.sha1Hex("123456"), "7c4a8d09ca3762af61e59520943dc26494f8941b")
    }

    /// 内嵌常见集直接命中。
    func testDemoSetHit() {
        XCTAssertTrue(CompromisedService.isLocallyBreached("123456"))
        XCTAssertTrue(CompromisedService.isLocallyBreached("qwerty"))
    }

    /// CRLF 响应解析回归:\r\n 是单个图形簇,按 "\n" 切分会整体失效
    /// (曾导致所有密码误报"未泄露")。
    func testParseSuffixesHandlesCRLF() {
        let body = "003C1587D5E9892AD2AE161B1B68C05BE85:3\r\n613BAF827B143068BDA59F58A92AD25EEEC:564\r\n"
        let suffixes = CompromisedService.parseSuffixes(body)
        XCTAssertEqual(suffixes.count, 2)
        XCTAssertTrue(suffixes.contains("613BAF827B143068BDA59F58A92AD25EEEC"))
    }

    /// 裸 LF 与空行容错。
    func testParseSuffixesHandlesLFAndEmptyLines() {
        let body = "\nAAAA:1\n\nBBBB:2\n"
        let suffixes = CompromisedService.parseSuffixes(body)
        XCTAssertEqual(suffixes, ["AAAA", "BBBB"])
    }

    /// 在线命中记录后进入本地清单(只存 SHA-1),isLocallyBreached 立即可判。
    func testRecordBreachedAddsToDynamicList() {
        let unique = "upw-breach-test-\(UUID().uuidString)"
        XCTAssertFalse(CompromisedService.isLocallyBreached(unique))
        CompromisedService.recordBreached([unique])
        XCTAssertTrue(CompromisedService.isLocallyBreached(unique))
        // 落盘的是 SHA-1,不是明文(隐私红线)
        let stored = UserDefaults.standard.stringArray(forKey: CompromisedService.dynamicHashesKey) ?? []
        XCTAssertTrue(stored.contains(CompromisedService.sha1Hex(unique)))
        XCTAssertFalse(stored.contains(unique))
        // 重复记录幂等
        CompromisedService.recordBreached([unique])
        XCTAssertEqual((UserDefaults.standard.stringArray(forKey: CompromisedService.dynamicHashesKey) ?? []).count,
                       stored.count)
    }

    /// Card.compromised 依赖动态清单:记录前 false,记录后 true。
    func testCardCompromisedFlagUsesDynamicList() throws {
        let spec = try XCTUnwrap(Templates.spec(id: 102))
        var card = Templates.makeCard(from: spec, id: 999_001)
        let unique = "upw-card-breach-test-\(UUID().uuidString)"
        card.fields = card.fields.map { f in
            var f = f
            if f.type == .password { f.value = unique }
            return f
        }
        XCTAssertFalse(card.compromised)
        CompromisedService.recordBreached([unique])
        XCTAssertTrue(card.compromised)
    }
}
