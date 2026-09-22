import SwiftUI
import AppKit

// MARK: - Export (ExportAsSheetController)

struct ExportAsSheet: View {
    @EnvironmentObject var ctx: AppContext
    @Environment(\.dismiss) var dismiss
    @State private var format: ExportFormat = .xml

    var body: some View {
        SheetShell(
            title: L10n.t("export_as_title"),
            onCancel: { dismiss() },
            onOk: { export() },
            content: {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.t("export_as_text")).font(.callout)
                    Picker("", selection: $format) {
                        ForEach(ExportFormat.allCases) { f in
                            Text(f.name).tag(f)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    Label(L10n.t("export_warning_message"), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }
        )
    }

    @MainActor private func export() {
        let cards = ctx.database.cards.filter { !$0.template }
        let text = ExportCardsTask.export(cards, labels: ctx.database.labels, format: format)
        let panel = NSSavePanel()
        panel.allowedContentTypes = format == .xml ? [.xml] : [.plainText]
        panel.nameFieldStringValue = "\(ctx.databaseName).\(format.rawValue)"
        if panel.runModal() == .OK, let url = panel.url {
            try? text.data(using: .utf8)?.write(to: url)
            AppToast.shared.show(L10n.t("data_exported_message") + " " + url.path)
        }
        dismiss()
    }
}

// MARK: - Import (ImportSheetController + ImportSourceViewController + ImportLogViewController)

struct ImportSheet: View {
    @EnvironmentObject var ctx: AppContext
    @Environment(\.dismiss) var dismiss

    @State private var formatId: String? = nil
    @State private var log: [String] = []
    @State private var imported = 0
    @State private var ranOnce = false

    var body: some View {
        SheetShell(
            title: L10n.t("import_command"),
            minWidth: 520,
            okTitle: ranOnce ? L10n.t("close_button") : L10n.t("continue_button"),
            okDisabled: !ranOnce && formatId == nil,
            onCancel: { dismiss() },
            onOk: { ranOnce ? dismiss() : run() },
            content: {
                VStack(alignment: .leading, spacing: 10) {
                    if !ranOnce {
                        Text(L10n.t("select_source_text"))
                            .font(.callout).foregroundStyle(.secondary)
                        ScrollView {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 8) {
                                ForEach(ImportFormatFactory.all, id: \.id) { f in
                                    Button {
                                        formatId = f.id
                                    } label: {
                                        Text(f.title)
                                            .lineLimit(1)
                                            .padding(8)
                                            .frame(maxWidth: .infinity)
                                            .background(
                                                formatId == f.id ? Color.accentColor.opacity(0.2) : Color(nsColor: .controlBackgroundColor),
                                                in: RoundedRectangle(cornerRadius: 6)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    } else {
                        Text(L10n.t("log_title")).font(.headline)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(log, id: \.self) { l in
                                    Text(l).font(.system(.callout, design: .monospaced))
                                }
                            }
                        }
                        Label("\(imported) \(L10n.t("cards_title"))", systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                    }
                }
            }
        )
    }

    private func run() {
        guard let id = formatId, let format = ImportFormatFactory.format(id: id) else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .xml, .json, .commaSeparatedText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.urls.first,
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            log = [L10n.t("operation_canceled_text")]
            return
        }
        log.append("\(L10n.t("source_prompt")) \(format.title)")
        log.append("\(L10n.t("conversion_started_message"))")
        var db = ctx.database
        do {
            let n = try format.parse(text, into: &db, now: Date())
            ctx.database = db
            ctx.save()
            imported = n
            log.append("\(L10n.t("conversion_completed_message")) — \(n) \(L10n.t("cards_title"))")
        } catch {
            log.append("\(L10n.t("conversion_failed_message")): \(error.localizedDescription)")
        }
        ranOnce = true
        ctx.markSetupTaskDone(.importPasswords)
    }
}

// MARK: - Database info (DatabaseInfoSheetController)

struct DatabaseInfoSheet: View {
    @EnvironmentObject var ctx: AppContext
    @Environment(\.dismiss) var dismiss

    var body: some View {
        SheetShell(
            title: L10n.t("database_info_button"),
            okTitle: L10n.t("close_button"),
            onCancel: { dismiss() },
            onOk: { dismiss() },
            content: {
                let cards = ctx.database.cards.filter { !$0.template }
                VStack(alignment: .leading, spacing: 8) {
                    infoRow(L10n.t("database_name_prompt"), ctx.databaseName)
                    infoRow(L10n.t("cards_title"), "\(cards.filter { !$0.trashed && !$0.archived }.count)")
                    infoRow(L10n.t("archived_label"), "\(cards.filter { $0.archived }.count)")
                    infoRow(L10n.t("trash_label"), "\(cards.filter { $0.trashed }.count)")
                    infoRow(L10n.t("labels_text"), "\(ctx.database.labels.count)")
                    infoRow(L10n.db("templates_label"), "\(ctx.database.templateCards.count)")
                    infoRow(L10n.t("cloud_prompt"), ctx.settings.cloud.name)
                    if let size = try? FileManager.default.attributesOfItem(atPath: DatabaseStore.shared.url(for: ctx.databaseName).path)[.size] as? Int {
                        infoRow(L10n.t("size_prompt"), ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    }
                    infoRow(L10n.t("security_title"), "PBKDF2-SHA256 ×310,000 + AES-256-GCM")
                }
            }
        )
    }

    private func infoRow(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
            Text(v)
            Spacer()
        }
    }
}

// MARK: - Compromised passwords (CompromisedPasswordsSheetController)

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
                                    CardIconView(symbol: card.symbol, color: card.color, size: 26)
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

// MARK: - Change password (SetPasswordSheetController)

struct ChangePasswordSheet: View {
    @EnvironmentObject var ctx: AppContext
    @Environment(\.dismiss) var dismiss
    @State private var current = ""
    @State private var new = ""
    @State private var confirm = ""
    @State private var error = ""

    var body: some View {
        SheetShell(
            title: L10n.t("change_password_button"),
            okDisabled: current.isEmpty || new.isEmpty,
            onCancel: { dismiss() },
            onOk: {
                guard new.count >= 4 else {
                    error = L10n.t("minimum_password_length_error")
                    return
                }
                guard new == confirm else {
                    error = L10n.t("passwords_do_not_match_error")
                    return
                }
                do {
                    try ctx.changePassword(current: current, new: new)
                    AppToast.shared.show(L10n.t("password_changed_message"))
                    dismiss()
                } catch {
                    self.error = error.localizedDescription
                }
            },
            content: {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledRow(label: L10n.t("enter_current_password_prompt")) {
                        SecureField("", text: $current).textFieldStyle(.roundedBorder)
                    }
                    LabeledRow(label: L10n.t("set_password_prompt")) {
                        SecureField("", text: $new).textFieldStyle(.roundedBorder)
                    }
                    LabeledRow(label: L10n.t("confirm_password_prompt")) {
                        SecureField("", text: $confirm).textFieldStyle(.roundedBorder)
                    }
                    Text(L10n.t("change_password_on_all_devices_message"))
                        .font(.caption).foregroundStyle(.secondary)
                    if !error.isEmpty {
                        Text(error).font(.callout).foregroundStyle(.red)
                    }
                }
            }
        )
    }
}

// MARK: - Configure cloud (ConfigureCloudSheetController + ConfigureCloudViewController)

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

// MARK: - Erase data (erase_data_command)

struct EraseDataSheet: View {
    @EnvironmentObject var ctx: AppContext
    @Environment(\.dismiss) var dismiss

    var body: some View {
        SheetShell(
            title: L10n.t("erase_data_command"),
            okTitle: L10n.t("delete_button"),
            onCancel: { dismiss() },
            onOk: {
                ctx.eraseAllData()
                dismiss()
            },
            content: {
                Text(L10n.t("erase_data_text"))
                    .font(.callout)
                    .frame(maxWidth: 360, alignment: .leading)
            }
        )
    }
}

// MARK: - Manage databases (ManageDatabasesViewController)

struct ManageDatabasesSheet: View {
    @EnvironmentObject var ctx: AppContext
    @Environment(\.dismiss) var dismiss
    @State private var newName = ""
    @State private var error = ""

    var body: some View {
        SheetShell(
            title: L10n.t("databases_title"),
            minWidth: 520,
            okTitle: L10n.t("close_button"),
            onCancel: { dismiss() },
            onOk: { dismiss() },
            content: {
                VStack(alignment: .leading, spacing: 10) {
                    // Main database group (MainDatabaseGroup / MainDatabaseCell)
                    Text(L10n.t("main_database_group")).font(.caption.bold()).foregroundStyle(.secondary)
                    ForEach(ctx.dbsInfo()) { db in
                        HStack {
                            Image(systemName: "cylinder")
                            Text(db.name)
                            if db.isMain {
                                Text(L10n.t("main_database_name"))
                                    .font(.caption2)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                            }
                            Spacer()
                            if db.name == ctx.databaseName && ctx.phase == .unlocked {
                                Text(L10n.t("authenticated_state"))
                                    .font(.caption).foregroundStyle(.green)
                            }
                            Menu {
                                if db.isMain == false {
                                    Button(L10n.t("main_database_name")) {
                                        ctx.store.mainDatabaseName = db.name
                                        ctx.objectWillChange.send()
                                    }
                                }
                                Button(L10n.t("rename_database_title")) {
                                    rename(db)
                                }
                                Divider()
                                Button(L10n.t("delete_button"), role: .destructive) {
                                    try? ctx.store.delete(name: db.name)
                                    ctx.objectWillChange.send()
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            Button(L10n.t("load_database_command")) {
                                switchTo(db)
                            }
                            .buttonStyle(.link)
                        }
                        .padding(8)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    }

                    Divider()
                    HStack {
                        TextField(L10n.t("database_name_prompt"), text: $newName)
                            .textFieldStyle(.roundedBorder)
                        Button(L10n.t("new_database_button")) {
                            create()
                        }
                        .disabled(newName.isEmpty)
                    }
                    if !error.isEmpty {
                        Text(error).font(.callout).foregroundStyle(.red)
                    }
                }
            }
        )
    }

    @MainActor private func create() {
        let pwd = ctx.password.isEmpty ? randomPassword() : ctx.password
        do {
            try ctx.store.create(name: newName, password: pwd)
            if !ctx.password.isEmpty {
                // inherit current password for a seamless switch
                try? ctx.store.save(PasswordDatabase.createDefault(), name: newName, password: ctx.password)
            }
            newName = ""
            error = ""
            AppToast.shared.show(L10n.t("new_database_created_message"))
            ctx.objectWillChange.send()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func rename(_ db: DatabaseFile) {
        let alert = NSAlert()
        alert.messageText = L10n.t("rename_database_title")
        alert.informativeText = L10n.t("rename_database_on_all_devices_message")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        input.stringValue = db.name
        alert.accessoryView = input
        alert.addButton(withTitle: L10n.t("ok_button"))
        alert.addButton(withTitle: L10n.t("cancel_button"))
        if alert.runModal() == .alertFirstButtonReturn, !input.stringValue.isEmpty {
            do {
                try ctx.store.rename(db.name, to: input.stringValue)
                if ctx.databaseName == db.name { ctx.databaseName = input.stringValue }
                ctx.objectWillChange.send()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func switchTo(_ db: DatabaseFile) {
        if ctx.phase == .unlocked && db.name == ctx.databaseName { return }
        ctx.databaseName = db.name
        ctx.store.mainDatabaseName = db.name
        if ctx.phase == .locked {
            ctx.activeSheet = nil
            // stay on lock screen; the new name is prefilled
        } else {
            ctx.lock()
        }
    }

    private func randomPassword() -> String {
        PasswordGenerator.instance.password(length: 16, type: 0)
    }
}

// MARK: - Select database (SelectDatabaseSheetController — from lock screen)

struct SelectDatabaseSheet: View {
    @EnvironmentObject var ctx: AppContext
    @Environment(\.dismiss) var dismiss

    var body: some View {
        SheetShell(
            title: L10n.t("select_database_title"),
            minHeight: 300,
            okTitle: L10n.t("close_button"),
            onCancel: { dismiss() },
            onOk: { dismiss() },
            content: {
                List {
                    ForEach(ctx.dbsInfo()) { db in
                        Button {
                            ctx.databaseName = db.name
                            ctx.store.mainDatabaseName = db.name
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: "cylinder")
                                Text(db.name)
                                Spacer()
                                if db.name == ctx.databaseName {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(height: 200)
            }
        )
    }
}

// MARK: - About (AboutWindowController)

struct AboutSheet: View {
    @EnvironmentObject var ctx: AppContext
    @Environment(\.dismiss) var dismiss

    var body: some View {
        SheetShell(
            title: L10n.t("about_title"),
            okTitle: L10n.t("close_button"),
            onCancel: { dismiss() },
            onOk: { dismiss() },
            content: {
                VStack(spacing: 12) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.tint)
                    Text(L10n.tBranded("app_title")).font(.title3.bold())
                    Text("\(L10n.t("version_text")) 1.0 (1000)")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("© 2026 UPasswords").font(.caption)
                    Text("Swift 1:1 replica study of Safe.app (SafeInCloud 25.3.5) — see README")
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: 360)
                        .multilineTextAlignment(.center)
                    Divider()
                    HStack {
                        Button(L10n.t("license_info_button")) {
                            ctx.activeSheet = .premium
                        }
                        .buttonStyle(.link)
                        Button(L10n.t("legal_title")) {
                            ctx.activeSheet = .whatsNew
                        }
                        .buttonStyle(.link)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        )
    }
}

// MARK: - What's new (WhatsNewSheetController + whats_new.json)

struct WhatsNewSheet: View {
    @EnvironmentObject var ctx: AppContext
    @Environment(\.dismiss) var dismiss
    @State private var showAtStartup = true

    var body: some View {
        SheetShell(
            title: L10n.t("whats_new_title"),
            minWidth: 420,
            okTitle: L10n.t("finish_button"),
            onCancel: { dismiss() },
            onOk: { dismiss() },
            content: {
                VStack(alignment: .leading, spacing: 10) {
                    feature("lock.shield", "PBKDF2-SHA256 ×310,000 + AES-256-GCM")
                    feature("timer", "TOTP (RFC 6238) one-time codes")
                    feature("icloud", "WebDAV cloud sync with item-level merge")
                    feature("square.and.arrow.down.on.square", "18 import formats (Chrome/Bitwarden/LastPass/…)")
                    feature("chart.bar", "Password strength & compromised checks (k-anonymity)")
                    Toggle(L10n.t("show_this_info_at_startup_button"), isOn: $showAtStartup)
                        .font(.callout)
                }
            }
        )
        .onDisappear { ctx.settings.showWhatsNewAtStartup = showAtStartup }
    }

    private func feature(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).frame(width: 20)
            Text(text).font(.callout)
        }
    }
}

// MARK: - Premium (PremiumSheetController — Adapty in the original)

struct PremiumSheet: View {
    @EnvironmentObject var ctx: AppContext
    @Environment(\.dismiss) var dismiss

    var body: some View {
        SheetShell(
            title: L10n.t("premium_title"),
            minWidth: 440,
            okTitle: L10n.t("close_button"),
            onCancel: { dismiss() },
            onOk: { dismiss() },
            content: {
                VStack(alignment: .leading, spacing: 12) {
                    Label(L10n.t("license_is_active_text"), systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L10n.t("activate_license_text")).font(.callout)
                            HStack {
                                TextField(L10n.t("enter_your_email_prompt"), text: .constant(""))
                                    .textFieldStyle(.roundedBorder)
                                Button(L10n.t("activate_button")) {}
                            }
                            Button(L10n.t("restore_purchase_button")) {}
                                .buttonStyle(.link)
                        }
                    }
                    Text("This replica has no store integration; Premium is informational only.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        )
    }
}

// MARK: - Setup plan (SetupPlanViewController / SetupWindowController 8 items)

struct SetupPlanSheet: View {
    @EnvironmentObject var ctx: AppContext
    @Environment(\.dismiss) var dismiss

    var body: some View {
        SheetShell(
            title: L10n.t("setup_text"),
            minWidth: 500,
            minHeight: 460,
            okTitle: L10n.t("finish_button"),
            onCancel: { dismiss() },
            onOk: { dismiss() },
            content: {
                VStack(spacing: 0) {
                    List {
                        ForEach(SetupPlanTask.allCases) { task in
                            HStack {
                                Image(systemName: ctx.setupTaskDone(task) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(ctx.setupTaskDone(task) ? .green : .secondary)
                                Text(task.name)
                                Spacer()
                                Button(L10n.t("configure_button")) {
                                    open(task)
                                }
                                .buttonStyle(.link)
                            }
                        }
                    }
                    // List 是滚动容器,理想高度为 0,必须显式给高,否则弹窗塌缩
                    .frame(height: 330)
                    ProgressView(value: Double(ctx.setupCompletedCount), total: 8)
                        .padding(.top, 8)
                }
            }
        )
    }

    private func open(_ task: SetupPlanTask) {
        switch task {
        case .cloudSync: ctx.activeSheet = .configureCloud
        case .importPasswords: ctx.activeSheet = .importData
        case .touchID:
            ctx.settings.fastUnlock = true
            // 已解锁状态下内存里有当前密码,用它保存生物识别副本
            ctx.enableTouchIDUnlock()
            ctx.markSetupTaskDone(task)
        case .securitySettings: ctx.activeSheet = .preferences
        case .autoBackup:
            ctx.settings.autoBackupEnabled = true
            ctx.backupNow()
            ctx.markSetupTaskDone(task)
        case .autofill: ctx.activeSheet = .preferences
        case .installOnMobile: ctx.markSetupTaskDone(task)
        case .uiPreferences: ctx.activeSheet = .preferences
        }
    }
}

// MARK: - Expired cards prompt (expiring_cards_warning)

struct ExpiredCardsSheet: View {
    @EnvironmentObject var ctx: AppContext
    @Environment(\.dismiss) var dismiss

    var body: some View {
        SheetShell(
            title: L10n.t("warning_title"),
            okTitle: L10n.t("show_button"),
            onCancel: { dismiss() },
            onOk: {
                ctx.selection = .special(.expiring)
                dismiss()
            },
            content: {
                VStack(alignment: .leading, spacing: 8) {
                    Label(L10n.t("expiring_cards_warning"), systemImage: "hourglass")
                    ForEach(ctx.cards(for: .special(.expiring), search: "").prefix(8)) { card in
                        HStack {
                            Text(card.title)
                            Spacer()
                            Text("\(card.expiringInDays) \(L10n.t("days_text"))")
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
        )
    }
}

// MARK: - Restore templates (restore_templates_command)

struct RestoreTemplatesSheet: View {
    @EnvironmentObject var ctx: AppContext
    @Environment(\.dismiss) var dismiss

    var body: some View {
        SheetShell(
            title: L10n.t("restore_templates_command"),
            okTitle: L10n.t("restore_button"),
            onCancel: { dismiss() },
            onOk: {
                for spec in Templates.all {
                    if ctx.database.card(id: spec.id) == nil {
                        ctx.database.cards.append(Templates.makeTemplateCard(spec))
                    }
                }
                ctx.saveDebounced()
                dismiss()
            },
            content: {
                Text(L10n.t("restore_templates_query"))
                    .frame(maxWidth: 320, alignment: .leading)
            }
        )
    }
}

// MARK: - Password history (HistorySheetController + HistoryViewController)

struct PasswordHistorySheet: View {
    @EnvironmentObject var ctx: AppContext
    @Environment(\.dismiss) var dismiss

    var body: some View {
        SheetShell(
            title: L10n.t("password_history_command"),
            minWidth: 520,
            minHeight: 460,
            okTitle: L10n.t("close_button"),
            onCancel: { dismiss() },
            onOk: { dismiss() },
            content: {
                let entries = ctx.allHistoryEntries
                Group {
                    if entries.isEmpty {
                        Text(L10n.t("user_empty_state"))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List {
                            ForEach(Array(entries.enumerated()), id: \.offset) { _, e in
                                HStack {
                                    CardIconView(symbol: e.card.symbol, color: e.card.color, size: 24)
                                    VStack(alignment: .leading) {
                                        Text("\(e.card.title) — \(e.field.name)").font(.callout)
                                        Text(e.entry.value).font(.callout.monospaced()).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(e.entry.time.date.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption).foregroundStyle(.secondary)
                                    Button {
                                        ClipboardModel.shared.copy(e.entry.value)
                                    } label: {
                                        Image(systemName: "doc.on.doc")
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                        }
                        // 滚动容器需显式高度,否则在 Sheet 里塌缩为 0
                        .frame(height: 320)
                    }
                }
            }
        )
    }
}

// MARK: - Select texture (SelectTextureSheetController + TextureCell)

struct SelectTextureSheet: View {
    @EnvironmentObject var ctx: AppContext
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) var dismiss

    var body: some View {
        SheetShell(
            title: L10n.t("select_texture_title"),
            minWidth: 520,
            onCancel: { dismiss() },
            onOk: { dismiss() },
            content: {
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(L10n.t("lock_screen_background_prompt")) \(L10n.t("lock_screen_preview_prompt"))")
                        .font(.callout).foregroundStyle(.secondary)
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))], spacing: 10) {
                            ForEach(0..<LockTextures.count, id: \.self) { i in
                                Button {
                                    settings.lockTexture = i
                                } label: {
                                    ZStack(alignment: .topTrailing) {
                                        LockTextures.gradient(for: i)
                                            .frame(width: 100, height: 64)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                        if settings.lockTexture == i {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(.white)
                                                .padding(4)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    Picker(L10n.t("lock_screen_text_prompt"), selection: $settings.lockWhiteText) {
                        Text(L10n.t("white_text_text")).tag(true)
                        Text(L10n.t("black_text_text")).tag(false)
                    }
                    .pickerStyle(.radioGroup)
                }
            }
        )
    }
}

// MARK: - SheetFactory

enum SheetFactory {
    @ViewBuilder
    static func view(for sheet: AppSheet) -> some View {
        switch sheet {
        case .addCard: AddCardSheet()
        case .addNote: AddNoteSheet()
        case .addLabel: AddLabelSheet()
        case .editCardLabel(let id): EditLabelSheet(labelId: id)
        case .selectColorCardLabel(let id): SelectColorLabelSheet(labelId: id)
        case .sorting: SortingSheet()
        case .generator: GeneratorSheet()
        case .labels(let cardId): SetLabelsSheet(cardId: cardId)
        case .selectSymbol: SelectSymbolSheet()
        case .selectColor: SelectColorSheet()
        case .selectTexture: SelectTextureSheet()
        case .selectTemplate: SelectTemplateSheet()
        case .exportAs: ExportAsSheet()
        case .importData: ImportSheet()
        case .databaseInfo: DatabaseInfoSheet()
        case .compromised: CompromisedSheet()
        case .changePassword: ChangePasswordSheet()
        case .configureCloud: ConfigureCloudSheet()
        case .eraseData: EraseDataSheet()
        case .manageDatabases: ManageDatabasesSheet()
        case .selectDatabase: SelectDatabaseSheet()
        case .about: AboutSheet()
        case .whatsNew: WhatsNewSheet()
        case .premium: PremiumSheet()
        case .setupPlan: SetupPlanSheet()
        case .expiredCards: ExpiredCardsSheet()
        case .restoreTemplates: RestoreTemplatesSheet()
        case .passwordHistory: PasswordHistorySheet()
        case .addField, .editField:
            // handled locally inside EditCardSheet
            EmptyView()
        case .preferences:
            PreferencesSheet()
        case .history, .addTemplate, .enterPassword:
            EmptyView() // history = recent sidebar label
        }
    }
}


/// Wraps the full tabbed PreferencesView for menu/setup-plan presentation
/// when the Settings scene is not reachable directly.
struct PreferencesSheet: View {
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 0) {
            PreferencesView()
            Divider()
            HStack {
                Spacer()
                Button(L10n.t("close_button")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(10)
        }
        .frame(minWidth: 560, minHeight: 430)
        .background(.regularMaterial)
    }
}
