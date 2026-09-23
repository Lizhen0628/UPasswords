import AppKit

/// 菜单栏状态图标(程序坞之外的常驻入口):三钥匙 template 图 + 快捷菜单。
@MainActor
final class StatusItemController {
    private var statusItem: NSStatusItem?

    /// 无状态构造,允许在 AppDelegate 的非隔离 init 中创建。
    nonisolated init() {}

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
        let url = Bundle.module.url(forResource: "MenuBarKeys", withExtension: "png")
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
