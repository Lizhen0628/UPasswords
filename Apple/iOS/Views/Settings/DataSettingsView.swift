import SwiftUI

import UPasswordsCore
import UPasswordsPersistence

// MARK: - 设置 › 数据

/// 数据子页:导出、导入与抹掉全部数据(危险操作集中于此,带二次确认)。
struct DataSettingsView: View {
    @EnvironmentObject var vault: Vault
    @Binding var activeSheet: SettingsView.ActiveSheet?

    @State private var showEraseConfirm = false

    var body: some View {
        Form {
            Section {
                Button { activeSheet = .export } label: {
                    Label(L10n.t("export_command"), systemImage: "square.and.arrow.up")
                        .foregroundStyle(.primary)
                }
                Button { activeSheet = .importData } label: {
                    Label(L10n.t("import_command"), systemImage: "square.and.arrow.down")
                        .foregroundStyle(.primary)
                }
            }
            Section {
                Button(role: .destructive) { showEraseConfirm = true } label: {
                    Label(L10n.t("ios_erase_all_button"), systemImage: "trash")
                }
            } footer: {
                Text(L10n.t("ios_data_section_footer"))
            }
        }
        .navigationTitle(L10n.t("ios_data_section"))
        .confirmationDialog(L10n.t("ios_erase_all_query"), isPresented: $showEraseConfirm, titleVisibility: .visible) {
            Button(L10n.t("ios_erase_all_button"), role: .destructive) { vault.eraseAll() }
            Button(L10n.t("cancel_button"), role: .cancel) {}
        } message: { Text(L10n.t("ios_erase_all_detail")) }
    }
}
