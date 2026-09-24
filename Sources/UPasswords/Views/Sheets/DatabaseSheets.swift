import SwiftUI
import AppKit

// MARK: - Database info

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


// MARK: - Change password

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

// MARK: - Manage databases

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

// MARK: - Select database (from lock screen)

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

