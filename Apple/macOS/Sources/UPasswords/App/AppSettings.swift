import Foundation
import SwiftUI
import AppKit
import UPasswordsCore
import UPasswordsPersistence

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
    /// 泄露库自动检查:解锁状态下按周期静默跑一次 HIBP;手动检查不受此开关限制。
    @Published var autoBreachCheckEnabled: Bool { didSet { d.set(autoBreachCheckEnabled, forKey: "sec.autoBreachCheck") } }
    @Published var autoBreachCheckDays: Int { didSet { d.set(autoBreachCheckDays, forKey: "sec.autoBreachCheckDays") } }

    // MARK: Lock screen
    /// 锁屏质感默认索引(黑→靛蓝对角渐变,右下泛紫光,同系统锁屏气质)。
    static let defaultLockTexture = 16
    /// texture index 0..16。
    @Published var lockTexture: Int { didSet { d.set(lockTexture, forKey: "lock.texture") } }
    @Published var lockWhiteText: Bool { didSet { d.set(lockWhiteText, forKey: "lock.whiteText") } }
    /// 锁屏背景类型:桌面壁纸(模糊压暗,macOS 原生风格,默认)/ 质感渐变 / 自定图片。
    @Published var lockBackgroundKindRaw: String {
        didSet { d.set(lockBackgroundKindRaw, forKey: "lock.backgroundKind") }
    }
    /// 自定图片文件名(存于 LockScreenImageStore.dir,空 = 未设置)。
    @Published var lockBackgroundImageName: String { didSet { d.set(lockBackgroundImageName, forKey: "lock.imageName") } }

    var lockBackgroundKind: LockBackgroundKind {
        LockBackgroundKind(rawValue: lockBackgroundKindRaw) ?? .wallpaper
    }

    /// 自定锁屏图片的当前文件 URL(未设置时为 nil)。
    var lockBackgroundImageURL: URL? {
        guard !lockBackgroundImageName.isEmpty else { return nil }
        return LockScreenImageStore.dir.appendingPathComponent(lockBackgroundImageName)
    }

    // MARK: Auto backup (AutoBackupViewController)
    @Published var autoBackupEnabled: Bool { didSet { d.set(autoBackupEnabled, forKey: "backup.enabled") } }
    /// backup_interval_setting days.
    @Published var backupIntervalDays: Int { didSet { d.set(backupIntervalDays, forKey: "backup.intervalDays") } }

    // MARK: Sync (ConfigureCloudViewController)
    @Published var cloudType: String { didSet { d.set(cloudType, forKey: "sync.cloud") } }
    @Published var webdav: WebDavSettings {
        didSet { saveCodable(webdav, key: "sync.webdav") }
    }
    /// 自动同步开关与间隔(秒):解锁状态下由常驻 ticker 按到期触发静默同步。
    @Published var autoSyncEnabled: Bool { didSet { d.set(autoSyncEnabled, forKey: "sync.autoEnabled") } }
    @Published var autoSyncSeconds: Int { didSet { d.set(autoSyncSeconds, forKey: "sync.autoSeconds") } }
    /// iCloud 云盘文件夹(沙盒下直读 CloudDocs 被禁,与 iOS 一样经安全作用域
    /// 书签访问用户选定的目录;未选择时回落旧直读路径,兼容未沙盒构建)。
    @Published var icloudFolderName: String { didSet { d.set(icloudFolderName, forKey: "sync.icloud.name") } }
    var icloudBookmark: Data? {
        get { d.data(forKey: "sync.icloud.bookmark") }
        set { d.set(newValue, forKey: "sync.icloud.bookmark") }
    }
    /// 所选文件夹语义:explicit = 文件夹本身是同步容器;root = 容器取其下 UPasswords/。
    var icloudFolderMode: String {
        get { d.string(forKey: "sync.icloud.mode") ?? "explicit" }
        set { d.set(newValue, forKey: "sync.icloud.mode") }
    }
    /// upasswords.com 信封同步加速通道(零知识,默认开;见 CloudEnvelopeService)。
    @Published var cloudAPIEnabled: Bool {
        didSet { d.set(cloudAPIEnabled, forKey: "sync.cloudAPI.enabled") }
    }

    // MARK: Misc
    /// 主窗口侧栏显隐(工具栏左一按钮切换,布局记忆跨启动保留)。
    @Published var sidebarVisible: Bool { didSet { d.set(sidebarVisible, forKey: "app.sidebarVisible") } }
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
        autoBreachCheckEnabled = d.object(forKey: "sec.autoBreachCheck") as? Bool ?? false
        autoBreachCheckDays = d.object(forKey: "sec.autoBreachCheckDays") as? Int ?? 7
        lockTexture = d.object(forKey: "lock.texture") as? Int ?? Self.defaultLockTexture
        lockWhiteText = d.object(forKey: "lock.whiteText") as? Bool ?? true
        // 旧版只有「是否用自定图片」布尔键,迁移为三态背景类型(默认壁纸模糊)
        lockBackgroundKindRaw = d.string(forKey: "lock.backgroundKind")
            ?? ((d.object(forKey: "lock.usesImage") as? Bool ?? false)
                ? LockBackgroundKind.image.rawValue : LockBackgroundKind.wallpaper.rawValue)
        lockBackgroundImageName = d.string(forKey: "lock.imageName") ?? ""
        autoBackupEnabled = d.object(forKey: "backup.enabled") as? Bool ?? false
        backupIntervalDays = d.object(forKey: "backup.intervalDays") as? Int ?? 7
        cloudType = d.string(forKey: "sync.cloud") ?? CloudType.none.rawValue
        webdav = Self.loadCodable(WebDavSettings.self, key: "sync.webdav") ?? WebDavSettings()
        autoSyncEnabled = d.object(forKey: "sync.autoEnabled") as? Bool ?? false
        autoSyncSeconds = d.object(forKey: "sync.autoSeconds") as? Int ?? 60
        icloudFolderName = d.string(forKey: "sync.icloud.name") ?? ""
        cloudAPIEnabled = d.object(forKey: "sync.cloudAPI.enabled") as? Bool ?? true
        sidebarVisible = d.object(forKey: "app.sidebarVisible") as? Bool ?? true
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

/// 锁定/显示主界面菜单快捷键的存储与广播:
/// 设置面板的录制控件写入,Commands 观察它即时刷新菜单快捷键。
/// key 为按键字符(小写,空 = 无快捷键),modifiers 为 NSEvent.ModifierFlags rawValue。
@MainActor
final class ShortcutStore: ObservableObject {
    static let shared = ShortcutStore()
    private let d = UserDefaults.standard

    static let lockKeyDefaults = "sc.lockKey"
    static let lockModsDefaults = "sc.lockMods"
    static let showMainKeyDefaults = "sc.showMainKey"
    static let showMainModsDefaults = "sc.showMainMods"

    @Published var lockKey: String { didSet { d.set(lockKey, forKey: Self.lockKeyDefaults) } }
    @Published var lockModifiers: Int { didSet { d.set(lockModifiers, forKey: Self.lockModsDefaults) } }
    @Published var showMainKey: String { didSet { d.set(showMainKey, forKey: Self.showMainKeyDefaults) } }
    @Published var showMainModifiers: Int { didSet { d.set(showMainModifiers, forKey: Self.showMainModsDefaults) } }

    private init() {
        lockKey = d.string(forKey: Self.lockKeyDefaults) ?? "l"
        lockModifiers = d.object(forKey: Self.lockModsDefaults) as? Int
            ?? Int(NSEvent.ModifierFlags.command.union(.control).rawValue)
        showMainKey = d.string(forKey: Self.showMainKeyDefaults) ?? "m"
        showMainModifiers = d.object(forKey: Self.showMainModsDefaults) as? Int
            ?? Int(NSEvent.ModifierFlags.command.union(.control).rawValue)
    }
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

/// 锁屏背景类型。
enum LockBackgroundKind: String {
    /// 桌面壁纸模糊压暗(macOS 原生锁屏风格,默认)。
    case wallpaper
    /// 程序内置质感渐变。
    case texture
    /// 用户自定图片。
    case image
}

/// 锁屏背景视图(设置页预览与真实锁屏共用)。
enum LockScreenBackground {
    @ViewBuilder
    static func view(kind: LockBackgroundKind, textureIndex: Int, imageName: String) -> some View {
        switch kind {
        case .wallpaper:
            if let wallpaper = desktopWallpaper() {
                // 原生锁屏气质:壁纸铺满 → 重模糊压暗;轻微放大遮住模糊边缘的透明毛边
                Image(nsImage: wallpaper)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 40)
                    .overlay(Color.black.opacity(0.35))
                    .scaleEffect(1.08)
            } else {
                LockTextures.gradient(for: textureIndex)
            }
        case .texture:
            LockTextures.gradient(for: textureIndex)
        case .image:
            if let image = LockScreenImageStore.image(named: imageName) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                LockTextures.gradient(for: textureIndex)
            }
        }
    }

    /// 主屏桌面壁纸(动态壁纸取当前解析文件,取不到返回 nil)。
    static func desktopWallpaper() -> NSImage? {
        guard let screen = NSScreen.main,
              let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        return NSImage(contentsOf: url)
    }
}
