import XCTest
@testable import UPasswordsCore

final class TOTPTests: XCTestCase {
    // RFC 6238 Appendix B vectors — SHA1, 8 digits, 30s period.
    private let vectors: [(time: TimeInterval, expected: String)] = [
        (59, "94287082"),
        (1111111109, "07081804"),
        (1111111111, "14050471"),
        (1234567890, "89005924"),
        (2000000000, "69279037"),
        (20000000000, "65353130"),
    ]

    private let secretBase32 = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ" // "12345678901234567890"

    func testRFC6238Vectors() throws {
        var cfg = try TOTP.parse(secretBase32)
        cfg.digits = 8
        for v in vectors {
            let code = try TOTP.code(config: cfg, at: Date(timeIntervalSince1970: v.time))
            XCTAssertEqual(code, v.expected, "at T=\(v.time)")
        }
    }

    func testOtpauthURIParsing() throws {
        let uri = "otpauth://totp/Example:alice?secret=JBSWY3DPEHPK3PXP&issuer=Example&digits=6&period=30&algorithm=SHA1"
        let cfg = try TOTP.parse(uri)
        XCTAssertEqual(cfg.issuer, "Example")
        XCTAssertEqual(cfg.digits, 6)
        XCTAssertEqual(cfg.period, 30)
        XCTAssertEqual(cfg.secret, [0x48, 0x65, 0x6c, 0x6c, 0x6f, 0x21, 0xde, 0xad, 0xbe, 0xef])
        XCTAssertEqual(try TOTP.hotp(config: cfg, counter: 0).count, 6)
    }

    func testBase32DecodePaddingFree() throws {
        let expected: [UInt8] = Array("Hello".utf8)
        XCTAssertEqual(try TOTP.base32Decode("JBSWY3DP"), expected)
        XCTAssertThrowsError(try TOTP.parse(""))
    }

    func testRemainingSeconds() {
        let t = Date(timeIntervalSince1970: 100) // 100 % 30 == 10
        XCTAssertEqual(TOTP.remainingSeconds(period: 30, at: t), 20)
    }
}
