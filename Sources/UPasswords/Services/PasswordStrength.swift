import Foundation
import CryptoKit

/// Password strength estimator: zxcvbn-style pattern matching (common
/// passwords / repeats / keyboard sequences / dates / dictionary) producing a
/// 0–4 score scale and crack-time strings.
struct PasswordStrength: Equatable {
    let score: Int          // 0…4 (zxcvbn scale)
    let entropy: Double     // bits
    var seconds: Double { // offline attack, 1e10 guesses/s
        pow(2.0, entropy) / 1e10
    }

    /// Fast scoring for weak-password checks.
    static func evaluate(_ password: String) -> PasswordStrength {
        guard !password.isEmpty else { return PasswordStrength(score: 0, entropy: 0) }
        var entropy = 0.0
        var guesses = 1.0

        // Common-password dictionary
        let common: Set<String> = [
            "123456", "password", "123456789", "12345678", "12345", "qwerty", "111111", "1234567",
            "dragon", "123123", "abc123", "iloveyou", "sunshine", "princess", "admin", "welcome",
            "monkey", "login", "football", "letmein", "passw0rd", "master", "hello", "freedom",
            "whatever", "qazwsx", "trustno1", "batman", "zaq12wsx", "asdfgh", "000000", "654321",
            "superman", "1qaz2wsx", "michael", "shadow", "password1", "p@ssw0rd", "qwerty123",
            "1q2w3e4r", "11111111", "aaa111", "zkzkzk", "asdf1234", "pass123", "test123", "root",
        ]
        if common.contains(password.lowercased()) {
            return PasswordStrength(score: 0, entropy: log2(Double(common.count)))
        }

        var rest = Substring(password)
        var weakestChain = 1.0 // product of per-segment guesses, take MIN over segmentation

        // simple single-pass segmentation: sequences / repeats / dictionary-ish / brute
        var totalGuesses = 1.0
        while !rest.isEmpty {
            let (guess, consumed) = matchPattern(rest)
            totalGuesses *= guess
            rest = rest.dropFirst(consumed)
        }
        weakestChain = totalGuesses

        guesses = weakestChain
        entropy = log2(max(guesses, 1.0))
        let score: Int
        switch entropy {
        case ..<20: score = 0
        case ..<40: score = 1
        case ..<60: score = 2
        case ..<80: score = 3
        default: score = 4
        }
        return PasswordStrength(score: score, entropy: entropy)
    }

    /// Returns (guesses, charsConsumed) for the strongest pattern at the head.
    /// All matching is done on Character arrays — no String index arithmetic.
    private static func matchPattern(_ s: Substring) -> (Double, Int) {
        let chars = Array(s)
        guard let head = chars.first else { return (1, 1) }

        // repeat (aaa, 111)
        var run = 1
        while run < chars.count && chars[run] == head { run += 1 }
        if run >= 3 { return (Double(run * 10), run) }

        // keyboard sequences (qwerty rows) and alphabet/digit sequences
        let rows: [[Character]] = [
            Array("qwertyuiop"), Array("asdfghjkl"), Array("zxcvbnm"),
            Array("1234567890"), Array("abcdefghijklmnopqrstuvwxyz"),
        ]
        func lower(_ c: Character) -> Character {
            let l = String(c).lowercased()
            return l.first ?? c
        }
        func runLength(in row: [Character]) -> Int {
            let low = lower(head)
            guard let start = row.firstIndex(of: low) else { return 1 }
            var n = 1
            var i = start + 1
            while n < chars.count, i < row.count, row[i] == lower(chars[n]) {
                n += 1
                i += 1
            }
            if n < 3, start > 0 {
                var m = 1
                var j = start - 1
                while m < chars.count, j >= 0, row[j] == lower(chars[m]) {
                    m += 1
                    j -= 1
                }
                n = max(n, m)
            }
            return n
        }
        var bestSeq = 1
        for row in rows { bestSeq = max(bestSeq, runLength(in: row)) }
        if bestSeq >= 3 { return (Double(bestSeq * 12), bestSeq) }

        let str = String(s)
        // year / date-like
        if let _ = str.range(of: "^(19|20)\\d{2}", options: .regularExpression), chars.count >= 4 {
            return (365 * 12.0, 4)
        }

        // dictionary word from the generator's word list (lowercased compare)
        let words = PasswordGenerator.instance.dictionary
        var bestWord = ""
        for w in words where w.count >= 4 {
            if str.lowercased().hasPrefix(w), w.count > bestWord.count { bestWord = w }
        }
        if !bestWord.isEmpty {
            let capBonus = chars[0].isUppercase ? 2.0 : 1.0
            return (Double(words.count) * capBonus, bestWord.count)
        }

        // brute force by charset size
        let charset: Double
        let hasLower = str.contains(where: { $0.isLowercase })
        let hasUpper = str.contains(where: { $0.isUppercase })
        let hasDigit = str.contains(where: { $0.isNumber })
        let hasSymbol = str.contains(where: { !$0.isLetter && !$0.isNumber })
        var c = 0.0
        if hasLower { c += 26 }
        if hasUpper { c += 26 }
        if hasDigit { c += 10 }
        if hasSymbol { c += 33 }
        charset = max(c, 10)
        return (pow(charset, 1.0), 1) // one char per step; entropy accrues per char
    }

    /// Per-character brute fallback for pure random strings: full charset entropy.
    static func bruteEntropy(_ password: String) -> Double {
        guard !password.isEmpty else { return 0 }
        let hasLower = password.contains(where: { $0.isLowercase })
        let hasUpper = password.contains(where: { $0.isUppercase })
        let hasDigit = password.contains(where: { $0.isNumber })
        let hasSymbol = password.contains(where: { !$0.isLetter && !$0.isNumber })
        var c = 0.0
        if hasLower { c += 26 }
        if hasUpper { c += 26 }
        if hasDigit { c += 10 }
        if hasSymbol { c += 33 }
        return Double(password.count) * log2(max(c, 2))
    }

    /// Convenience: the attacker always takes the cheapest strategy, so the
    /// effective entropy is min(pattern-search entropy, raw brute-force entropy).
    ///
    /// 结果经有界缓存(见 scoreCache):侧栏弱密码计数和详情页强度条每次渲染
    /// 都会对所有密码字段重算,而 score 是纯函数,缓存后结果完全一致。
    static func score(_ password: String) -> PasswordStrength {
        let key = cacheKey(for: password)
        cacheLock.lock()
        let hit = scoreCache[key]
        cacheLock.unlock()
        if let hit { return hit }

        let p = evaluate(password)
        let b = bruteEntropy(password)
        let entropy = min(p.entropy, b)
        let s: Int
        switch entropy {
        case ..<20: s = 0
        case ..<40: s = 1
        case ..<60: s = 2
        case ..<80: s = 3
        default: s = 4
        }
        let result = PasswordStrength(score: s, entropy: entropy)

        cacheLock.lock()
        if scoreCache[key] == nil {
            scoreCache[key] = result
            scoreCacheOrder.append(key)
            if scoreCacheOrder.count > scoreCacheLimit {
                scoreCache.removeValue(forKey: scoreCacheOrder.removeFirst())
            }
        }
        cacheLock.unlock()
        return result
    }

    // MARK: - Score cache

    /// 缓存键用密码的 SHA-256,避免在数据库之外再长期留存明文。
    private static func cacheKey(for password: String) -> String {
        SHA256.hash(data: Data(password.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var scoreCache: [String: PasswordStrength] = [:]
    nonisolated(unsafe) private static var scoreCacheOrder: [String] = []  // FIFO 逐出
    private static let scoreCacheLimit = 512
}

extension PasswordStrength {
    /// Localized crack-time text (瞬间/秒/分钟/小时/天/月/年/世纪之久).
    static func crackTime(seconds: Double) -> String {
        let minute = 60.0, hour = 3600.0, day = 86400.0
        let month = day * 30, year = day * 365, century = year * 100
        switch seconds {
        case ..<1: return L10n.t("instant_text")
        case ..<minute: return "\(Int(seconds))\(L10n.t("seconds_abbr_text"))"
        case ..<hour: return "\(Int(seconds / minute))\(L10n.t("minutes_abbr_text"))"
        case ..<day: return "\(Int(seconds / hour))\(L10n.t("hours_text"))"
        case ..<month: return "\(Int(seconds / day))\(L10n.t("days_text"))"
        case ..<year: return "\(Int(seconds / month))\(L10n.t("months_text"))"
        case ..<century: return "\(Int(seconds / year))\(L10n.t("years_text"))"
        default:
            let c = seconds / century
            if c > 100 { return L10n.t("centuries_text") }
            return "\(Int(c)) \(L10n.t("centuries_text"))"
        }
    }

    var crackTimeText: String { PasswordStrength.crackTime(seconds: seconds) }
}
