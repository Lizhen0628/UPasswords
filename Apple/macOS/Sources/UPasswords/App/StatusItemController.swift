import AppKit
import UPasswordsCore

/// 菜单栏状态图标(程序坞之外的常驻入口):三钥匙 template 图 + 快捷菜单。
@MainActor
final class StatusItemController: NSObject {
    private var statusItem: NSStatusItem?

    /// 无状态构造,允许在 AppDelegate 的非隔离 init 中创建。
    nonisolated override init() {}

    /// 由 RootView 注入的 SwiftUI openWindow 动作:窗口被关闭后
    /// (应用仍驻留程序坞)据此重建主窗口。
    private(set) static var openMainWindow: () -> Void = {}

    static func registerOpenWindow(_ action: @escaping () -> Void) {
        openMainWindow = action
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = item.button else {
            Log.warn("app", "status item install failed: no button")
            return
        }
        button.image = Self.loadIcon()
        item.menu = makeMenu()
        statusItem = item
        Log.info("app", "status item installed")
    }

    // MARK: - Icon

    /// 三钥匙 template 图(与程序坞图标同款设计,由 AppIconMaster 提取剪影);
    /// 找不到资源时退回 SF 钥匙符号。template 模式自动适配菜单栏深/浅色。
    private static func loadIcon() -> NSImage? {
        let url = AppResources.bundle.url(forResource: "MenuBarKeys", withExtension: "png")
            ?? Bundle.main.url(forResource: "MenuBarKeys", withExtension: "png")
        if let url, let img = NSImage(contentsOf: url) {
            img.size = NSSize(width: 18, height: 18)
            img.isTemplate = true
            return img
        }
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let img = NSImage(systemSymbolName: "key.fill", accessibilityDescription: "UPasswords")?
            .withSymbolConfiguration(cfg)
        img?.isTemplate = true
        return img
    }

    // MARK: - Menu

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let show = NSMenuItem(title: L10n.t("show_command"), action: #selector(showMainWindowAction), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        // 切换密码库:列出全部库,勾选当前;点击后回锁屏预填新库名
        let switchItem = NSMenuItem(title: L10n.t("switch_database_command"), action: nil, keyEquivalent: "")
        let switchMenu = NSMenu()
        switchMenu.delegate = self
        switchItem.submenu = switchMenu
        menu.addItem(switchItem)
        menu.addItem(.separator())
        let lock = NSMenuItem(title: L10n.t("lock_command"), action: #selector(lockNow), keyEquivalent: "")
        lock.target = self
        menu.addItem(lock)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L10n.tBranded("quit_command"),
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        return menu
    }

    @objc private func switchDatabaseAction(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        Log.info("db", "menu bar switch database → \"\(name)\"")
        if AppContext.shared.promptUnlockAndSwitch(to: name) {
            Self.showMainWindow()
        }
    }

    // MARK: - Actions

    static func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        let visible = NSApp.windows.filter { $0.isVisible && $0.frame.width > 200 }
        if visible.isEmpty {
            openMainWindow()  // 主窗口已关闭:经 SwiftUI openWindow 重建
        } else {
            for w in visible { w.makeKeyAndOrderFront(nil) }
        }
    }

    @objc private func showMainWindowAction() {
        Log.info("ui", "status menu: show main window")
        Self.showMainWindow()
    }

    @objc private func lockNow() {
        Log.info("ui", "status menu: lock now")
        AppContext.shared.lock()
        Self.showMainWindow()
    }
}

// MARK: - NSMenuDelegate

extension StatusItemController: NSMenuDelegate {
    /// 「切换密码库」子菜单每次展开前重建:文件列表可能已增删。
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let ctx = AppContext.shared
        for db in ctx.dbsInfo() {
            let item = NSMenuItem(title: db.name, action: #selector(switchDatabaseAction), keyEquivalent: "")
            item.target = self
            item.representedObject = db.name
            item.state = db.name == ctx.databaseName ? .on : .off
            menu.addItem(item)
        }
    }
}
