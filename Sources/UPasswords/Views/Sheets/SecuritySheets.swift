import SwiftUI

// MARK: - Compromised passwords

struct CompromisedSheet: View {
    @EnvironmentObject var ctx: AppContext
    @Environment(\.dismiss) var dismiss

    @State private var running = false
    @State private var compromisedCards: [Card] = []
    @State private var offline = false
    @State private var resultText = ""

    var body: some View {
        SheetShell(
            title: L10n.t("compromised_passwords_title"),
            minWidth: 520,
            minHeight: 400,
            okTitle: L10n.t("close_button"),
            onCancel: { dismiss() },
            onOk: { dismiss() },
            content: {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.t("compromised_passwords_text"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button {
                            Task { await check(online: true) }
                        } label: {
                            if running {
                                ProgressView().controlSize(.small)
                            } else {
                                Label(L10n.t("check_passwords_button"), systemImage: "magnifyingglass")
                            }
                        }
                        .disabled(running)
                        Button(L10n.t("offline_button", fallback: "离线检查")) {
                            Task { await check(online: false) }
                        }
                        .disabled(running)
                        Spacer()
                        if !resultText.isEmpty {
                            Text(resultText).font(.callout)
                        }
                    }
                    List {
                        ForEach(compromisedCards) { card in
                            Button {
                                ctx.selectedCardId = card.id
                                dismiss()
                            } label: {
                                HStack {
                                    CardIconView(symbol: card.symbol, color: card.color, size: 26, card: card)
                                    Text(card.title)
                                    Spacer()
                                    Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.red)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    // 滚动容器需显式高度,否则在 Sheet 里塌缩为 0
                    .frame(height: 200)
                    .overlay {
                        if compromisedCards.isEmpty && !running {
                            Text(L10n.t("compromised_passwords_empty_state"))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: 360)
                                .multilineTextAlignment(.center)
                        }
                    }
                }
            }
        )
    }

    private func check(online: Bool) async {
        running = true
        compromisedCards = []
        let passwords = Set(ctx.database.activeCards.flatMap { card in
            card.fields.filter { $0.type == .password && !$0.value.isEmpty }.map(\.value)
        })
        let result = await CompromisedService.check(passwords: passwords, demo: !online)
        offline = result.offline
        compromisedCards = ctx.database.activeCards.filter { card in
            card.fields.contains { $0.type == .password && result.compromisedPasswords.contains($0.value) }
        }
        resultText = "\(L10n.t("compromised_passwords_found_text")) \(compromisedCards.count)" + (offline ? " (offline)" : "")
        running = false
    }
}


// MARK: - Configure cloud

struct ConfigureCloudSheet: View {
    @EnvironmentObject var ctx: AppContext
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) var dismiss

    @State private var testing = false
    @State private var testResult: String? = nil

    var body: some View {
        SheetShell(
            title: L10n.t("cloud_sync_title"),
            minWidth: 480,
            okTitle: L10n.t("save_button"),
            onCancel: { dismiss() },
            onOk: {
                if settings.cloud == .webdav {
                    Task { await test() }
                } else {
                    saved()
                }
            },
            content: {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.t("cloud_sync_text"))
                        .font(.callout).foregroundStyle(.secondary)
                    Picker(L10n.t("cloud_prompt"), selection: Binding(
                        get: { settings.cloud }, set: { settings.cloudType = $0.rawValue }
                    )) {
                        ForEach(CloudType.allCases) { c in
                            Text(c.name).tag(c)
                        }
                    }
                    .pickerStyle(.radioGroup)

                    if settings.cloud == .webdav {
                        GroupBox {
                            VStack(alignment: .leading, spacing: 8) {
                                Toggle(L10n.t("https_protocol_warning").prefix(6) + " HTTPS", isOn: $settings.webdav.useHTTPS)
                                LabeledRow(label: L10n.t("host_prompt")) {
                                    TextField("dav.example.com", text: $settings.webdav.host).textFieldStyle(.roundedBorder)
                                }
                                LabeledRow(label: L10n.t("port_prompt")) {
                                    TextField("443", value: $settings.webdav.port, format: .number).textFieldStyle(.roundedBorder)
                                }
                                LabeledRow(label: L10n.db("database_name_field")) {
                                    TextField("/UPasswords/", text: $settings.webdav.path).textFieldStyle(.roundedBorder)
                                }
                                LabeledRow(label: L10n.t("user_name_prompt")) {
                                    TextField("", text: $settings.webdav.user).textFieldStyle(.roundedBorder)
                                }
                                LabeledRow(label: L10n.t("password_prompt")) {
                                    SecureField("", text: $settings.webdav.password).textFieldStyle(.roundedBorder)
                                }
                                Text(L10n.t("https_protocol_warning"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } else if settings.cloud != .none {
                        Label(L10n.t("not_configured_state"), systemImage: "info.circle")
                            .font(.callout).foregroundStyle(.secondary)
                    }

                    if settings.cloud == .none {
                        Label(L10n.t("not_synchronizing_warning"), systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }

                    if let testResult {
                        Text(testResult).font(.callout)
                    }
                }
            }
        )
    }

    private func saved() {
        if settings.cloud != .none { ctx.markSetupTaskDone(.cloudSync) }
        dismiss()
    }

    private func test() async {
        testing = true
        do {
            try await WebDavDriver(settings: settings.webdav, databaseName: ctx.databaseName).testConnection()
            testResult = L10n.t("success_title")
            ctx.markSetupTaskDone(.cloudSync)
            dismiss()
        } catch {
            testResult = error.localizedDescription
        }
        testing = false
    }
}

