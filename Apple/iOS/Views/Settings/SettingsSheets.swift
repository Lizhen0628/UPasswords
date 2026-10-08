import SwiftUI
import UniformTypeIdentifiers

import UPasswordsCore
import UPasswordsPersistence

// MARK: - 设置域共享弹层与桥接视图

// MARK: 修改主密码

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
                        .disabled(old.isEmpty || new.count < 4)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        guard new == confirm else { error = L10n.t("ios_password_mismatch_error"); return }
        guard vault.verifyMaster(old) else { error = L10n.t("ios_wrong_password_error"); return }
        _ = vault.changeMasterPassword(old: old, new: new)
        vault.showToast(L10n.t("ios_master_changed_message"))
        dismiss()
    }
}

// MARK: 系统分享面板

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: 云盘文件夹选择(iOS 沙盒获取云端目录安全作用域访问权的唯一入口)

struct FolderPickerView: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void

        init(onPick: @escaping (URL) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            Log.info("sync", "ios folder picker returned \"\(url.lastPathComponent)\"")
            onPick(url)
        }
    }
}

// MARK: 自动填充开启指引

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
