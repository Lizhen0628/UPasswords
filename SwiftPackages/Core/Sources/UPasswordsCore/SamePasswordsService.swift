import Foundation

/// Same-password analysis (SamePasswordsModel).
public enum SamePasswordsService {
    /// password → card ids using it.
    public static func groups(cards: [Card]) -> [String: [Int]] {
        var out: [String: [Int]] = [:]
        for c in cards where !c.trashed && !c.template {
            for f in c.fields where f.type == .password && !f.value.isEmpty {
                out[f.value, default: []].append(c.id)
            }
        }
        return out.filter { $0.value.count > 1 }
    }
}
