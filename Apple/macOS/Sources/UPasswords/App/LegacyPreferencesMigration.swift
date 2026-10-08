import Foundation

import UPasswordsCore

/// macOS 沙盒化一次性迁移:把未沙盒时代的偏好设置 plist 并入容器 defaults
/// (db.main/同步配置/主题/语言等),避免老用户升级后设置全部复位。
/// 读取旧 plist 依赖临时例外 entitlement;读不到(例外缺失/新装机)静默跳过。
enum LegacyPreferencesMigration {
    private static let plistName = "com.upasswords.UPasswords.plist"
    private static let doneKey = "migrated.legacyPreferences"

    static func run() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        // 沙盒下 NSHomeDirectoryForUser 也返回容器路径;POSIX getpwuid 才是真家目录
        guard let pw = getpwuid(getuid()), let pwDir = pw.pointee.pw_dir else { return }
        let legacy = URL(fileURLWithPath: String(cString: pwDir))
            .appendingPathComponent("Library/Preferences/\(plistName)")
        guard FileManager.default.fileExists(atPath: legacy.path) else { return }
        do {
            let data = try Data(contentsOf: legacy)
            guard let dict = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  !dict.isEmpty else { return }
            var merged = 0
            for (key, value) in dict where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
                merged += 1
            }
            defaults.set(true, forKey: doneKey)
            Log.info("app", "migrated \(merged)/\(dict.count) preference keys from legacy plist")
        } catch {
            // 沙盒例外缺失时会抛权限错误;不打 done 标记,下次启动再探
            Log.warn("app", "legacy preferences migration skipped: \(error)")
        }
    }
}
