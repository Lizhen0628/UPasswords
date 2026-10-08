import AppKit

import UPasswordsCore
import UPasswordsPersistence

/// 切换密码库:先验证目标库解锁密码,成功才切换。
extension AppContext {

    /// 弹窗要求输入目标库的解锁密码,验证通过后直接切换并解锁;
    /// 取消或失败则留在当前会话(密码错误可原地重试)。
    /// 供「管理密码库」弹窗与菜单栏「切换密码库」共用。
    /// - Parameter name: 目标库名
    /// - Returns: 是否切换成功
    @discardableResult
    func promptUnlockAndSwitch(to name: String) -> Bool {
        guard name != databaseName || phase == .locked else { return true }
        let alert = NSAlert()
        alert.messageText = String(format: L10n.t("switch_database_unlock_title"), name)
        alert.informativeText = L10n.t("switch_database_unlock_message")
        alert.addButton(withTitle: L10n.t("unlock_button"))
        alert.addButton(withTitle: L10n.t("cancel_button"))
        let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        NSApp.activate(ignoringOtherApps: true)
        while true {
            guard alert.runModal() == .alertFirstButtonReturn else {
                Log.info("db", "switch to \"\(name)\" cancelled at password prompt")
                return false
            }
            do {
                try unlock(name: name, password: input.stringValue)
                store.mainDatabaseName = name
                activeSheet = nil
                Log.info("db", "switched to \"\(name)\" after password verify")
                return true
            } catch {
                Log.warn("db", "switch to \"\(name)\" failed: wrong password")
                alert.informativeText = L10n.t("wrong_password_error")
                input.stringValue = ""
            }
        }
    }
}
