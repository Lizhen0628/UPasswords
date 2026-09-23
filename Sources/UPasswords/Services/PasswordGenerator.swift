import Foundation
import Security

/// Mirrors `PasswordSettings` (Services/PasswordSettings.h, ObservableModel singleton).
final class PasswordSettings: ObservableObject {
    static let shared = PasswordSettings()

    private let d = UserDefaults.standard

    @Published var symbolsAlphabet: String {
        didSet { d.set(symbolsAlphabet, forKey: "pwd.symbolsAlphabet") }
    }
    @Published var separatorAlphabet: String {
        didSet { d.set(separatorAlphabet, forKey: "pwd.separatorAlphabet") }
    }
    @Published var excludeSimilarCharacters: Bool {
        didSet { d.set(excludeSimilarCharacters, forKey: "pwd.excludeSimilar") }
    }
    @Published var passwordLength: Int {
        didSet { d.set(passwordLength, forKey: "pwd.length") }
    }
    /// 0 完全随机 / 1 便于记忆 / 2 仅字母和数字 / 3 仅允许数字 — Localizable keys
    /// random_text / memorable_text / letters_and_numbers_text / numbers_only_text.
    @Published var passwordType: Int {
        didSet { d.set(passwordType, forKey: "pwd.type") }
    }

    init() {
        symbolsAlphabet = d.string(forKey: "pwd.symbolsAlphabet") ?? "!@#$%^&*()-_=+[]{};:,.?/"
        separatorAlphabet = d.string(forKey: "pwd.separatorAlphabet") ?? "-_."
        excludeSimilarCharacters = d.bool(forKey: "pwd.excludeSimilar")
        passwordLength = d.object(forKey: "pwd.length") as? Int ?? 12
        passwordType = d.object(forKey: "pwd.type") as? Int ?? 0
    }
}

/// Mirrors `PasswordGenerator` (Services/PasswordGenerator.h) — singleton with
/// history, random / memorable / letters-and-numbers / digits-only modes and a
/// word dictionary for memorable passwords.
final class PasswordGenerator {
    static let instance = PasswordGenerator()

    private(set) var history: [String] = []
    let dictionary: [String]
    /// 生成历史容量上限(超出淘汰最旧记录)
    private static let historyLimit = 20
    /// 便于记忆密码的最大组词数(超过后截断,避免超长)
    private static let memorableMaxWords = 6

    init() {
        // Compact embedded word list (original ships dictionary.txt for
        // memorable passwords and zxcvbn).
        let words = """
        apple anchor autumn brave breeze bridge bright bronze butter cabin candle canvas canyon carbon
        castle cedar cherry chess cinder clay cliff clover cobalt comet compass copper coral cosmic cotton
        crystal dagger dahlia dawn delta desert diamond dolphin domino dragon dune eagle ember emerald
        falcon feather fern fiddle flint forest fossil fountain galaxy garnet gecko ginger glacier granite
        harbor harvest hazard helix hollow horizon ivory jade jasmine jasper jungle juniper kernel kettle
        lagoon lantern lava lemon lilac linen lotus lumber lunar lynx magma maple marble meadow mercury
        mineral mirror monsoon moss nebula nickel noble nectar needle oasis ocean olive onyx opal orbit
        orchid otter oxide paddle panda papaya pearl pebble pepper petal phoenix pigeon pillar pine pistol
        planet plasma plaza plum polar poppy prairie prism quail quartz quiver rabbit radar rapid raven
        reef ribbon ridge ripple river robin rocket rose ruby rustic saffron sage sail salmon sandal
        sapphire satin savanna scarlet sequoia shadow shell shrimp signal silk silver siren slate solar
        sonnet sparrow spider spiral spruce stellar stone sunset syrup tandem teal temple thicket thunder
        tiger timber topaz torch tornado tortoise totem toucan trail trellis tulip tundra tunnel turtle
        umber unicorn valley vanilla velvet verbena vertex vessel violet vista volcanic walnut warbler
        waterfall wattle willow winter wisteria wolf wombat yarrow zebra zenith zephyr zinc zircon
        """
        dictionary = words.split(whereSeparator: { $0 == "\n" || $0 == " " }).map(String.init).filter { $0.count >= 3 }
    }

    // MARK: History

    func addPasswordToHistory(_ p: String) {
        guard !p.isEmpty else { return }
        history.removeAll { $0 == p }
        history.insert(p, at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
    }
    func clearHistory() { history.removeAll() }

    // MARK: Alphabets

    var symbolsAlphabet: String { PasswordSettings.shared.symbolsAlphabet }
    var separatorAlphabet: String { PasswordSettings.shared.separatorAlphabet }

    private let lower = "abcdefghijklmnopqrstuvwxyz"
    private let upper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    private let digits = "0123456789"
    private let similar = "Il1O0o"

    func alphabets(forType type: Int) -> [String] {
        switch type {
        case 1: return [lower, upper, digits] // memorable uses dictionary; fallback chars
        case 2: return [lower, upper, digits]
        case 3: return [digits]
        default: return [lower, upper, digits, symbolsAlphabet]
        }
    }

    // MARK: Generation

    func password(length: Int, type: Int) -> String {
        switch type {
        case 1: return memorablePassword(length: length)
        case 2: return randomPassword(length: length, alphabets: [lower, upper, digits])
        case 3: return randomPassword(length: length, alphabets: [digits])
        default: return randomPassword(length: length, alphabets: alphabets(forType: 0))
        }
    }

    func randomPassword(length: Int, alphabets: [String]) -> String {
        guard length >= 1 else { return "" }
        var pools = alphabets.filter { !$0.isEmpty }
        if PasswordSettings.shared.excludeSimilarCharacters {
            pools = pools.map { $0.filter { !similar.contains($0) } }.filter { !$0.isEmpty }
        }
        guard !pools.isEmpty else { return "" }
        var chars: [Character] = []
        // guarantee at least one char from each pool when length allows
        // (pools 已过滤非空,此处解包为逻辑保证)
        for pool in pools where chars.count < length {
            chars.append(pool.randomElement()!)
        }
        let all = pools.joined()  // pools 非空 → all 非空
        while chars.count < length {
            chars.append(all.randomElement()!)
        }
        return String(chars.shuffled())
    }

    func memorablePassword(length: Int) -> String {
        // 三元表达式 else 分支已保证 separatorAlphabet 非空,解包为逻辑保证
        let sep = separatorAlphabet.isEmpty ? "-" : String(separatorAlphabet.randomElement()!)
        var words: [String] = []
        var total = 0
        while total < length {
            let w = dictionaryWord(maxLength: max(3, length - total))
            if total > 0 { total += 1 }
            total += w.count
            words.append(w)
            if words.count >= Self.memorableMaxWords { break }
        }
        var pw = words.joined(separator: sep)
        if pw.count > length + 4 {
            pw = randomPassword(length: length, alphabets: [lower, digits])
        }
        return pw
    }

    func dictionaryWord(maxLength: Int) -> String {
        let candidates = dictionary.filter { $0.count <= max(3, maxLength) }
        return candidates.randomElement() ?? "word"
    }
}
