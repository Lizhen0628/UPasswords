import Foundation
import CryptoKit

/// Compromised password check via haveibeenpwned.com's k-anonymity range API:
/// only the first 5 hex chars of the SHA-1 hash leave the machine. Falls back
/// to an embedded offline demo set when offline.
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
            let digest = Insecure.SHA1.hash(data: Data(p.utf8))
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            out[p] = hex
        }
        return out
    }

    struct Result {
        var compromisedPasswords: Set<String> = []
        var offline: Bool = false
        var error: String? = nil
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
        for prefix in byPrefix.keys {
            var req = URLRequest(url: URL(string: "https://api.pwnedpasswords.com/range/\(prefix)")!)
            req.timeoutInterval = 15
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                    hadNetworkFailure = true
                    continue
                }
                let body = String(data: data, encoding: .utf8) ?? ""
                let suffixes = Set(body.split(separator: "\n").compactMap { line -> String? in
                    let parts = line.split(separator: ":")
                    guard let sfx = parts.first else { return nil }
                    return String(sfx).uppercased()
                })
                for (pw, hash) in hashes where hash.hasPrefix(prefix) {
                    let suffix = String(hash.dropFirst(5)).uppercased()
                    if suffixes.contains(suffix) { found.insert(pw) }
                }
            } catch {
                hadNetworkFailure = true
            }
        }
        if found.isEmpty && hadNetworkFailure && byPrefix.isEmpty == false {
            // network unavailable: fall back to the offline set so the feature
            // still produces a result (marked offline)
            result.compromisedPasswords = passwords.intersection(offlineDemoSet)
            result.offline = true
        } else {
            result.compromisedPasswords = found
        }
        return result
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
