import XCTest
@testable import UPasswords

final class CipherTests: XCTestCase {
    func testRoundTrip() throws {
        let plain = Data("<?xml version=\"1.0\"?><database><card title=\"卡\" id=\"1\"/></database>".utf8)
        let enc = try DatabaseCipher.encryptedData(plain, password: "s3cret!")
        XCTAssertGreaterThan(enc.count, plain.count)
        XCTAssertTrue(DatabaseCipher.checkFileMagic(enc))
        let dec = try DatabaseCipher.decryptedData(enc, password: "s3cret!")
        XCTAssertEqual(dec, plain)
    }

    func testWrongPasswordFails() throws {
        let enc = try DatabaseCipher.encryptedData(Data("hello".utf8), password: "right")
        XCTAssertThrowsError(try DatabaseCipher.decryptedData(enc, password: "wrong")) { error in
            XCTAssertTrue("\(error)".contains("密码错误") || "\(error)".contains("Wrong password"))
        }
    }

    func testMagicRejected() {
        XCTAssertFalse(DatabaseCipher.checkFileMagic(Data("not a database".utf8)))
        XCTAssertFalse(DatabaseCipher.checkFileMagic(Data()))
    }

    func testEncryptedOutputIsNonDeterministic() throws {
        let p = Data("payload".utf8)
        let a = try DatabaseCipher.encryptedData(p, password: "x")
        let b = try DatabaseCipher.encryptedData(p, password: "x")
        XCTAssertNotEqual(a, b, "random salt/nonce must make ciphertexts differ")
    }

    func testKeyDerivationDeterministic() {
        let salt = Data(repeating: 7, count: 16)
        let k1 = DatabaseCipher.deriveKey(password: "pw", salt: salt, iterations: 1000)
        let k2 = DatabaseCipher.deriveKey(password: "pw", salt: salt, iterations: 1000)
        XCTAssertEqual(k1.withUnsafeBytes { Data($0) }, k2.withUnsafeBytes { Data($0) })
        let k3 = DatabaseCipher.deriveKey(password: "pw2", salt: salt, iterations: 1000)
        XCTAssertNotEqual(k1.withUnsafeBytes { Data($0) }, k3.withUnsafeBytes { Data($0) })
    }
}

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

final class DatabaseXMLTests: XCTestCase {
    private func sampleDB() -> PasswordDatabase {
        var db = PasswordDatabase()
        db.labels = [
            CardLabel(id: 1, name: "商务", timeStamp: 1000),
            CardLabel(id: 2, name: "Private", color: "blue", timeStamp: 1001),
        ]
        var card = Card(id: 10)
        card.title = "Example Site"
        card.symbol = "web_site"
        card.color = "green"
        card.autofillEnabled = true
        card.favorite = true
        card.archived = false
        card.trashed = false
        card.expiration = 4102444800000
        card.created = 1690000000000
        card.modified = 1690000100000
        card.fields = [
            Field(name: "登录", type: .login, value: "user@example.com", autofill: .username),
            Field(name: "密码", type: .password, value: "hunter2", autofill: .currentPassword,
                  history: [HistoryEntry(value: "old1", time: 1680000000000)]),
            Field(name: "一次性代码", type: .oneTimePassword, value: "JBSWY3DPEHPK3PXP", autofill: .oneTimeCode),
        ]
        card.notes = "多行\n笔记"
        card.labelIds = [1, 2]
        card.images = [Attachment(name: "shot.png", data: Data([0x89, 0x50, 0x4E, 0x47]))]
        card.files = [Attachment(name: "key.txt", data: Data("secret file".utf8))]
        db.cards = [card]
        db.ghosts = [Ghost(id: 99, time: 1690000000000)]
        return db
    }

    func testRoundTrip() throws {
        let db = sampleDB()
        let xml = db.xmlData()
        let parsed = try PasswordDatabase.parse(xml)
        XCTAssertEqual(parsed.labels, db.labels)
        XCTAssertEqual(parsed.cards.count, 1)
        let c = parsed.cards[0]
        XCTAssertEqual(c.title, "Example Site")
        XCTAssertEqual(c.symbol, "web_site")
        XCTAssertEqual(c.favorite, true)
        XCTAssertEqual(c.autofillEnabled, true)
        XCTAssertEqual(c.expiration, 4102444800000)
        XCTAssertEqual(c.fields.count, 3)
        XCTAssertEqual(c.fields[1].value, "hunter2")
        XCTAssertEqual(c.fields[1].history.first?.value, "old1")
        XCTAssertEqual(c.fields[2].type, .oneTimePassword)
        XCTAssertEqual(c.notes, "多行\n笔记")
        XCTAssertEqual(c.labelIds, [1, 2])
        XCTAssertEqual(c.images.first?.data, Data([0x89, 0x50, 0x4E, 0x47]))
        XCTAssertEqual(c.files.first?.name, "key.txt")
        XCTAssertEqual(parsed.ghosts, [Ghost(id: 99, time: 1690000000000)])
    }

    func testParseOriginalTemplateFormat() throws {
        // Shape mirrors resources/templates-database.xml of Safe.app.
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <database>
            <label name="Business" id="1" />
            <card title="Credit card" id="101" symbol="credit_card" color="gray" template="true" autofill="on">
                <field name="Number" type="number" autofill="cc-number"/>
                <field name="CVV" type="pin" autofill="cc-csc"/>
            </card>
        </database>
        """
        let db = try PasswordDatabase.parse(Data(xml.utf8))
        XCTAssertEqual(db.labels.first?.name, "Business")
        let t = db.cards.first
        XCTAssertEqual(t?.isTemplate, true)
        XCTAssertEqual(t?.fields.map(\.type), [.number, .pin])
        XCTAssertEqual(t?.fields.map(\.autofill), [.ccNumber, .ccCsc])
    }

    func testUnknownFieldTypeSanitizedToText() throws {
        let xml = """
        <database><card title="x" id="1"><field name="a" type="hyperdrive" autofill="off">v</field></card></database>
        """
        let db = try PasswordDatabase.parse(Data(xml.utf8))
        XCTAssertEqual(db.cards[0].fields[0].type, .text)
    }

    func testXMLEscaping() throws {
        var db = PasswordDatabase()
        var c = Card(id: 1)
        c.title = "a<b>&\"'\">"
        db.cards = [c]
        let parsed = try PasswordDatabase.parse(db.xmlData())
        XCTAssertEqual(parsed.cards[0].title, "a<b>&\"'\">")
    }

    func testMalformedThrows() {
        XCTAssertThrowsError(try PasswordDatabase.parse(Data("<not-xml".utf8)))
    }

    func testMergeNewestWins() {
        var a = PasswordDatabase()
        var c1 = Card(id: 5); c1.title = "old"; c1.modified = 100
        a.cards = [c1]
        var b = PasswordDatabase()
        var c2 = Card(id: 5); c2.title = "new"; c2.modified = 200
        var c3 = Card(id: 6); c3.title = "added remotely"; c3.modified = 300
        b.cards = [c2, c3]
        a.merge(with: b)
        XCTAssertEqual(a.cards.count, 2)
        XCTAssertEqual(a.card(id: 5)?.title, "new")
        XCTAssertEqual(a.card(id: 6)?.title, "added remotely")
    }

    func testMergeGhostSuppressesResurrection() {
        var a = PasswordDatabase()
        a.ghosts = [Ghost(id: 7, time: 500)]
        var b = PasswordDatabase()
        var c = Card(id: 7); c.title = "zombie"; c.modified = 100
        b.cards = [c]
        a.merge(with: b)
        XCTAssertNil(a.card(id: 7))
    }

    func testDefaultDatabaseContents() {
        var db = PasswordDatabase.createDefault(now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(db.labels.count, 3, "商务/私人/网络账号")
        XCTAssertEqual(db.templateCards.count, 16, "15 named templates + custom")
        XCTAssertEqual(db.templateCards.first { $0.id == 102 }?.fields.count, 4)
        let nid = db.nextItemId()
        XCTAssertFalse(db.isUsedItemId(nid), "ids must skip used ids")
        XCTAssertTrue(![1, 2, 4].contains(nid), "label ids are taken")
    }
}

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

final class FieldTypeTests: XCTestCase {
    func testTypeSet() {
        XCTAssertEqual(FieldType.allCases.count, 12)
        XCTAssertEqual(Autofill.allCases.count, 9)
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

final class StoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("upw-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testCreateLoadSaveBackupRestoreRenameDelete() throws {
        let store = DatabaseStore(root: tempDir)
        try store.create(name: "Alpha", password: "pw1", now: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(store.exists("Alpha"))

        var db = try store.load(name: "Alpha", password: "pw1")
        XCTAssertEqual(db.templateCards.count, 16)
        var card = Card(id: 900)
        card.title = "Added"
        db.cards.append(card)
        try store.save(db, name: "Alpha", password: "pw1")

        let reloaded = try store.load(name: "Alpha", password: "pw1")
        XCTAssertEqual(reloaded.card(id: 900)?.title, "Added")

        XCTAssertThrowsError(try store.load(name: "Alpha", password: "bad"))

        try store.backup(name: "Alpha", password: "pw1", now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(store.backups(name: "Alpha").count, 1)

        try store.rename("Alpha", to: "Beta")
        XCTAssertFalse(store.exists("Alpha"))
        XCTAssertTrue(store.exists("Beta"))

        try store.delete(name: "Beta")
        XCTAssertFalse(store.exists("Beta"))
    }

    func testInvalidNamesRejected() {
        let store = DatabaseStore(root: tempDir)
        XCTAssertThrowsError(try store.create(name: "bad name!", password: "x"))
        XCTAssertThrowsError(try store.create(name: "", password: "x"))
    }

    func testEncryptedFileFormat() throws {
        let store = DatabaseStore(root: tempDir)
        try store.create(name: "Gamma", password: "pw")
        let data = try Data(contentsOf: store.url(for: "Gamma"))
        XCTAssertTrue(DatabaseCipher.checkFileMagic(data), "on-disk container uses DatabaseCipher format")
        XCTAssertNil(String(data: data, encoding: .utf8).flatMap { $0.contains("<database>") ? $0 : nil },
                     "plaintext XML must not appear in the container")
    }
}
