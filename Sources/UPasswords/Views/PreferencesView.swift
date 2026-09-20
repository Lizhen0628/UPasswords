import SwiftUI

/// The Settings window — tabbed like the original's preferences panes:
/// Appearance / Security / AutoBackup / Autofill (+ lock screen / sync).
struct PreferencesView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case appearance = "appearance_title"
        case security = "security_title"
        case autoBackup = "auto_backup_title"
        case autofill = "autofill_title"
        case lockScreen = "lock_screen_title"
        case cloud = "cloud_sync_title"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .appearance

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { t in
                    Text(L10n.t(t.rawValue)).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .padding(12)
            Divider()
            Group {
                switch tab {
                case .appearance: AppearancePane()
                case .security: SecurityPane()
                case .autoBackup: AutoBackupPane()
                case .autofill: AutofillPane()
                case .lockScreen: LockScreenPane()
                case .cloud: CloudPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 560, minHeight: 430)
    }
}

// MARK: - Appearance (AppearanceViewController)

struct AppearancePane: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Form {
            Picker(L10n.t("sorting_title"), selection: Binding(
                get: { settings.sortingValue }, set: { settings.sortingValue = $0 }
            )) {
                ForEach(Sorting.allCases) { s in
                    Text(s.name).tag(s)
                }
            }
            Toggle(L10n.t("favorites_at_top_setting"), isOn: $settings.favoritesAtTop)
            Toggle(L10n.t("show_card_count_setting"), isOn: $settings.showCardCount)
            Toggle(L10n.t("hide_passwords_setting"), isOn: $settings.hidePasswords)
            Toggle(L10n.t("use_website_icons_setting"), isOn: $settings.useWebsiteIcons)
            Divider()
            Toggle(L10n.t("search_by_labels_setting"), isOn: $settings.searchByLabels)
            Toggle(L10n.t("search_passwords_setting"), isOn: $settings.searchPasswords)
            Toggle(L10n.t("global_search_setting"), isOn: .constant(true))
                .disabled(true)
                .help(L10n.t("recommended_text"))
        }
        .formStyle(.grouped)
    }
}

// MARK: - Security (SecurityViewController)

struct SecurityPane: View {
    @EnvironmentObject var ctx: AppContext
    @EnvironmentObject var settings: AppSettings

    private let lockChoices: [(String, Int)] = [
        (L10n.t("never_text"), 0), ("1 m", 60), ("5 m", 300), ("15 m", 900), ("1 h", 3600),
    ]
    private let requireChoices: [(String, Int)] = [
        (L10n.t("never_text"), 0), ("8 h", 28800), ("1 d", 86400), ("7 d", 604800),
    ]
    private let clipboardChoices: [(String, Int)] = [
        (L10n.t("off_text"), 0), ("10 s", 10), ("30 s", 30), ("1 m", 60), ("2 m", 120),
    ]
    private let attemptsChoices: [(String, Int)] = [
        (L10n.t("unlimited_text"), 0), ("5", 5), ("10", 10), ("20", 20),
    ]

    var body: some View {
        Form {
            Picker(L10n.t("auto_lock_setting"), selection: $settings.autoLockSeconds) {
                ForEach(lockChoices, id: \.1) { c in Text(c.0).tag(c.1) }
            }
            Toggle(L10n.t("lock_in_background_button"), isOn: $settings.lockInBackground)
            Toggle(L10n.t("lock_if_window_closed_button"), isOn: $settings.lockIfWindowClosed)
            Divider()
            Toggle(L10n.t("fast_unlock_setting"), isOn: $settings.fastUnlock)
                .disabled(!ctx.touchIDAvailable)
            if !ctx.touchIDAvailable {
                Text(L10n.t("not_recommended_text") + ": Touch ID unavailable")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(L10n.t("touch_id_login_warning"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker(L10n.t("require_password_setting"), selection: $settings.requirePasswordSeconds) {
                ForEach(requireChoices, id: \.1) { c in Text(c.0).tag(c.1) }
            }
            Divider()
            Picker(L10n.t("empty_clipboard_setting"), selection: $settings.clipboardClearSeconds) {
                ForEach(clipboardChoices, id: \.1) { c in Text(c.0).tag(c.1) }
            }
            Picker(L10n.t("password_attempts_setting"), selection: $settings.selfDestructAttempts) {
                ForEach(attemptsChoices, id: \.1) { c in Text(c.0).tag(c.1) }
            }
            Divider()
            HStack {
                Button(L10n.t("change_password_button")) { ctx.activeSheet = .changePassword }
                Button(L10n.t("erase_data_command"), role: .destructive) { ctx.activeSheet = .eraseData }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Auto backup (AutoBackupViewController)

struct AutoBackupPane: View {
    @EnvironmentObject var ctx: AppContext
    @EnvironmentObject var settings: AppSettings

    private let intervalChoices: [(String, Int)] = [
        ("1 d", 1), ("3 d", 3), ("7 d", 7), ("30 d", 30),
    ]

    var body: some View {
        Form {
            Toggle(L10n.t("auto_backup_title"), isOn: $settings.autoBackupEnabled)
            Picker(L10n.t("backup_interval_setting"), selection: $settings.backupIntervalDays) {
                ForEach(intervalChoices, id: \.1) { c in Text(c.0).tag(c.1) }
            }
            .disabled(!settings.autoBackupEnabled)
            LabeledRow(label: L10n.t("backup_location_setting")) {
                Text("~/Library/Application Support/UPasswords/Backups")
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            HStack {
                Button(L10n.t("backup_now_button")) { ctx.backupNow() }
                Button(L10n.t("restore_command")) { restore() }
            }
            if !backups.isEmpty {
                Divider()
                Text(L10n.t("last_backup_completed_text")).font(.caption.bold()).foregroundStyle(.secondary)
                List {
                    ForEach(backups, id: \.absoluteString) { url in
                        HStack {
                            Image(systemName: "doc.badge.clock")
                            Text(url.lastPathComponent)
                            Spacer()
                            Button(L10n.t("restore_button")) { restoreFrom(url) }
                                .buttonStyle(.link)
                        }
                    }
                }
                .frame(minHeight: 100)
            }
        }
        .formStyle(.grouped)
    }

    private var backups: [URL] {
        ctx.store.backups(name: ctx.databaseName)
    }

    @MainActor private func restore() {
        guard !backups.isEmpty else { return }
        restoreFrom(backups[0])
    }

    @MainActor private func restoreFrom(_ url: URL) {
        let alert = NSAlert()
        alert.messageText = L10n.t("confirm_restore_query")
        alert.addButton(withTitle: L10n.t("restore_button"))
        alert.addButton(withTitle: L10n.t("cancel_button"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try ctx.store.restore(backup: url, to: ctx.databaseName)
            try ctx.unlock(name: ctx.databaseName, password: ctx.password)
            AppToast.shared.show(L10n.t("database_restored_message"))
        } catch {
            AppToast.shared.show(error.localizedDescription)
        }
    }
}

// MARK: - Autofill (AutofillViewController + SetAutofillSheetController)

struct AutofillPane: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label(L10n.t("browser_integration_title"), systemImage: "safari")
                    .font(.headline)
                Text(L10n.t("install_extension_text"))
                Label(L10n.t("use_for_autofill_button"), systemImage: "iphone")
                    .font(.headline)
                Text("macOS autofill requires a Credential Provider extension and is not part of this replica; passwords can be copied from any field instead.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 460, alignment: .leading)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Lock screen (SelectTextureSheetController settings)

struct LockScreenPane: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Form {
            Picker(L10n.t("lock_screen_background_prompt"), selection: $settings.lockTexture) {
                ForEach(0..<LockTextures.count, id: \.self) { i in
                    Text("\(L10n.t("texture_text")) \(i + 1)").tag(i)
                }
            }
            Picker(L10n.t("lock_screen_text_prompt"), selection: $settings.lockWhiteText) {
                Text(L10n.t("white_text_text")).tag(true)
                Text(L10n.t("black_text_text")).tag(false)
            }
            ZStack {
                LockTextures.gradient(for: settings.lockTexture)
                VStack {
                    Image(systemName: "lock.circle").font(.system(size: 30))
                    Text(L10n.tBranded("app_title")).font(.headline)
                }
                .foregroundStyle(settings.lockWhiteText ? .white : .primary)
            }
            .frame(height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .formStyle(.grouped)
    }
}

// MARK: - Cloud sync (ConfigureCloudViewController inside preferences)

struct CloudPane: View {
    var body: some View {
        ConfigureCloudSheetContents()
    }
}

/// Body of ConfigureCloudSheet reusable in the preferences pane.
struct ConfigureCloudSheetContents: View {
    @EnvironmentObject var ctx: AppContext
    @EnvironmentObject var settings: AppSettings
    @State private var testing = false
    @State private var testResult: String? = nil

    var body: some View {
        Form {
            Picker(L10n.t("cloud_prompt"), selection: Binding(
                get: { settings.cloud }, set: { settings.cloudType = $0.rawValue }
            )) {
                ForEach(CloudType.allCases) { c in
                    Text(c.name).tag(c)
                }
            }
            .pickerStyle(.radioGroup)

            if settings.cloud == .webdav {
                GroupBox("WebDAV") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("HTTPS", isOn: $settings.webdav.useHTTPS)
                        LabeledRow(label: L10n.t("host_prompt")) {
                            TextField("dav.example.com", text: $settings.webdav.host).textFieldStyle(.roundedBorder)
                        }
                        LabeledRow(label: L10n.t("port_prompt")) {
                            TextField("443", value: $settings.webdav.port, format: .number).textFieldStyle(.roundedBorder)
                        }
                        LabeledRow(label: L10n.t("local_path_prompt")) {
                            TextField("/UPasswords/", text: $settings.webdav.path).textFieldStyle(.roundedBorder)
                        }
                        LabeledRow(label: L10n.t("user_name_prompt")) {
                            TextField("", text: $settings.webdav.user).textFieldStyle(.roundedBorder)
                        }
                        LabeledRow(label: L10n.t("password_prompt")) {
                            SecureField("", text: $settings.webdav.password).textFieldStyle(.roundedBorder)
                        }
                        HStack {
                            Button(L10n.t("testing_message")) {}
                                .hidden()
                            if testing {
                                ProgressView().controlSize(.small)
                            }
                            if let testResult {
                                Text(testResult).font(.caption)
                            }
                        }
                        Button(L10n.t("repair_button")) {
                            Task { await test() }
                        }
                    }
                }
            } else if settings.cloud != .none {
                Label(L10n.t("not_configured_state"), systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func test() async {
        testing = true
        do {
            try await WebDavDriver(settings: settings.webdav, databaseName: ctx.databaseName).testConnection()
            testResult = L10n.t("success_title")
            ctx.markSetupTaskDone(.cloudSync)
        } catch {
            testResult = error.localizedDescription
        }
        testing = false
    }
}
