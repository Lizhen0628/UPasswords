import SwiftUI
import AppKit

/// Entry point — AppDelegate keeps the dock menu / quit behaviors of the
/// original NSApplicationDelegate (Services/AppDelegate.h).
@main
struct UPasswordsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var ctx = AppContext.shared
    @StateObject private var toast = AppToast.shared
    @StateObject private var pwdSettings = PasswordSettings.shared

    init() {
        // 最早入口:横幅先落盘,后续每条日志(包括 AppContext bootstrap)都排在它后面
        Log.bootstrap()
    }

    var body: some Scene {
        WindowGroup(L10n.tBranded("app_title")) {
            RootView()
                .environmentObject(ctx)
                .environmentObject(toast)
                .environmentObject(pwdSettings)
                .environmentObject(ctx.settings)
        }
        // 注意:不要加 .windowToolbarStyle——它会再渲染一个系统标题区(残留的居中窗口标题)。
        // .windowStyle(.hiddenTitleBar) 是根治方案:SwiftUI 重设窗口样式时会把
        // 标题栏保持为隐藏/透明(与自绘条带一致),不再周期性翻转出系统材质带。
        // 锁屏/向导窗的标题条改由 PhaseTitleBar 自绘(见 SetupAndLock.swift)。
        .windowStyle(.hiddenTitleBar)
        .defaultSize(Self.bootSize)
        .commands { UPasswordsCommands() }

        Settings {
            PreferencesView()
                .environmentObject(ctx)
                .environmentObject(ctx.settings)
                .frame(minWidth: 560, minHeight: 420)
        }
    }

    /// DEBUG 专用:UP_SCREENSHOT_SIZE=WxH 覆盖默认窗口尺寸(截图对比用)。
    static var bootSize: CGSize {
        #if DEBUG
        if let spec = ProcessInfo.processInfo.environment["UP_SCREENSHOT_SIZE"] {
            let parts = spec.split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 { return CGSize(width: parts[0], height: parts[1]) }
        }
        #endif
        return CGSize(width: 970, height: 640)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 菜单栏状态图标(程序坞之外的常驻入口):钥匙模板图 + 快捷菜单
    private var statusItem: NSStatusItem?

    func applicationWillFinishLaunching(_ notification: Notification) {
        Log.bootstrap()
        Log.info("app", "application will finish launching")
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }   // 点程序坞图标时若无窗口则重新拉起
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        Log.debug("app", "last window closed → keeping app in dock (lock_if_window_closed)")
        return false // main window may be closed while app stays in dock (lock_if_window_closed)
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        Log.debug("app", "app active")
    }
    func applicationWillTerminate(_ notification: Notification) {
        Log.info("app", "application will terminate → flushing session save")
        AppContext.shared.save()
    }

    // MARK: - 菜单栏状态图标

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = item.button else { return }
        // 三钥匙 template 图(与程序坞图标同款设计);找不到资源时退回 SF 钥匙符号
        if let url = Bundle.main.url(forResource: "MenuBarKeys", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            img.size = NSSize(width: 18, height: 18)
            img.isTemplate = true   // 自动适配菜单栏深/浅色
            button.image = img
        } else {
            let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            if let img = NSImage(systemSymbolName: "key.fill", accessibilityDescription: "UPasswords")?
                .withSymbolConfiguration(cfg) {
                img.isTemplate = true
                button.image = img
            }
        }
        let menu = NSMenu()
        let show = NSMenuItem(title: "显示 UPasswords", action: #selector(showMainWindow), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        menu.addItem(.separator())
        let lock = NSMenuItem(title: L10n.t("lock_command"), action: #selector(lockNow), keyEquivalent: "")
        lock.target = self
        menu.addItem(lock)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 UPasswords",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
        Log.debug("app", "status item installed")
    }

    @MainActor @objc private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        for w in NSApp.windows where w.isVisible && w.frame.width > 200 {
            w.makeKeyAndOrderFront(self)
        }
    }

    @MainActor @objc private func lockNow() {
        AppContext.shared.lock()
        showMainWindow()
    }
}
