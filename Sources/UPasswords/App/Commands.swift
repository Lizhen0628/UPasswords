import SwiftUI

/// Main menu — mirrors MainMenu.nib structure from the reverse notes:
/// 文件/编辑/工具/视图 + standard items, with the original selector names
/// (addCard: addNote: addTemplate: addLabel: importData: exportData: …).
struct UPasswordsCommands: Commands {
    // Commands do not inherit the window environment on macOS; use the
    // shared session controller directly instead of @EnvironmentObject.
    private var ctx: AppContext { AppContext.shared }

    var body: some Commands {
        // 文件
        CommandMenu(L10n.t("file_menu")) {
            Button(L10n.t("add_card_command")) { ctx.activeSheet = .addCard }
                .keyboardShortcut("n", modifiers: .command)
            Button(L10n.t("add_note_command")) { ctx.activeSheet = .addNote }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button(L10n.t("add_template_command")) {
                // save current card as template via edit draft
                if let c = ctx.selectedCard {
                    var t = c
                    t.template = true
                    t.id = ctx.newCardId()
                    ctx.database.cards.append(t)
                    AppToast.shared.show(L10n.t("template_saved_message"))
                }
            }
            Button(L10n.t("add_label_command")) { ctx.activeSheet = .addLabel }
            Divider()
            Button(L10n.t("import_command")) { ctx.activeSheet = .importData }
            Button(L10n.t("export_command")) { ctx.activeSheet = .exportAs }
            Divider()
            Button(L10n.t("database_info_command")) { ctx.activeSheet = .databaseInfo }
            Button(L10n.t("password_history_command")) { ctx.activeSheet = .passwordHistory }
            Divider()
            Button(L10n.t("sync_command")) { Task { await ctx.sync() } }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Button(L10n.t("manage_databases_command")) { ctx.activeSheet = .manageDatabases }
            Divider()
            Button(L10n.t("backup_command")) { ctx.backupNow() }
        }

        // 工具
        CommandMenu(L10n.t("tools_menu")) {
            Button(L10n.t("setup_command")) { ctx.activeSheet = .setupPlan }
            Button(L10n.t("check_passwords_command")) { ctx.activeSheet = .compromised }
            Divider()
            Button(L10n.t("change_password_command")) { ctx.activeSheet = .changePassword }
            Button(L10n.t("configure_cloud_command")) { ctx.activeSheet = .configureCloud }
            Divider()
            Button(L10n.t("restore_templates_command")) { ctx.activeSheet = .restoreTemplates }
            Divider()
            Button(L10n.t("erase_data_command"), role: .destructive) { ctx.activeSheet = .eraseData }
        }

        // 视图
        CommandMenu(L10n.t("interface_prompt")) {
            Button(L10n.t("main_window_command")) { NSApp.activate(ignoringOtherApps: true) }
            Divider()
            Button(L10n.t("sorting_command")) { ctx.activeSheet = .sorting }
                .keyboardShortcut(",", modifiers: [.command, .shift])
            Button(L10n.t("generator_command")) { ctx.activeSheet = .generator }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Divider()
            Button(L10n.t("show_all_command")) { ctx.selection = .special(.allCards) }
            Button(L10n.t("clear_recent_command")) { ctx.clearRecent() }
            Button(L10n.t("empty_trash_command")) { ctx.emptyTrash() }
            Divider()
            Button(L10n.t("lock_command")) { ctx.lock() }
                .keyboardShortcut("l", modifiers: [.command, .control])
        }

        // replace default Help with branded help
        CommandGroup(replacing: .help) {
            Button(L10n.t("help_command")) { ctx.activeSheet = .whatsNew }
        }

        CommandGroup(after: .appInfo) {
            Button(L10n.t("whats_new_title")) { ctx.activeSheet = .whatsNew }
            Divider()
            Button(L10n.t("premium_command")) { ctx.activeSheet = .premium }
        }

        // contextual delete-key behavior for the card list
        CommandGroup(after: .pasteboard) {
            Button(L10n.t("delete_card_query")) {
                if let id = ctx.selectedCardId {
                    if ctx.selection == .special(.trash) {
                        ctx.deleteCardPermanently(id)
                    } else {
                        ctx.trashCard(id)
                    }
                }
            }
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(ctx.selectedCardId == nil)

            Button(L10n.t("duplicate_command")) {
                if let id = ctx.selectedCardId { ctx.duplicateCard(id) }
            }
            .keyboardShortcut("d", modifiers: [.command])

            Button(L10n.t("edit_button")) {
                if let c = ctx.selectedCard { ctx.editDraft = EditCardModel(card: c) }
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(ctx.selectedCardId == nil)
        }
    }
}

extension AppContext {
    var selectedCard: Card? {
        selectedCardId.flatMap { database.card(id: $0) }
    }
}
