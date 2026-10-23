import XCTest
@testable import UPasswordsCore

final class FieldTypeTests: XCTestCase {
    func testTypeSet() {
        XCTAssertEqual(FieldType.allCases.count, 12)
        XCTAssertEqual(Autofill.allCases.count, 20)
        let personalInfoTokens: Set<String> = [
            "given-name", "family-name", "email", "tel", "street-address",
            "address-line1", "address-line2", "address-level1", "address-level2",
            "postal-code", "country-name",
        ]
        XCTAssertTrue(personalInfoTokens.isSubset(of: Set(Autofill.allCases.map(\.rawValue))))
        XCTAssertTrue(FieldType.password.isHidden)
        XCTAssertTrue(FieldType.oneTimePassword.isHidden)
        XCTAssertFalse(FieldType.login.isHidden)
        XCTAssertTrue(FieldType.login.isLogin)
        XCTAssertTrue(FieldType.password.needsScoring)
    }

    func testHistoryPut() {
        var f = Field(name: "pw", type: .password)
        f.putHistoryValue("v1", time: 1)
        f.value = "v2"
        f.putHistoryValue("v1", time: 2)
        XCTAssertEqual(f.history.count, 1)
        XCTAssertEqual(f.history[0].time, 2, "re-put refreshes time")
    }
}
