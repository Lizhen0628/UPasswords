import Foundation

/// Localization helper over the `Localizable` / `Database` strings tables.
public enum L10n {
    public static let bundle: Bundle = .module

    /// 语言覆盖(设置页「语言」选项):为空时跟随系统,否则使用对应 lproj。
    /// 每次调用时解析,使切换语言后界面即时刷新。
    private static var bundleCache: [String: Bundle] = [:]

    public static var activeBundle: Bundle {
        let lang = UserDefaults.standard.string(forKey: "app.language") ?? ""
        guard lang.isEmpty else { return overrideBundle(for: lang) }
        return systemBundle
    }

    /// 显式覆盖:按 lproj 名解析(SwiftPM 会把目录名小写化,zh-Hans → zh-hans,需两次尝试)。
    private static func overrideBundle(for lang: String) -> Bundle {
        if let cached = bundleCache[lang] { return cached }
        let path = Bundle.module.path(forResource: lang, ofType: "lproj")
            ?? Bundle.module.path(forResource: lang.lowercased(), ofType: "lproj")
        let resolved = path.flatMap { Bundle(path: $0) } ?? .module
        bundleCache[lang] = resolved
        return resolved
    }

    /// 无覆盖时:按系统首选语言(Locale.preferredLanguages)在本包可用本地化中匹配。
    /// iOS 主 App 不含 lproj(字符串都在本资源包),进程级 preferredLocalizations
    /// 会退化为开发语言,直接读 .module 导致"跟随系统"失效——这里显式匹配,
    /// 兼容区域后缀(zh-Hans-CN → zh-Hans)且不跨文字体系(zh-Hant 不会命中 zh-Hans)。
    private static let systemBundle: Bundle = {
        let available = Bundle.module.paths(forResourcesOfType: "lproj", inDirectory: nil)
            .map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent.lowercased() }
        func lookup(_ tag: String) -> Bundle? {
            guard available.contains(tag.lowercased()) else { return nil }
            return Bundle.module.path(forResource: tag, ofType: "lproj").flatMap { Bundle(path: $0) }
                ?? Bundle.module.path(forResource: tag.lowercased(), ofType: "lproj").flatMap { Bundle(path: $0) }
        }
        for pref in Locale.preferredLanguages {
            // "zh-Hans-CN" 依次尝试 zh-hans-cn / zh-hans;"en" 只有一次
            var tag = pref.replacingOccurrences(of: "_", with: "-")
            while !tag.isEmpty {
                if let resolved = lookup(tag) { return resolved }
                if let idx = tag.lastIndex(of: "-") {
                    tag = String(tag[..<idx])
                } else {
                    break
                }
            }
        }
        return .module
    }()

    /// Localizable.strings lookup.
    public static func t(_ key: String) -> String {
        let v = activeBundle.localizedString(forKey: key, value: key, table: "Localizable")
        return v
    }

    /// database.strings lookup (template/field/special-label names).
    public static func db(_ key: String) -> String {
        let v = activeBundle.localizedString(forKey: key, value: key, table: "Database")
        return v
    }

    /// Resolves `@string/key` references used by the built-in templates.
    public static func resolve(_ raw: String) -> String {
        guard raw.hasPrefix("@string/") else { return raw }
        return db(String(raw.dropFirst("@string/".count)))
    }

    /// 品牌相关文案(字符串表中品牌名直接为 UPasswords,与 t 一致,保留语义入口)。
    public static func tBranded(_ key: String) -> String { t(key) }

    /// Key with a fallback applied when the key is missing.
    public static func t(_ key: String, fallback: String) -> String {
        let v = activeBundle.localizedString(forKey: key, value: fallback, table: "Localizable")
        return v == key ? fallback : v
    }
}
