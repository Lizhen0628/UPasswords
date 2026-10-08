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

extension AppContext {
    /// 远端被「其他设备改后的新密码」加密时的接管弹窗:输入新密码 →
    /// 合并+换密+重传;密码错误提示后可重新打开重试。
    func promptAdoptRemotePassword() {
        let alert = NSAlert()
        alert.messageText = L10n.t("ios_sync_adopt_password_title")
        alert.informativeText = L10n.t("ios_sync_adopt_password_message")
        alert.addButton(withTitle: L10n.t("unlock_button"))
        alert.addButton(withTitle: L10n.t("cancel_button"))
        let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn, !input.stringValue.isEmpty else {
            Log.info("sync", "adopt remote password cancelled at prompt")
            return
        }
        let pw = input.stringValue
        Task {
            let ok = await adoptRemotePassword(pw)
            if !ok {
                AppToast.shared.show(L10n.t("wrong_password_error"))
            } else {
                AppToast.shared.show(L10n.t("last_sync_completed_prompt"))
            }
        }
    }

    /// 「用本地数据覆盖云端」的确认弹窗(丢弃远端内容,须用户明确确认)。
    func promptOverwriteUnreadableRemote() {
        let alert = NSAlert()
        alert.messageText = L10n.t("ios_sync_overwrite_cloud_button")
        alert.informativeText = L10n.t("ios_sync_overwrite_cloud_query")
        alert.addButton(withTitle: L10n.t("ok_button"))
        alert.addButton(withTitle: L10n.t("cancel_button"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await overwriteUnreadableRemote() }
    }
}
