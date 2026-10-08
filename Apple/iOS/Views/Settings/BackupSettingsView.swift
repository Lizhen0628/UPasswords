import SwiftUI

import UPasswordsCore
import UPasswordsPersistence

// MARK: - 设置 › 备份

/// 备份子页:立即备份、自动备份策略与备份列表。
struct BackupSettingsView: View {
    @EnvironmentObject var vault: Vault
    @Binding var activeSheet: SettingsView.ActiveSheet?

    var body: some View {
        Form {
            Section {
                Button { vault.backupNow() } label: {
                    Label(L10n.t("ios_backup_now_button"), systemImage: "externaldrive.badge.timemachine")
                        .foregroundStyle(.primary)
                }
                Toggle(isOn: $vault.autoBackupEnabled) {
                    Label(L10n.t("auto_backup_setting"), systemImage: "clock.badge.checkmark")
                }
                .tint(Brand.accent)
                if vault.autoBackupEnabled {
                    Picker(selection: $vault.autoBackupIntervalDays) {
                        ForEach([1, 7, 30], id: \.self) { days in
                            Text("\(days)\(L10n.t("days_text"))").tag(days)
                        }
                    } label: {
                        Label(L10n.t("backup_interval_setting"), systemImage: "calendar.badge.clock")
                    }
                }
                Button { activeSheet = .backups } label: {
                    Label(L10n.t("ios_backup_list_button"), systemImage: "externaldrive")
                        .foregroundStyle(.primary)
                }
            } footer: {
                Text(L10n.t("ios_backup_section_footer"))
            }
        }
        .navigationTitle(L10n.t("ios_backup_section_title"))
    }
}
