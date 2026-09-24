import Foundation

/// Localization helper over the `Localizable` / `Database` strings tables.
enum L10n {
    static let bundle: Bundle = .module

    /// 语言覆盖(设置页「语言」选项):为空时跟随系统,否则使用对应 lproj。
    /// 每次调用时解析,使切换语言后界面即时刷新。
    private static var bundleCache: [String: Bundle] = [:]

    static var activeBundle: Bundle {
        let lang = UserDefaults.standard.string(forKey: "app.language") ?? ""
        guard !lang.isEmpty else { return .module }
        if let cached = bundleCache[lang] { return cached }
        // SwiftPM 会把 lproj 目录名小写化(zh-Hans → zh-hans),需两次尝试
        let path = Bundle.module.path(forResource: lang, ofType: "lproj")
            ?? Bundle.module.path(forResource: lang.lowercased(), ofType: "lproj")
        let resolved = path.flatMap { Bundle(path: $0) } ?? .module
        bundleCache[lang] = resolved
        return resolved
    }

    /// Localizable.strings lookup.
    static func t(_ key: String) -> String {
        let v = activeBundle.localizedString(forKey: key, value: key, table: "Localizable")
        return v
    }

    /// database.strings lookup (template/field/special-label names).
    static func db(_ key: String) -> String {
        let v = activeBundle.localizedString(forKey: key, value: key, table: "Database")
        return v
    }

    /// Resolves `@string/key` references used by the built-in templates.
    static func resolve(_ raw: String) -> String {
        guard raw.hasPrefix("@string/") else { return raw }
        return db(String(raw.dropFirst("@string/".count)))
    }

    /// 品牌相关文案(字符串表中品牌名直接为 UPasswords,与 t 一致,保留语义入口)。
    static func tBranded(_ key: String) -> String { t(key) }

    /// Key with a fallback applied when the key is missing.
    static func t(_ key: String, fallback: String) -> String {
        let v = activeBundle.localizedString(forKey: key, value: fallback, table: "Localizable")
        return v == key ? fallback : v
    }
}
