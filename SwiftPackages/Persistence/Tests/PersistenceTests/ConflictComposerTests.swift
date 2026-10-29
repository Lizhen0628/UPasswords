import XCTest

import UPasswordsCore
@testable import UPasswordsPersistence

final class ConflictComposerTests: XCTestCase {
    private let itemID = ConflictComposerTests.fixtureUUID(
        "123e4567-e89b-12d3-a456-426614174000")
    private let loginID = ConflictComposerTests.fixtureUUID(
        "223e4567-e89b-12d3-a456-426614174000")
    private let passwordID = ConflictComposerTests.fixtureUUID(
        "323e4567-e89b-12d3-a456-426614174000")
    private let candidateA = String(repeating: "a", count: 32)
    private let candidateB = String(repeating: "b", count: 32)

    func testComposesFieldsAndNotesFromExplicitCandidateSelections() throws {
        let a = card(
            title: "Base metadata",
            login: "login A",
            password: "password A",
            notes: "notes A")
        let b = card(
            title: "Other metadata",
            login: "login B",
            password: "password B",
            notes: "notes B")
        let candidates = [
            ConflictComposer.Candidate(candidateID: candidateA, item: .card(a)),
            ConflictComposer.Candidate(candidateID: candidateB, item: .card(b)),
        ]
        let groups = try XCTUnwrap(ConflictComposer.fieldGroups(for: candidates))
        XCTAssertEqual(groups.count, 2)
        XCTAssertTrue(groups.allSatisfy(\.requiresChoice))
        XCTAssertNil(groups[0].defaultCandidateID)

        let composed = try XCTUnwrap(ConflictComposer.compose(
            baseCandidateID: candidateA,
            candidates: candidates,
            fieldSelections: [loginID: candidateB, passwordID: candidateA],
            notesCandidateID: candidateA))
        guard case .card(let result) = composed else {
            return XCTFail("Expected composed card")
        }
        XCTAssertEqual(result.title, "Base metadata")
        XCTAssertEqual(result.fields.first { $0.id == loginID }?.value, "login B")
        XCTAssertEqual(result.fields.first { $0.id == passwordID }?.value, "password A")
        XCTAssertEqual(result.notes, "notes A")
        XCTAssertGreaterThan(result.modified, a.modified)
    }

    func testFieldDeletionIsAnExplicitCandidateOption() throws {
        let a = card(title: "A", login: "present", password: "", notes: "")
        let b = card(title: "B", login: nil, password: "", notes: "")
        let candidates = [
            ConflictComposer.Candidate(candidateID: candidateA, item: .card(a)),
            ConflictComposer.Candidate(candidateID: candidateB, item: .card(b)),
        ]
        let group = try XCTUnwrap(ConflictComposer.fieldGroups(for: candidates)?.first)
        XCTAssertTrue(group.requiresChoice)
        XCTAssertTrue(group.options.contains { $0.candidateID == candidateB && $0.field == nil })

        let composed = try XCTUnwrap(ConflictComposer.compose(
            baseCandidateID: candidateA,
            candidates: candidates,
            fieldSelections: [loginID: candidateB]))
        guard case .card(let result) = composed else {
            return XCTFail("Expected composed card")
        }
        XCTAssertFalse(result.fields.contains { $0.id == loginID })
    }

    func testChangedNotesRequireAnExplicitSelection() {
        let candidates = [
            ConflictComposer.Candidate(
                candidateID: candidateA,
                item: .card(card(title: "A", login: "", password: "", notes: "one"))),
            ConflictComposer.Candidate(
                candidateID: candidateB,
                item: .card(card(title: "B", login: "", password: "", notes: "two"))),
        ]
        XCTAssertNil(ConflictComposer.compose(
            baseCandidateID: candidateA,
            candidates: candidates,
            fieldSelections: [:]))
    }

    func testIdenticalFieldsNeedNoSelectionAndPreserveBaseOrder() throws {
        let firstID = Self.fixtureUUID("423e4567-e89b-12d3-a456-426614174000")
        let a = card(title: "A", login: "same", password: "", notes: "same")
        var b = card(title: "B", login: "same", password: "", notes: "same")
        b.fields[0].id = firstID
        var adjustedA = a
        adjustedA.fields[0].id = firstID
        let candidates = [
            ConflictComposer.Candidate(candidateID: candidateA, item: .card(adjustedA)),
            ConflictComposer.Candidate(candidateID: candidateB, item: .card(b)),
        ]

        let group = try XCTUnwrap(ConflictComposer.fieldGroups(for: candidates)?.first)
        XCTAssertFalse(group.requiresChoice)
        XCTAssertEqual(group.defaultCandidateID, candidateA)
        let composed = try XCTUnwrap(ConflictComposer.compose(
            baseCandidateID: candidateB,
            candidates: candidates,
            fieldSelections: [:]))
        guard case .card(let result) = composed else {
            return XCTFail("Expected composed card")
        }
        XCTAssertEqual(result.fields.map(\.id), [firstID, passwordID])
    }

    func testRejectsUnreliableFieldsAndAttachmentCandidates() throws {
        let legacy = try PasswordDatabase.parse(Data("""
        <database><card id="\(itemID.uuidString)"><field name="legacy">value</field></card></database>
        """.utf8)).cards[0]
        XCTAssertFalse(ConflictComposer.isComposable([
            ConflictComposer.Candidate(candidateID: candidateA, item: .card(legacy)),
            ConflictComposer.Candidate(candidateID: candidateB, item: .card(legacy)),
        ]))

        var attached = card(title: "Attached", login: "", password: "", notes: "")
        attached.files = [Attachment(name: "key.bin", data: Data([1, 2, 3]))]
        XCTAssertFalse(ConflictComposer.isComposable([
            ConflictComposer.Candidate(candidateID: candidateA, item: .card(attached)),
            ConflictComposer.Candidate(candidateID: candidateB, item: .card(attached)),
        ]))
    }

    private func card(title: String, login: String?, password: String, notes: String) -> Card {
        var card = Card(id: itemID, title: title)
        if let login {
            card.fields.append(Field(id: loginID, name: "Login", type: .login, value: login))
        }
        card.fields.append(Field(id: passwordID, name: "Password", type: .password, value: password))
        card.notes = notes
        return card
    }

    private static func fixtureUUID(_ value: String) -> UUID {
        guard let uuid = UUID(uuidString: value) else {
            preconditionFailure("Invalid UUID test fixture: \(value)")
        }
        return uuid
    }
}
