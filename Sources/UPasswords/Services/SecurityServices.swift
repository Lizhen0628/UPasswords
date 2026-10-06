import Foundation
import CryptoKit

/// Compromised password check via haveibeenpwned.com's k-anonymity range API:
/// only the first 5 hex chars of the SHA-1 hash leave the machine. Falls back
/// to an embedded offline demo set when offline. Online hits are recorded into
/// a local dynamic breach list (SHA-1 only), so they keep counting offline.
enum CompromisedService {
    /// Offline demo set — most-common leaked passwords (subset).
    static let offlineDemoSet: Set<String> = [
        "123456", "password", "123456789", "12345678", "12345", "1234567", "qwerty",
        "111111", "1234567890", "123123", "abc123", "1234", "password1", "iloveyou",
        "000000", "qwerty123", "1q2w3e4r", "admin", "qwertyuiop", "654321", "555555",
        "lovely", "7777777", "888888", "princess", "dragon", "sunshine", "master",
        "monkey", "letmein", "football", "shadow", "superman", "michael", "trustno1",
    ]

    static func sha1Prefixes(_ passwords: [String], prefixLength: Int = 5) -> [String: String] {
        var out: [String: String] = [:]
        for p in passwords {
            out[p] = sha1Hex(p)
        }
        return out
    }

    /// 单个密码的 SHA-1 十六进制(小写)。
    static func sha1Hex(_ password: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data(password.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    struct Result {
        var compromisedPasswords: Set<String> = []
        var offline: Bool = false
        var error: String? = nil
    }

    /// 解析 HIBP range 响应为后缀集合。响应行以 CRLF 分隔——Swift 把 \r\n
    /// 视为单个图形簇,String.split(separator: "\n") 一个也切不开,会导致
    /// 整个泄露库"查不中"(曾造成全部误报干净),必须按 isNewline 切分。
    static func parseSuffixes(_ body: String) -> Set<String> {
        Set(body.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            guard let sfx = line.split(separator: ":").first else { return nil }
            return String(sfx).uppercased()
        })
    }

    /// Online k-anonymity check. `demo` forces the offline set (no network).
    static func check(passwords: Set<String>, demo: Bool = false) async -> Result {
        guard !passwords.isEmpty else { return Result() }
        if demo {
            return Result(compromisedPasswords: passwords.intersection(offlineDemoSet), offline: true)
        }
        var result = Result()
        let hashes = sha1Prefixes(Array(passwords))
        let byPrefix = Dictionary(grouping: hashes.values) { String($0.prefix(5)) }
        var found: Set<String> = []
        var hadNetworkFailure = false
        var failures: [String] = []
        for prefix in byPrefix.keys {
            var req = URLRequest(url: URL(string: "https://api.pwnedpasswords.com/range/\(prefix)")!)
            req.timeoutInterval = 15
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                    hadNetworkFailure = true
                    failures.append("\(prefix): HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
                    continue
                }
                let body = String(data: data, encoding: .utf8) ?? ""
                let suffixes = parseSuffixes(body)
                for (pw, hash) in hashes where hash.hasPrefix(prefix) {
                    let suffix = String(hash.dropFirst(5)).uppercased()
                    if suffixes.contains(suffix) { found.insert(pw) }
                }
            } catch {
                hadNetworkFailure = true
                failures.append("\(prefix): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty {
            // 请求失败必须可见:否则回退结果会被当成"真干净"(曾掩盖过真实泄露)
            Log.warn("security", "hibp range failed \(failures.count)/\(byPrefix.count): \(failures.prefix(3).joined(separator: "; "))")
        } else if !byPrefix.isEmpty {
            Log.info("security", "hibp range: \(byPrefix.count) prefix(es) ok")
        }
        if found.isEmpty && hadNetworkFailure && byPrefix.isEmpty == false {
            // network unavailable: fall back to the offline set so the feature
            // still produces a result (marked offline)
            Log.warn("security", "hibp unreachable → offline demo-set fallback (check network/proxy)")
            result.compromisedPasswords = passwords.intersection(offlineDemoSet)
            result.offline = true
        } else {
            result.compromisedPasswords = found
        }
        return result
    }
}

// MARK: - 本地动态泄露清单

extension CompromisedService {
    /// UserDefaults 键:在线检查命中过的密码 SHA-1 列表(不存明文,隐私红线)。
    static let dynamicHashesKey = "security.breachHashes"
    private static let cacheLock = NSLock()
    /// 进程内缓存(读多写少,UserDefaults 每次读也有开销);nil = 未加载。
    private static var cachedDynamicHashes: Set<String>? = nil

    /// 本地动态泄露清单:在线检查命中的密码哈希集合。
    static var dynamicBreachHashes: Set<String> {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = cachedDynamicHashes { return cached }
        let loaded = Set(UserDefaults.standard.stringArray(forKey: dynamicHashesKey) ?? [])
        cachedDynamicHashes = loaded
        return loaded
    }

    /// 在线检查命中的密码加入本地清单(记录 SHA-1),此后离线也能标记侧栏计数。
    static func recordBreached(_ passwords: Set<String>) {
        cacheLock.lock()
        var all = cachedDynamicHashes ?? Set(UserDefaults.standard.stringArray(forKey: dynamicHashesKey) ?? [])
        cacheLock.unlock()
        var added = 0
        for p in passwords where all.insert(sha1Hex(p)).inserted {
            added += 1
        }
        cacheLock.lock()
        cachedDynamicHashes = all
        cacheLock.unlock()
        UserDefaults.standard.set(all.sorted(), forKey: dynamicHashesKey)
        if added > 0 {
            Log.info("security", "local breach list +\(added) → \(all.count) hash(es)")
        }
    }

    /// 密码是否命中本地泄露清单(内嵌常见集 或 动态积累的在线命中)。
    static func isLocallyBreached(_ password: String) -> Bool {
        if offlineDemoSet.contains(password) { return true }
        return dynamicBreachHashes.contains(sha1Hex(password))
    }
}

/// Same-password analysis (SamePasswordsModel).
enum SamePasswordsService {
    /// password → card ids using it.
    static func groups(cards: [Card]) -> [String: [Int]] {
        var out: [String: [Int]] = [:]
        for c in cards where !c.trashed && !c.template {
            for f in c.fields where f.type == .password && !f.value.isEmpty {
                out[f.value, default: []].append(c.id)
            }
        }
        return out.filter { $0.value.count > 1 }
    }
}
