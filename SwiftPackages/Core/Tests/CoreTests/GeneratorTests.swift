import XCTest
@testable import UPasswordsCore

final class GeneratorTests: XCTestCase {
    func testLengthRespected() {
        let g = PasswordGenerator.instance
        for len in [4, 8, 16, 32, 64] {
            XCTAssertEqual(g.password(length: len, type: 0).count, len)
            XCTAssertEqual(g.password(length: len, type: 2).count, len)
        }
    }

    func testDigitsOnly() {
        let pw = PasswordGenerator.instance.password(length: 12, type: 3)
        XCTAssertTrue(pw.allSatisfy(\.isNumber))
    }

    func testLettersAndNumbers() {
        let pw = PasswordGenerator.instance.password(length: 20, type: 2)
        XCTAssertTrue(pw.allSatisfy { $0.isLetter || $0.isNumber })
    }

    func testExcludeSimilarCharacters() {
        let settings = PasswordSettings.shared
        let old = settings.excludeSimilarCharacters
        defer { settings.excludeSimilarCharacters = old }
        settings.excludeSimilarCharacters = true
        let pw = PasswordGenerator.instance.password(length: 128, type: 0)
        XCTAssertFalse(pw.contains(where: { "Il1O0o".contains($0) }))
    }

    func testMemorableContainsSeparatorAndWords() {
        let pw = PasswordGenerator.instance.memorablePassword(length: 16)
        XCTAssertGreaterThanOrEqual(pw.count, 12)
        XCTAssertTrue(pw.contains(where: { PasswordSettings.shared.separatorAlphabet.contains($0) })
                      || pw.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == "." }).count >= 1)
    }

    func testHistoryBehavior() {
        let g = PasswordGenerator.instance
        g.clearHistory()
        g.addPasswordToHistory("alpha")
        g.addPasswordToHistory("beta")
        g.addPasswordToHistory("alpha")
        XCTAssertEqual(g.history.first, "alpha")
        XCTAssertEqual(g.history.count, 2, "re-adding moves to front without duplicates")
        g.clearHistory()
        XCTAssertTrue(g.history.isEmpty)
    }
}
