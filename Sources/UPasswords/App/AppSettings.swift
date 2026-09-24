import Foundation
import SwiftUI

/// App-level settings persisted in UserDefaults — the union of
/// AppearanceViewController / SecurityViewController / AutoBackupViewController
/// / SelectTextureSheetController option keys.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    // MARK: Appearance
    @Published var languageOverride: String { didSet { d.set(languageOverride, forKey: "app.language") } }
    @Published var sorting: Sorting.RawValue { didSet { d.set(sorting, forKey: "app.sorting") } }
    @Published var favoritesAtTop: Bool { didSet { d.set(favoritesAtTop, forKey: "app.favoritesAtTop") } }
    @Published var showCardCount: Bool { didSet { d.set(showCardCount, forKey: "app.showCardCount") } }
    @Published var hidePasswords: Bool { didSet { d.set(hidePasswords, forKey: "app.hidePasswords") } }
    @Published var searchByLabels: Bool { didSet { d.set(searchByLabels, forKey: "app.searchByLabels") } }
    @Published var searchPasswords: Bool { didSet { d.set(searchPasswords, forKey: "app.searchPasswords") } }
    @Published var useWebsiteIcons: Bool { didSet { d.set(useWebsiteIcons, forKey: "app.useWebsiteIcons") } }

    var sortingValue: Sorting {
        get { Sorting(rawValue: sorting) ?? .titleAsc }
        set { sorting = newValue.rawValue }
    }

    // MARK: Security
    /// auto_lock_setting seconds: 0=never 60 300 900 3600.
    @Published var autoLockSeconds: Int { didSet { d.set(autoLockSeconds, forKey: "sec.autoLock") } }
    @Published var lockInBackground: Bool { didSet { d.set(lockInBackground, forKey: "sec.lockInBackground") } }
    @Published var lockIfWindowClosed: Bool { didSet { d.set(lockIfWindowClosed, forKey: "sec.lockIfWindowClosed") } }
    /// require_password_setting seconds: 0=never … forces password over Touch ID.
    @Published var requirePasswordSeconds: Int { didSet { d.set(requirePasswordSeconds, forKey: "sec.requirePassword") } }
    @Published var fastUnlock: Bool { didSet { d.set(fastUnlock, forKey: "sec.fastUnlock") } }
    @Published var selfDestructAttempts: Int { didSet { d.set(selfDestructAttempts, forKey: "sec.selfDestruct") } }
    /// empty_clipboard_setting seconds: 0=off 10 30 60 120.
    @Published var clipboardClearSeconds: Int { didSet { d.set(clipboardClearSeconds, forKey: "clipboard.clearSeconds") } }

    // MARK: Lock screen
    /// texture index 0..16。
    @Published var lockTexture: Int { didSet { d.set(lockTexture, forKey: "lock.texture") } }
    @Published var lockWhiteText: Bool { didSet { d.set(lockWhiteText, forKey: "lock.whiteText") } }

    // MARK: Auto backup (AutoBackupViewController)
    @Published var autoBackupEnabled: Bool { didSet { d.set(autoBackupEnabled, forKey: "backup.enabled") } }
    /// backup_interval_setting days.
    @Published var backupIntervalDays: Int { didSet { d.set(backupIntervalDays, forKey: "backup.intervalDays") } }

    // MARK: Sync (ConfigureCloudViewController)
    @Published var cloudType: String { didSet { d.set(cloudType, forKey: "sync.cloud") } }
    @Published var webdav: WebDavSettings {
        didSet { saveCodable(webdav, key: "sync.webdav") }
    }

    // MARK: Misc
    /// Optional sidebar rows (密码/文件/图片) shown through the 「显示」 menu.
    @Published var sidebarOptionalItems: [String] {
        didSet { d.set(sidebarOptionalItems.joined(separator: ","), forKey: "app.sidebarOptional") }
    }
    @Published var showWhatsNewAtStartup: Bool { didSet { d.set(showWhatsNewAtStartup, forKey: "whatsnew.atStartup") } }
    var lastWhatsNewVersion: String {
        get { d.string(forKey: "whatsnew.lastVersion") ?? "" }
        set { d.set(newValue, forKey: "whatsnew.lastVersion") }
    }

    init() {
        languageOverride = d.string(forKey: "app.language") ?? ""
        sorting = d.string(forKey: "app.sorting") ?? Sorting.titleAsc.rawValue
        favoritesAtTop = d.object(forKey: "app.favoritesAtTop") as? Bool ?? true
        showCardCount = d.object(forKey: "app.showCardCount") as? Bool ?? true
        hidePasswords = d.object(forKey: "app.hidePasswords") as? Bool ?? true
        searchByLabels = d.object(forKey: "app.searchByLabels") as? Bool ?? true
        searchPasswords = d.object(forKey: "app.searchPasswords") as? Bool ?? false
        useWebsiteIcons = d.object(forKey: "app.useWebsiteIcons") as? Bool ?? true
        autoLockSeconds = d.object(forKey: "sec.autoLock") as? Int ?? 300
        lockInBackground = d.object(forKey: "sec.lockInBackground") as? Bool ?? true
        lockIfWindowClosed = d.object(forKey: "sec.lockIfWindowClosed") as? Bool ?? false
        requirePasswordSeconds = d.object(forKey: "sec.requirePassword") as? Int ?? 0
        fastUnlock = d.object(forKey: "sec.fastUnlock") as? Bool ?? true
        selfDestructAttempts = d.object(forKey: "sec.selfDestruct") as? Int ?? 0
        clipboardClearSeconds = d.object(forKey: "clipboard.clearSeconds") as? Int ?? 60
        lockTexture = d.object(forKey: "lock.texture") as? Int ?? 12   // 默认深灰(原 0 是亮紫渐变)
        lockWhiteText = d.object(forKey: "lock.whiteText") as? Bool ?? true
        autoBackupEnabled = d.object(forKey: "backup.enabled") as? Bool ?? false
        backupIntervalDays = d.object(forKey: "backup.intervalDays") as? Int ?? 7
        cloudType = d.string(forKey: "sync.cloud") ?? CloudType.none.rawValue
        webdav = Self.loadCodable(WebDavSettings.self, key: "sync.webdav") ?? WebDavSettings()
        sidebarOptionalItems = (d.string(forKey: "app.sidebarOptional") ?? "")
            .split(separator: ",").map(String.init).filter { !$0.isEmpty }
        showWhatsNewAtStartup = d.object(forKey: "whatsnew.atStartup") as? Bool ?? true
    }

    private func saveCodable<T: Encodable>(_ v: T, key: String) {
        if let data = try? JSONEncoder().encode(v) { d.set(data, forKey: key) }
    }
    private static func loadCodable<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    var cloud: CloudType { CloudType(rawValue: cloudType) ?? .none }
}

/// The 8 first-run setup tasks — values are Localizable keys;
/// order matches the setup checklist.
enum SetupPlanTask: String, CaseIterable, Identifiable {
    case cloudSync = "cloud_sync_task"
    case importPasswords = "import_passwords_task"
    case touchID = "touch_id_task"
    case securitySettings = "security_settings_task"
    case autoBackup = "auto_backup_task"
    case autofill = "autofill_task"
    case installOnMobile = "install_on_mobile_task"
    case uiPreferences = "ui_preferences_task"

    var id: String { rawValue }
    var name: String { L10n.t(rawValue) }

    var systemImage: String {
        switch self {
        case .cloudSync: return "icloud"
        case .importPasswords: return "square.and.arrow.down.on.square"
        case .touchID: return "touchid"
        case .securitySettings: return "lock.shield"
        case .autoBackup: return "externaldrive.badge.timemachine"
        case .autofill: return "iphone.gen3"
        case .installOnMobile: return "iphone"
        case .uiPreferences: return "paintbrush"
        }
    }
}

/// 17 procedural lock-screen textures (programmatically drawn gradients).
enum LockTextures {
    static let count = 17

    static func gradient(for index: Int) -> LinearGradient {
        let palettes: [(Color, Color)] = [
            (.indigo, .purple), (.teal, .cyan), (.orange, .pink), (.green, .teal),
            (.blue, .indigo), (.pink, .purple), (.red, .orange), (.mint, .green),
            (.cyan, .blue), (.yellow, .orange), (.purple, .indigo), (.teal, .green),
            (.gray, .black), (.brown, .orange), (.indigo, .mint), (.orange, .red),
            (.black, .indigo),
        ]
        let (a, b) = palettes[index % palettes.count]
        return LinearGradient(colors: [a, b], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
