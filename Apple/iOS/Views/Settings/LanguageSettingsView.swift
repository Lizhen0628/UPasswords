import SwiftUI

import UPasswordsCore
import UPasswordsPersistence

// MARK: - 设置 › 语言

/// 语言子页:应用内语言切换,复用 Core L10n 的 app.language 覆盖,立即生效;
/// 语言名按各自语言展示(通用做法),新增语言只需补充 lproj 字符串表。
struct LanguageSettingsView: View {
    @EnvironmentObject var vault: Vault

    var body: some View {
        Form {
            Section {
                Picker(selection: $vault.language) {
                    Text(L10n.t("ios_language_system")).tag("")
                    Text("English").tag("en")
                    Text("简体中文").tag("zh-Hans")
                } label: {
                    Label(L10n.t("ios_language_label"), systemImage: "globe")
                }
            } footer: {
                Text(L10n.t("ios_language_footer"))
            }
        }
        .navigationTitle(L10n.t("ios_language_section"))
    }
}
