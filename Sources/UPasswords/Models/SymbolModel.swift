import SwiftUI

/// Mirrors `SymbolModel` + `Symbol` (Views/Symbol.h): a catalog of card icons
/// organized into selectable groupsss. The original ships TIFF assets; this
/// replica draws the same symbol vocabulary with SF Symbols (original artwork
/// is not redistributed).
final class SymbolModel {
    static let shared = SymbolModel()

    /// group key (database.strings `*_group`) → symbol names
    let groups: [String: [String]]
    /// symbol name → SF Symbol name for drawing
    private let sfMap: [String: String]

    /// Original symbol names appearing in templates-database.xml and the binary.
    private static let catalog: [(group: String, items: [(name: String, sf: String)])] = [
        ("internet_group", [
            ("web_site", "globe"), ("email", "envelope"), ("router", "wifi.router"), ("network", "network"),
            ("cloud", "cloud"), ("facebook", "f.circle"), ("x_twitter", "bird"), ("instagram", "camera.circle"),
            ("linkedin", "person.crop.rectangle"), ("reddit", "bubble.left.and.bubble.right"), ("youtube", "play.rectangle"),
            ("telegram", "paperplane"), ("whatsapp", "phone.circle"), ("tiktok", "music.note"),
            ("netflix", "play.tv"), ("spotify", "music.quarternote.3"), ("twitch", "tv"),
            ("github", "chevron.left.forwardslash.chevron.right"), ("gitlab", "arrow.triangle.branch"),
            ("discord", "message"), ("pinterest", "pin"), ("amazon", "cart"), ("ebay", "tag"),
            ("paypal", "dollarsign.circle"), ("stripe", "creditcard"), ("shop", "bag"),
            ("wordpress", "w.square"), ("wikipedia", "books.vertical"), ("vpn", "shield.lefthalf.filled"),
        ]),
        ("finances_group", [
            ("bank", "building.columns"), ("credit_card", "creditcard"), ("wallet", "wallet.pass"),
            ("cash", "banknote"), ("money", "dollarsign.circle"), ("bitcoin", "bitcoinsign.circle"),
            ("coin", "centsign.circle"), ("investment", "chart.line.uptrend.xyaxis"),
            ("insurance", "umbrella"), ("stock", "chart.bar"), ("tax", "percent"),
            ("loan", "arrow.left.arrow.right"), ("piggy_bank", "banknote"),
            ("visa", "creditcard.fill"), ("mastercard", "creditcard.circle"), ("amex", "creditcard.and.123"),
            ("discover", "creditcard.trianglebadge.exclamationmark"), ("jcb", "creditcard.square"), ("rupay", "creditcard.fill"),
        ]),
        ("personal_group", [
            ("id", "person.crop.square"), ("passport", "book"), ("driving_license", "car"),
            ("social_security", "person.text.rectangle"), ("name", "person.crop.circle"),
            ("address", "mappin"), ("birthday", "gift"), ("phone", "phone"), ("contacts", "person.2"),
            ("family", "figure.2.and.child.holdinghands"), ("health", "cross.case"), ("doctor", "stethoscope"),
            ("medicine", "pills"), ("pets", "pawprint"), ("clothes", "tshirt"),
        ]),
        ("technology_group", [
            ("key", "key"), ("lock", "lock"), ("cd", "opticaldisc"), ("usb", "cable.connector"),
            ("computer", "desktopcomputer"), ("laptop", "laptopcomputer"), ("mobile", "iphone"),
            ("tablet", "ipad.landscape"), ("tv", "tv"), ("camera", "camera"), ("printer", "printer"),
            ("console", "gamecontroller"), ("drone", "antenna.radiowaves.left.and.right"),
            ("server", "server.rack"), ("database", "cylinder.split.1x2"), ("code", "curlybraces"),
        ]),
        ("transport_group", [
            ("car", "car"), ("moto", "figure.outdoor.cycle"), ("bicycle", "bicycle"),
            ("bus", "bus"), ("train", "tram"), ("plane", "airplane"), ("ship", "ferry"),
            ("transport", "car.2"), ("fuel", "fuelpump"), ("map", "map"), ("hotel", "bed.double"),
            ("luggage", "suitcase"),
        ]),
        ("security_group", [
            ("shield", "shield"), ("fingerprint", "touchid"), ("eye", "eye"), ("vault", "lock.shield"),
            ("safe", "lock.rectangle"), ("alarm", "alarm"), ("cctv", "video"), ("siren", "light.beacon.max"),
        ]),
        ("misc_group", [
            ("membership", "person.crop.rectangle.badge.checkmark"), ("card", "rectangle.on.rectangle"),
            ("note", "note.text"), ("bookmark", "bookmark"), ("gift", "gift"), ("education", "graduationcap"),
            ("book", "textbook"), ("music", "music.note"), ("movie", "film"), ("game", "gamecontroller"),
            ("sport", "sportscourt"), ("travel", "airplane.departure"), ("food", "fork.knife"),
            ("coffee", "cup.and.saucer"), ("shopping", "bag"), ("tools", "wrench.and.screwdriver"),
            ("job", "briefcase"), ("meeting", "person.3"), ("lecture", "person.wave.2"),
            ("legal", "scalemass"), ("science", "atom"), ("weather", "cloud.sun"), ("recycle", "arrow.triangle.2.circlepath.recycle"),
            ("custom", "square.dashed"),
        ]),
        ("special_group", [
            ("star", "star"), ("heart", "heart"), ("flag", "flag"), ("warning", "exclamationmark.triangle"),
            ("check", "checkmark.seal"), ("question", "questionmark.circle"), ("info", "info.circle"),
            ("plus", "plus.circle"), ("gear", "gearshape"), ("link", "link"), ("pin", "mappin.and.ellipse"),
        ]),
    ]

    init() {
        var g: [String: [String]] = [:]
        var m: [String: String] = [:]
        for group in Self.catalog {
            g[group.group] = group.items.map(\.name)
            for item in group.items { m[item.name] = item.sf }
        }
        groups = g
        sfMap = m
    }

    var groupNames: [String] { Self.catalog.map(\.group) }

    func names(forGroup group: String) -> [String] { groups[group] ?? [] }

    func group(ofSymbol symbol: String) -> String? {
        for (g, names) in groups where names.contains(symbol) { return g }
        return nil
    }

    func sfSymbol(for name: String) -> String {
        if let sf = sfMap[name] { return sf }
        return "square.dashed" // custom/unknown
    }

    func groupName(_ key: String) -> String { L10n.db(key) }

    /// Mirrors `SymbolModel.creditCardSymbolForNumber:` — brand detection by IIN.
    func creditCardSymbol(forNumber number: String) -> String {
        let digits = number.filter(\.isNumber)
        guard digits.count >= 2 else { return "credit_card" }
        let prefix2 = Int(digits.prefix(2)) ?? 0
        let prefix4 = Int(digits.prefix(4)) ?? 0
        if digits.hasPrefix("4") { return "visa" }
        if (51...55).contains(prefix2) || (2221...2720).contains(prefix4) { return "mastercard" }
        if prefix2 == 34 || prefix2 == 37 { return "amex" }
        if prefix2 == 60 || prefix2 == 65 || digits.hasPrefix("6011") || (644...649).contains(prefix2) { return "discover" }
        if prefix2 == 35 || (300...305).contains(Int(digits.prefix(3)) ?? 0) { return "jcb" }
        if digits.hasPrefix("6035") { return "rupay" }
        return "credit_card"
    }
}
