import SwiftUI
import UniformTypeIdentifiers

import UPasswordsCore
import UPasswordsPersistence

// MARK: - 设置域共享弹层与桥接视图

// MARK: 修改主密码

/// 收集当前与新主密码，将验证、密钥轮换及持久化交由会话层。
struct ChangePasswordSheet: View {
    @EnvironmentObject var vault: Vault
    @Environment(\.dismiss) private var dismiss

    @State private var old = ""
    @State private var new = ""
    @State private var confirm = ""
    @State private var error: String? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField(L10n.t("ios_current_master_prompt"), text: $old)
                    SecureField(L10n.t("ios_new_master_prompt"), text: $new)
                    SecureField(L10n.t("ios_master_password_confirm_prompt"), text: $confirm)
                }
                if let error {
                    Section {
                        Text(error).foregroundStyle(.red).font(.footnote)
                    }
                }
            }
            .navigationTitle(L10n.t("ios_change_master_button"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.t("cancel_button")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("ios_save_button")) { save() }
                        .disabled(old.isEmpty || new.count < PasswordPolicy.minimumMasterPasswordLength)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        guard new == confirm else { error = L10n.t("ios_password_mismatch_error"); return }
        guard vault.verifyMaster(old) else { error = L10n.t("ios_wrong_password_error"); return }
        // 改密落盘失败(rewrap/存储异常)不得谎报成功
        guard vault.changeMasterPassword(old: old, new: new) else {
            error = L10n.t("ios_wrong_password_error")
            return
        }
        vault.showToast(L10n.t("ios_master_changed_message"))
        dismiss()
    }
}

// MARK: 系统分享面板

/// 将待分享内容交给系统分享控制器的 SwiftUI 桥接。
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: 自动填充开启指引

/// 展示系统凭据自动填充的配置步骤。
struct AutoFillGuideView: View {
    @Environment(\.dismiss) private var dismiss

    private var steps: [String] {
        [L10n.t("ios_autofill_step_1"), L10n.t("ios_autofill_step_2"),
         L10n.t("ios_autofill_step_3"), L10n.t("ios_autofill_step_4")]
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(Array(steps.enumerated()), id: \.offset) { i, text in
                        HStack(alignment: .top, spacing: 12) {
                            Text("\(i + 1)")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(width: 24, height: 24)
                                .background(Brand.accent, in: Circle())
                            Text(text)
                                .font(.system(size: 15))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text(L10n.t("ios_autofill_steps_section"))
                } footer: {
                    Text(L10n.t("ios_autofill_steps_footer"))
                }

                Section {
                    Text(L10n.t("ios_registration_safari_steps"))
                } header: {
                    Text(L10n.t("registration_autofill_setting"))
                }

                Section {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Label(L10n.t("ios_open_settings_button"), systemImage: "gear")
                            .foregroundStyle(Brand.accent)
                    }
                }
            }
            .navigationTitle(L10n.t("ios_autofill_guide_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("ios_done_button")) { dismiss() }
                }
            }
        }
    }
}
