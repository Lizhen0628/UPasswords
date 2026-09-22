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
        // 注意:不要加 .windowToolbarStyle——它与 SafeWindowConfigurator 的隐藏标题栏
        // 方案冲突,会在自绘条带上方再渲染一个系统标题区(残留的居中窗口标题)。
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
    func applicationWillFinishLaunching(_ notification: Notification) {
        Log.bootstrap()
        Log.info("app", "application will finish launching")
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
}
