import AppKit

import UPasswordsCore

/// 独立 Safari 扩展容器 App:不含任何密码库逻辑——扩展的登录/解锁/填充
/// 全部经 relay API 直连(见 WebExtensions/safari/src)。此 App 的唯一职责是
/// 承载 SafariWebExtension.appex 供 Safari 注册(LSUIElement,无 Dock 图标)。
@main
enum SafariAppMain {
    static func main() {
        Log.bootstrap()
        Log.info("app", "standalone safari container launched")
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {}
