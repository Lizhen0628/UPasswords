import SwiftUI
import UniformTypeIdentifiers

import UPasswordsCore
import UPasswordsPersistence

// MARK: - 导出(XML/CSV/TXT,与 macOS ExportCardsTask 同一套格式;XML 可回导)

/// 选择导出格式并生成明文文件；加密库备份由独立备份流程负责。
struct ExportAsSheet: View {
    @EnvironmentObject var vault: Vault
    @Environment(\.dismiss) private var dismiss

    @State private var shareItems: [Any] = []
    @State private var showShare = false
    // 导出前验密:数据文件一旦落盘即为明文,必须确认持库者本人
    @State private var pendingFormat: ExportFormat? = nil
    @State private var gatePassword = ""
    @State private var showGate = false
    @State private var gateFailed = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(ExportFormat.allCases) { format in
                        Button {
                            pendingFormat = format
                            gatePassword = ""
                            gateFailed = false
                            showGate = true
                        } label: {
                            Label(format.name, systemImage: icon(format))
                                .foregroundStyle(.primary)
                        }
                    }
                } footer: {
                    Text(L10n.t("confirm_export_query"))
                }
            }
            .navigationTitle(L10n.t("export_as_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("cancel_button")) { dismiss() }
                }
            }
            .sheet(isPresented: $showShare) { ActivityView(items: shareItems) }
            .sheet(isPresented: $showGate) { passwordGate }
        }
    }

    /// 导出验密弹层:输入库主密码验证通过后才生成数据文件。
    private var passwordGate: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField(L10n.t("export_password_prompt"), text: $gatePassword)
                } footer: {
                    Text(L10n.t("export_password_hint"))
                }
                if gateFailed {
                    Text(L10n.t("wrong_password_error"))
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle(L10n.t("export_as_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("cancel_button")) {
                        showGate = false
                        pendingFormat = nil
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("continue_button")) {
                        guard vault.verifyMaster(gatePassword) else {
                            gateFailed = true
                            gatePassword = ""
                            Log.warn("app", "ios export rejected: wrong vault password")
                            return
                        }
                        showGate = false
                        if let format = pendingFormat {
                            export(format)
                        }
                        pendingFormat = nil
                        gatePassword = ""
                    }
                    .disabled(gatePassword.isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func icon(_ format: ExportFormat) -> String {
        switch format {
        case .xml: return "doc.text"
        case .csv: return "tablecells"
        case .txt: return "doc.plaintext"
        }
    }

    /// XML 导全量(含模板与标签,可回导);CSV/TXT 只导非模板条目。
    private func export(_ format: ExportFormat) {
        let cards = format == .xml ? vault.cards.filter { !$0.trashed }
            : vault.cards.filter { !$0.trashed && !$0.template }
        let text = ExportCardsTask.export(cards, labels: vault.labels, format: format)
        guard !text.isEmpty, let url = writeTemp(text, "upasswords-export.\(format.rawValue)") else {
            Log.error("app", "ios export \(format.rawValue) produced no file")
            vault.showToast(L10n.t("conversion_failed_message"))
            return
        }
        Log.info("app", "ios export \(format.rawValue) cards=\(cards.count)")
        shareItems = [url]
        showShare = true
    }

    private func writeTemp(_ content: String, _ name: String) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            Log.error("app", "ios export write \(name) failed: \(error)")
            return nil
        }
    }
}

// MARK: - 导入(18 种来源格式,复用 Persistence 的 ImportFormatFactory)

/// 读取用户选择的明文文件，使用共享导入器追加记录。
struct ImportDataSheet: View {
    @EnvironmentObject var vault: Vault
    @Environment(\.dismiss) private var dismiss

    @State private var pendingFormatId: String? = nil
    @State private var showFilePicker = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(ImportFormatFactory.all, id: \.id) { format in
                        Button {
                            pendingFormatId = format.id
                            showFilePicker = true
                        } label: {
                            Label(format.title, systemImage: "square.and.arrow.down")
                                .foregroundStyle(.primary)
                        }
                    }
                } header: {
                    Text(L10n.t("import_command"))
                } footer: {
                    Text(L10n.t("select_source_text"))
                }
            }
            .navigationTitle(L10n.t("import_command"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("cancel_button")) { dismiss() }
                }
            }
            .fileImporter(isPresented: $showFilePicker,
                          allowedContentTypes: [.plainText, .xml, .json, .commaSeparatedText],
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    importFrom(url)
                }
            }
        }
    }

    private func importFrom(_ url: URL) {
        guard let formatId = pendingFormatId else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            Log.warn("app", "ios import: unreadable file \(url.lastPathComponent)")
            vault.showToast(L10n.t("ios_import_unreadable_message"))
            return
        }
        do {
            let added = try vault.importEntries(text: content, formatId: formatId)
            vault.showToast(added > 0 ? String(format: L10n.t("ios_imported_fmt"), added)
                                      : L10n.t("ios_import_none_message"))
            // 批量导入的条目不经逐条泄露检查,静默兜底一次
            if added > 0 { vault.scheduleSilentBreachCheck() }
            dismiss()
        } catch {
            Log.error("app", "ios import format=\(formatId) failed: \(error)")
            vault.showToast("\(L10n.t("conversion_failed_message")): \(error.localizedDescription)")
        }
    }
}
