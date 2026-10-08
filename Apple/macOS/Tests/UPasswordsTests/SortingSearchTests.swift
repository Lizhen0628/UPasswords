import XCTest
import UPasswordsCore
@testable import UPasswords

final class SortingAndSearchTests: XCTestCase {
    private func cards(_ specs: [(String, Bool, TimeInterval)]) -> [Card] {
        specs.enumerated().map { i, s in
            var c = Card(id: i)
            c.title = s.0
            c.favorite = s.1
            c.created = s.2
            return c
        }
    }

    func testTitleSortAndFavoritesFirst() {
        let input = cards([("b", false, 3), ("a", true, 2), ("c", false, 1)])
        let sorted = Sorting.titleAsc.sort(input, favoritesFirst: true)
        XCTAssertEqual(sorted.map(\.title), ["a", "b", "c"])
        let favTop = Sorting.titleDesc.sort(input, favoritesFirst: true)
        XCTAssertEqual(favTop.first?.title, "a")
    }

    func testCreatedSort() {
        let input = cards([("x", false, 30), ("y", false, 10), ("z", false, 20)])
        XCTAssertEqual(Sorting.createdAsc.sort(input, favoritesFirst: false).map(\.title), ["y", "z", "x"])
        XCTAssertEqual(Sorting.createdDesc.sort(input, favoritesFirst: false).map(\.title), ["x", "z", "y"])
    }

    func testSearchSatisfiesAllWords() {
        var card = Card(id: 1)
        card.title = "GitHub"
        card.fields = [Field(name: "login", type: .login, value: "octocat")]
        card.notes = "work account"
        func match(_ q: String) -> Bool {
            let words = q.lowercased().split(separator: " ").map(String.init)
            return words.allSatisfy { word in
                card.title.lowercased().contains(word)
                    || card.fields.contains { $0.value.lowercased().contains(word) }
                    || card.notes.lowercased().contains(word) }
        }
        XCTAssertTrue(match("git octo"))
        XCTAssertFalse(match("git slack"))
    }
}
