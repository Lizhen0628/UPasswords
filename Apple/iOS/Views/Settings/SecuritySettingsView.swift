import SwiftUI

import UPasswordsCore
import UPasswordsPersistence

// MARK: - 设置 › 安全

/// 安全子页:Face ID、修改主密码、自动锁定、剪贴板清除与泄露检查。
struct SecuritySettingsView: View {
    @EnvironmentObject var vault: Vault
    @Binding var activeSheet: SettingsView.ActiveSheet?

    var body: some View {
        Form {
            Section {
                if vault.biometricAvailable {
                    Toggle(isOn: $vault.faceIDEnabled) {
                        Label(L10n.t("ios_faceid_toggle"), systemImage: "faceid")
                    }
                    .tint(Brand.accent)
                }
                Button { activeSheet = .changePassword } label: {
                    Label(L10n.t("ios_change_master_button"), systemImage: "lock.rotation")
                        .foregroundStyle(.primary)
                }
                Picker(selection: $vault.autoLockSeconds) {
                    Text(L10n.t("ios_autolock_immediately")).tag(0)
                    Text(String(format: L10n.t("ios_minutes_fmt"), 1)).tag(60)
                    Text(String(format: L10n.t("ios_minutes_fmt"), 5)).tag(300)
                    Text(String(format: L10n.t("ios_minutes_fmt"), 15)).tag(900)
                } label: {
                    Label(L10n.t("ios_autolock_label"), systemImage: "lock.clock")
                }
            }
            Section {
                Picker(selection: $vault.clipboardClearSeconds) {
                    Text(L10n.t("ios_clipboard_keep")).tag(0)
                    Text(String(format: L10n.t("ios_seconds_fmt"), 30)).tag(30)
                    Text(String(format: L10n.t("ios_seconds_fmt"), 90)).tag(90)
                    Text(String(format: L10n.t("ios_minutes_fmt"), 3)).tag(180)
                } label: {
                    Label(L10n.t("ios_clipboard_clear_label"), systemImage: "clipboard")
                }
            }
            Section {
                Toggle(isOn: $vault.autoBreachCheckEnabled) {
                    Label(L10n.t("auto_breach_check_setting"), systemImage: "exclamationmark.shield")
                }
                .tint(Brand.accent)
                if vault.autoBreachCheckEnabled {
                    Picker(selection: $vault.autoBreachCheckDays) {
                        ForEach([1, 7, 30], id: \.self) { days in
                            Text("\(days)\(L10n.t("days_text"))").tag(days)
                        }
                    } label: {
                        Label(L10n.t("breach_check_interval_setting"), systemImage: "calendar.badge.clock")
                    }
                }
            }
        }
        .navigationTitle(L10n.t("ios_tab_security"))
    }
}
