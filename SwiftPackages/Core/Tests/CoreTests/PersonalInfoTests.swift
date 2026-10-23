import XCTest
@testable import UPasswordsCore

final class PersonalInfoTests: XCTestCase {
    func testEmptyDraftDoesNotCreateProfile() {
        var draft = PersonalInfoDraft()
        draft.email = "  "
        XCTAssertNil(draft.makeProfile(autofillEnabled: true))
    }

    func testContactFieldsAndDisabledPreferenceSurviveXMLRoundTrip() throws {
        var draft = PersonalInfoDraft()
        draft.givenName = " Taylor "
        draft.email = " test@example.com "
        draft.phone = "5550100"
        draft.addressLine1 = "1 Main Street"
        draft.postalCode = "00100"
        let profile = try XCTUnwrap(draft.makeProfile(autofillEnabled: false))
        var database = PasswordDatabase()
        database.userProfiles = [profile]
        let parsed = try PasswordDatabase.parse(database.xmlData())
        let saved = try XCTUnwrap(parsed.userProfiles.first)
        XCTAssertFalse(saved.registrationAutofillEnabled)
        XCTAssertEqual(saved.fields.map(\.autofill), [.givenName, .email, .telephone, .addressLine1, .postalCode])
        XCTAssertEqual(saved.fields.map(\.type), [.text, .email, .phone, .text, .text])
        XCTAssertEqual(saved.fields.map(\.value), ["Taylor", "test@example.com", "5550100", "1 Main Street", "00100"])
        XCTAssertTrue(parsed.cards.isEmpty)
        XCTAssertEqual(PersonalInfoDraft(profile: saved).postalCode, "00100")
    }

    func testLegacyCardMigrationRetainsIdentityAndIsIdempotent() throws {
        var card = Card(title: "Profile")
        card.symbol = "person.text.rectangle.fill"
        card.fields = [Field(name: "Email", type: .email, value: "test@example.com", autofill: .email)]
        card.autofillEnabled = false
        card.modified = 100
        var database = PasswordDatabase()
        database.cards = [card]
        XCTAssertEqual(database.migrateLegacyPersonalInfo(), 1)
        XCTAssertTrue(database.cards.isEmpty)
        let profile = try XCTUnwrap(database.userProfiles.first)
        XCTAssertEqual(profile.id, card.id)
        XCTAssertEqual(profile.fields, card.fields)
        XCTAssertFalse(profile.registrationAutofillEnabled)
        XCTAssertGreaterThan(profile.modified, card.modified)
        XCTAssertEqual(database.migrateLegacyPersonalInfo(), 0)
        let encoded = DatabaseItemCodec.xmlData(.userProfile(profile))
        let decoded = try XCTUnwrap(DatabaseItemCodec.parse(kind: 3, uuid: profile.id, data: encoded))
        XCTAssertEqual(decoded.uuid, profile.id)
        XCTAssertEqual(decoded.syncKind, 3)
        guard case .userProfile(let saved) = decoded else { return XCTFail("Expected profile") }
        XCTAssertEqual(saved.fields.map(\.value), profile.fields.map(\.value))
        XCTAssertEqual(saved.registrationAutofillEnabled, profile.registrationAutofillEnabled)
        XCTAssertNil(DatabaseItemCodec.parse(kind: 1, uuid: profile.id, data: encoded))
    }

    func testEditingRetainsIdentityAdditionalFieldsAndHistory() throws {
        var draft = PersonalInfoDraft()
        draft.email = "old@example.com"
        var previous = try XCTUnwrap(draft.makeProfile(autofillEnabled: true))
        let extra = Field(name: "Additional", type: .text, value: "Extra", autofill: .off)
        previous.fields[0].history = [HistoryEntry(value: "earlier@example.com", time: 100)]
        previous.fields.append(extra)
        previous.modified = Date().millis + 1000
        draft.email = "updated@example.com"
        let updated = try XCTUnwrap(draft.makeProfile(autofillEnabled: false, updating: previous))
        XCTAssertEqual(updated.id, previous.id)
        XCTAssertEqual(updated.created, previous.created)
        XCTAssertGreaterThan(updated.modified, previous.modified)
        XCTAssertEqual(updated.fields[0].id, previous.fields[0].id)
        XCTAssertEqual(updated.fields[0].value, "updated@example.com")
        XCTAssertEqual(updated.fields[0].history, previous.fields[0].history)
        XCTAssertEqual(updated.fields[1], extra)
        var database = PasswordDatabase()
        database.userProfiles = [updated]
        let parsed = try PasswordDatabase.parse(database.xmlData())
        XCTAssertEqual(parsed.userProfiles.first?.fields.first?.history, updated.fields[0].history)
    }

    func testDecodingLegacyJSONDefaultsToNoProfiles() throws {
        let data = Data(#"{"labels":[],"cards":[]}"#.utf8)
        let database = try JSONDecoder().decode(PasswordDatabase.self, from: data)
        XCTAssertTrue(database.userProfiles.isEmpty)
        XCTAssertEqual(try JSONDecoder().decode(PasswordDatabase.self, from: JSONEncoder().encode(database)), database)
    }
}
