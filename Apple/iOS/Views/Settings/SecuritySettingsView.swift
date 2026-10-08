import SwiftUI

import UPasswordsCore
import UPasswordsPersistence

// MARK: - 设置 › 安全

/// 安全子页:Face ID、修改主密码、自动锁定、剪贴板清除与泄露检查。
struct SecuritySettingsView: View {
    @EnvironmentObject var vault: Vault
    @Binding var activeSheet: SettingsView.ActiveSheet?

    /// 自定义档位的分钟数(选择自定义时从当前值推导)。
    @State private var customMinutes = 10
    /// 预设档位(秒);不在其中即为自定义。
    private static let autoLockPresets = [0, 60, 300, 900]

    /// 自动锁定选择:-1 表示自定义分钟数。
    private var autoLockSelection: Binding<Int> {
        Binding(
            get: { Self.autoLockPresets.contains(vault.autoLockSeconds) ? vault.autoLockSeconds : -1 },
            set: { newValue in
                if newValue == -1 {
                    let minutes = vault.autoLockSeconds > 0 ? max(1, vault.autoLockSeconds / 60) : customMinutes
                    customMinutes = minutes
                    vault.autoLockSeconds = minutes * 60
                } else {
                    vault.autoLockSeconds = newValue
                }
            }
        )
    }

    /// 自定义分钟数双向绑定:改动即写回 vault 持久化。
    private var customMinutesBinding: Binding<Int> {
        Binding(
            get: { customMinutes },
            set: { customMinutes = $0; vault.autoLockSeconds = $0 * 60 }
        )
    }

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
                Picker(selection: autoLockSelection) {
                    Text(L10n.t("ios_autolock_immediately")).tag(0)
                    Text(String(format: L10n.t("ios_minutes_fmt"), 1)).tag(60)
                    Text(String(format: L10n.t("ios_minutes_fmt"), 5)).tag(300)
                    Text(String(format: L10n.t("ios_minutes_fmt"), 15)).tag(900)
                    Text(L10n.t("ios_autolock_custom")).tag(-1)
                } label: {
                    Label(L10n.t("ios_autolock_label"), systemImage: "lock.clock")
                }
                if autoLockSelection.wrappedValue == -1 {
                    Stepper(value: customMinutesBinding, in: 1...120) {
                        Text(String(format: L10n.t("ios_minutes_fmt"), customMinutes))
                    }
                    .tint(Brand.accent)
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
