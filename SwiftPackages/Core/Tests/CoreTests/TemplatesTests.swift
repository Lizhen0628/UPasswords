import XCTest
@testable import UPasswordsCore

final class TemplatesTests: XCTestCase {
    func testTemplateCatalog() {
        XCTAssertEqual(Templates.all.count, 16)
        let ids = Set(Templates.all.map(\.id))
        XCTAssertEqual(ids, Set([101, 102, 103, 104, 100, 105, 106, 107, 108, 109, 110, 111, 112, 113, 120, 114]))
    }

    func testMakeCardInstantiatesFields() {
        let spec = Templates.spec(id: 102)!
        let card = Templates.makeCard(from: spec, id: 500)
        XCTAssertFalse(card.template)
        XCTAssertFalse(card.title.isEmpty)
        XCTAssertEqual(card.fields.count, 4)
        XCTAssertEqual(card.fields[0].autofill, .username)
    }

    func testBankTemplateFieldSequence() {
        let bank = Templates.spec(id: 108)!
        XCTAssertEqual(bank.fields.map(\.type), [.text, .text, .number, .text, .text, .text, .phone, .login, .password, .website])
    }
}
