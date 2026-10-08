import SwiftUI

import UPasswordsCore
import UPasswordsPersistence

// MARK: - 设置 › 密码库

/// 密码库子页:多库管理、新建与导入。
struct VaultsSettingsView: View {
    @Binding var activeSheet: SettingsView.ActiveSheet?

    var body: some View {
        Form {
            Section {
                Button { activeSheet = .manageVaults } label: {
                    Label(L10n.t("ios_db_manage_button"), systemImage: "externaldrive")
                        .foregroundStyle(.primary)
                }
                .accessibilityIdentifier("settings.manageVaults")
                Button { activeSheet = .createDatabase } label: {
                    Label(L10n.t("ios_db_new_button"), systemImage: "plus.square.dashed")
                        .foregroundStyle(.primary)
                }
                Button { activeSheet = .importDatabase } label: {
                    Label(L10n.t("ios_db_import_button"), systemImage: "icloud.and.arrow.down")
                        .foregroundStyle(.primary)
                }
            } footer: {
                Text(L10n.t("ios_databases_section_footer"))
            }
        }
        .navigationTitle(L10n.t("ios_databases_section_title"))
    }
}
