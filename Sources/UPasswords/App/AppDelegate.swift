import AppKit

/// Application delegate — dock reopen / quit behaviors.
/// 菜单栏常驻入口由 StatusItemController 承担。
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = StatusItemController()

    func applicationWillFinishLaunching(_ notification: Notification) {
        Log.bootstrap()
        Log.info("app", "application will finish launching")
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.install()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // 点程序坞图标时若无窗口则重新拉起;返回 false 阻止系统重复处理
        if !flag {
            StatusItemController.showMainWindow()
            return false
        }
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
        Log.flush()
    }
}
