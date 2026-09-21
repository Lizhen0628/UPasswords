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

    var body: some Scene {
        WindowGroup(L10n.tBranded("app_title")) {
            RootView()
                .environmentObject(ctx)
                .environmentObject(toast)
                .environmentObject(pwdSettings)
                .environmentObject(ctx.settings)
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(CGSize(width: 970, height: 640))
        .commands { UPasswordsCommands() }

        Settings {
            PreferencesView()
                .environmentObject(ctx)
                .environmentObject(ctx.settings)
                .frame(minWidth: 560, minHeight: 420)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // main window may be closed while app stays in dock (lock_if_window_closed)
    }
    func applicationWillTerminate(_ notification: Notification) {
        AppContext.shared.save()
    }
}
