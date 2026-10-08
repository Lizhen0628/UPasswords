import XCTest
@testable import UPasswordsCore

final class StrengthTests: XCTestCase {
    func testCommonPasswordsScoreZero() {
        for pw in ["123456", "password", "qwerty", "letmein", "P@ssw0rd"] {
            XCTAssertLessThanOrEqual(PasswordStrength.score(pw).score, 1, "'\(pw)' must be weak")
        }
    }

    func testShortPasswordsWeak() {
        XCTAssertLessThanOrEqual(PasswordStrength.score("a1").score, 1)
    }

    func testRandomLongPasswordsStrong() {
        for pw in ["7hZ!q2#LmV@9pQx&", "f4T8_wR6kU2nB9dZ"] {
            XCTAssertGreaterThanOrEqual(PasswordStrength.score(pw).score, 3, "'\(pw)'")
        }
    }

    func testScoreMonotonicByLength() {
        let short = PasswordStrength.bruteEntropy("abc123")
        let long = PasswordStrength.bruteEntropy("abc123abc123abc123abc123")
        XCTAssertLessThan(short, long)
    }

    func testCrackTimeText() {
        XCTAssertEqual(PasswordStrength.crackTime(seconds: 0.5), L10n.t("instant_text"))
        XCTAssertEqual(PasswordStrength.crackTime(seconds: 30).hasSuffix("s"), true)
        XCTAssertFalse(PasswordStrength.crackTime(seconds: 1e30).isEmpty)
    }

    func testCardWeakDetection() {
        var card = Card(id: 1)
        card.fields = [Field(name: "pw", type: .password, value: "123456")]
        XCTAssertTrue(card.hasWeakPasswords)
        card.fields[0].value = "9uH&2mQ!vXz#7LpR"
        XCTAssertFalse(card.hasWeakPasswords)
    }
}
