import Foundation

/// Localization helper. Keys and values are carried over verbatim from the
/// original app's `Localizable.strings` / `database.strings` tables
/// (see ../PasswordsCodes/resources/strings).
enum L10n {
    static let bundle: Bundle = .module

    /// Localizable.strings lookup.
    static func t(_ key: String) -> String {
        let v = bundle.localizedString(forKey: key, value: key, table: "Localizable")
        return v
    }

    /// database.strings lookup (template/field/special-label names).
    static func db(_ key: String) -> String {
        let v = bundle.localizedString(forKey: key, value: key, table: "Database")
        return v
    }

    /// Resolves `@string/key` references used by the original templates XML.
    static func resolve(_ raw: String) -> String {
        guard raw.hasPrefix("@string/") else { return raw }
        return db(String(raw.dropFirst("@string/".count)))
    }

    /// Brand substitution: the original strings hardcode the "Safe" brand name.
    static func brand() -> String { "UPasswords" }

    static func tBranded(_ key: String) -> String {
        t(key).replacingOccurrences(of: "Safe", with: brand())
    }
}
