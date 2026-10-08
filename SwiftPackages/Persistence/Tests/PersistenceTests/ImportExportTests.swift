import XCTest
import UPasswordsCore
@testable import UPasswordsPersistence

final class CSVTests: XCTestCase {
    func testBasicParsing() {
        let rows = CSV.rows("a,b,c\n\"x,1\",\"y\"\"2\",z\n")
        XCTAssertEqual(rows, [["a", "b", "c"], ["x,1", "y\"2", "z"]])
    }

    func testEscaping() {
        XCTAssertEqual(CSV.escape("he said \"hi\", ok"), "\"he said \"\"hi\"\", ok\"")
    }
}

final class ImportTests: XCTestCase {
    private func parse(_ format: any ImportFormat, _ text: String) throws -> (PasswordDatabase, Int) {
        var db = PasswordDatabase()
        let n = try format.parse(text, into: &db, now: Date(timeIntervalSince1970: 0))
        return (db, n)
    }

    func testChromeCSV() throws {
        let csv = "name,url,username,password\nGitHub,https://github.com,octocat,cat123\n"
        let (db, n) = try parse(ImportFormatFactory.format(id: "chrome-chrome")!, csv)
        XCTAssertEqual(n, 1)
        let card = db.cards[0]
        XCTAssertEqual(card.title, "GitHub")
        XCTAssertEqual(card.login, "octocat")
        XCTAssertEqual(card.password, "cat123")
        XCTAssertEqual(card.website, "https://github.com")
    }

    func testLastPassCSV() throws {
        let csv = "url,username,password,extra,note,name\nhttps://x.com,u,p,extra1,,X\n,,,,,\n"
        let (db, n) = try parse(ImportFormatFactory.format(id: "lastpass")!, csv)
        XCTAssertEqual(n, 1)
        XCTAssertEqual(db.cards[0].notes, "extra1")
    }

    func testBitwardenJSON() throws {
        let json = """
        {"encrypted":false,"folders":[{"id":"f1","name":"Work"}],
         "items":[{"id":"1","folderId":"f1","name":"Vaultwarden","login":{"username":"u","password":"p","totp":"JBSWY3DP","uris":[{"uri":"https://vw.com"}]},"notes":"n"}]}
        """
        let (db, n) = try parse(ImportFormatFactory.format(id: "bitwarden-json")!, json)
        XCTAssertEqual(n, 1)
        let card = db.cards[0]
        XCTAssertEqual(card.title, "Vaultwarden")
        XCTAssertEqual(card.fields.filter { $0.type == .oneTimePassword }.count, 1)
        XCTAssertEqual(card.labelIds, [db.labels.first { $0.name == "Work" }!.id])
    }

    func testSafeInCloudXMLImportSkipsExistingTitles() throws {
        var db = PasswordDatabase.createDefault()
        let xml = """
        <database>
          <card title="Brand new" id="1" modified="100">
            <field name="Login" type="login">u</field>
          </card>
        </database>
        """
        let f = ImportFormatFactory.format(id: "safeincloud-xml")!
        let n = try f.parse(xml, into: &db, now: Date())
        XCTAssertEqual(n, 1)
        XCTAssertEqual(db.cards.first { $0.title == "Brand new" }?.fields.first?.value, "u")
        // importing again imports nothing new (title already present)
        let n2 = try f.parse(xml, into: &db, now: Date())
        XCTAssertEqual(n2, 0)
    }

    func testGenericCSV() throws {
        let csv = "title,username,password\nA,u1,p1\nB,u2,p2\n"
        let (db, n) = try parse(ImportFormatFactory.format(id: "csv")!, csv)
        XCTAssertEqual(n, 2)
        XCTAssertEqual(db.cards.map(\.title), ["A", "B"])
    }

    func testCanParseDetection() {
        XCTAssertTrue(ImportFormatFactory.format(id: "chrome-chrome")!.canParse("name,username,password\na,b,c"))
        XCTAssertFalse(ImportFormatFactory.format(id: "lastpass")!.canParse("gibberish"))
    }
}

final class ExportTests: XCTestCase {
    func testCSVExport() {
        var card = Card(id: 1)
        card.title = "T,\"q\""
        card.fields = [Field(name: "l", type: .login, value: "u", autofill: .username)]
        let out = ExportCardsTask.export([card], labels: [], format: .csv)
        XCTAssertEqual(out.components(separatedBy: "\n").count, 2)
        XCTAssertTrue(out.contains("\"T,\"\"q\"\"\""))
    }

    func testXMLExportReimportable() throws {
        var db = PasswordDatabase.createDefault()
        var card = Card(id: 500)
        card.title = "Exported"
        card.fields = [Field(name: "Login", type: .login, value: "u", autofill: .username)]
        db.cards.append(card)
        let xml = ExportCardsTask.export(db.cards.filter { !$0.template }, labels: db.labels, format: .xml)
        let back = try PasswordDatabase.parse(Data(xml.utf8))
        XCTAssertEqual(back.card(id: 500)?.login, "u")
    }

    func testTXTExport() {
        var card = Card(id: 1)
        card.title = "Note card"
        card.notes = "body"
        let out = ExportCardsTask.export([card], labels: [], format: .txt)
        XCTAssertTrue(out.contains("Note card"))
        XCTAssertTrue(out.contains("body"))
    }
}
