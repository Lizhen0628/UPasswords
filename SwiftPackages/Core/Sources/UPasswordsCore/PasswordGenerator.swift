import Foundation
import Security

/// Password generator settings, persisted to `UserDefaults`.
public final class PasswordSettings: ObservableObject {
    /// 应用共享的生成设置实例，使用 UserDefaults 持久化偏好。
    public static let shared = PasswordSettings()

    private let d = UserDefaults.standard

    /// 随机模式可选的符号字符集合。
    public var symbolsAlphabet: String {
        didSet { d.set(symbolsAlphabet, forKey: "pwd.symbolsAlphabet") }
    }
    /// 词组模式可选的分隔字符集合；为空时使用连字符。
    public var separatorAlphabet: String {
        didSet { d.set(separatorAlphabet, forKey: "pwd.separatorAlphabet") }
    }
    /// 随机字符模式是否排除容易混淆的字符。
    public var excludeSimilarCharacters: Bool {
        didSet { d.set(excludeSimilarCharacters, forKey: "pwd.excludeSimilar") }
    }
    /// 用户配置的目标字符数；词组模式的实际长度可能有小幅偏差。
    public var passwordLength: Int {
        didSet { d.set(passwordLength, forKey: "pwd.length") }
    }
    /// 0 完全随机 / 1 便于记忆 / 2 仅字母和数字 / 3 仅允许数字 — Localizable keys
    /// random_text / memorable_text / letters_and_numbers_text / numbers_only_text.
    public var passwordType: Int {
        didSet { d.set(passwordType, forKey: "pwd.type") }
    }

    /// 从 UserDefaults 加载生成偏好，缺失项使用内置默认值。
    public init() {
        symbolsAlphabet = d.string(forKey: "pwd.symbolsAlphabet") ?? "!@#$%^&*()-_=+[]{};:,.?/"
        separatorAlphabet = d.string(forKey: "pwd.separatorAlphabet") ?? "-_."
        excludeSimilarCharacters = d.bool(forKey: "pwd.excludeSimilar")
        passwordLength = d.object(forKey: "pwd.length") as? Int ?? 12
        passwordType = d.object(forKey: "pwd.type") as? Int ?? 0
    }
}

/// Password generator — singleton with history, random / memorable /
/// letters-and-numbers / digits-only modes and a word dictionary for
/// memorable passwords.
public final class PasswordGenerator {
    /// 应用共享的密码生成器；历史仅驻留在此实例内存中。
    public static let instance = PasswordGenerator()

    /// 去重且从新到旧排列的最近 20 条生成明文，不写入 UserDefaults。
    public private(set) var history: [String] = []
    /// 随应用内嵌的英文单词表，用于生成便于记忆的密码。
    public let dictionary: [String]
    /// 生成历史容量上限(超出淘汰最旧记录)
    private static let historyLimit = 20
    /// 便于记忆密码的最大组词数(超过后截断,避免超长)
    private static let memorableMaxWords = 6

    /// 创建携带内嵌词表及空明文历史的生成器实例。
    public init() {
        // Compact embedded word list for memorable passwords.
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

    /// 将非空生成值移到历史首位，去重并裁剪为最近 20 项。
    ///
    /// - Parameter p: 生成的密码明文。
    public func addPasswordToHistory(_ p: String) {
        guard !p.isEmpty else { return }
        history.removeAll { $0 == p }
        history.insert(p, at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
    }
    /// 清除生成器实例中的全部明文历史。
    public func clearHistory() { history.removeAll() }

    // MARK: Alphabets

    /// 随机模式可选的符号字符集合。
    public var symbolsAlphabet: String { PasswordSettings.shared.symbolsAlphabet }
    /// 词组模式可选的分隔字符集合；为空时使用连字符。
    public var separatorAlphabet: String { PasswordSettings.shared.separatorAlphabet }

    private let lower = "abcdefghijklmnopqrstuvwxyz"
    private let upper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    private let digits = "0123456789"
    private let similar = "Il1O0o"

    /// 返回指定模式的候选字符集合。
    ///
    /// - Parameter type: 设置中的模式编号；未知编号使用完整随机模式。
    /// - Returns: 尚未按易混淆字符偏好过滤的字符集合。
    public func alphabets(forType type: Int) -> [String] {
        switch type {
        case 1: return [lower, upper, digits] // memorable uses dictionary; fallback chars
        case 2: return [lower, upper, digits]
        case 3: return [digits]
        default: return [lower, upper, digits, symbolsAlphabet]
        }
    }

    // MARK: Generation

    /// 按指定模式生成密码；不会自动写入历史。
    ///
    /// - Parameters:
    ///   - length: 目标字符数，随机模式中小于 1 时返回空串。
    ///   - type: 0 为随机、1 为词组、2 为字母数字、3 为数字。
    /// - Returns: 生成的密码明文。
    public func password(length: Int, type: Int) -> String {
        switch type {
        case 1: return memorablePassword(length: length)
        case 2: return randomPassword(length: length, alphabets: [lower, upper, digits])
        case 3: return randomPassword(length: length, alphabets: [digits])
        default: return randomPassword(length: length, alphabets: alphabets(forType: 0))
        }
    }

    /// 从非空字符池安全随机抽取并打乱密码。
    ///
    /// 长度允许时每个有效字符池至少贡献一个字符。
    /// - Parameters:
    ///   - length: 精确输出长度，小于 1 时返回空串。
    ///   - alphabets: 各类别候选字符，应用排除偏好后空池会被跳过。
    /// - Returns: 随机密码；所有池为空时返回空串。
    public func randomPassword(length: Int, alphabets: [String]) -> String {
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

    /// 拼接最多六个词与随机分隔符，必要时回退为随机字符。
    ///
    /// - Parameter length: 目标长度；词组输出不保证与此长度完全相等。
    /// - Returns: 生成的密码明文。
    public func memorablePassword(length: Int) -> String {
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

    /// 从符合长度限制的词表中随机选取一个词。
    ///
    /// - Parameter maxLength: 最大词长；小于 3 时按 3 处理。
    /// - Returns: 候选词；没有匹配项时为固定回退词。
    public func dictionaryWord(maxLength: Int) -> String {
        let candidates = dictionary.filter { $0.count <= max(3, maxLength) }
        return candidates.randomElement() ?? "word"
    }
}
