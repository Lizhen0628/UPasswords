import SwiftUI

/// Main menu — mirrors MainMenu.nib structure from the reverse notes:
/// 文件/编辑/工具/视图 + standard items, with the original selector names
/// (addCard: addNote: addTemplate: addLabel: importData: exportData: …).
///
/// Commands run outside the window's environment and actor isolation, so every
/// action hops to the main actor before touching the session controller.
struct UPasswordsCommands: Commands {
    private func perform(_ action: @escaping @MainActor () -> Void) {
        Task { @MainActor in action() }
    }

    var body: some Commands {
        // 文件
        CommandMenu(L10n.t("file_menu")) {
            Button(L10n.t("add_card_command")) { perform { AppContext.shared.activeSheet = .addCard } }
                .keyboardShortcut("n", modifiers: .command)
            Button(L10n.t("add_note_command")) { perform { AppContext.shared.activeSheet = .addNote } }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button(L10n.t("add_template_command")) {
                perform {
                    let ctx = AppContext.shared
                    if let c = ctx.selectedCard {
                        var t = c
                        t.template = true
                        t.id = ctx.newCardId()
                        ctx.database.cards.append(t)
                        AppToast.shared.show(L10n.t("template_saved_message"))
                    }
                }
            }
            Button(L10n.t("add_label_command")) { perform { AppContext.shared.activeSheet = .addLabel } }
            Divider()
            Button(L10n.t("import_command")) { perform { AppContext.shared.activeSheet = .importData } }
            Button(L10n.t("export_command")) { perform { AppContext.shared.activeSheet = .exportAs } }
            Divider()
            Button(L10n.t("database_info_command")) { perform { AppContext.shared.activeSheet = .databaseInfo } }
            Button(L10n.t("password_history_command")) { perform { AppContext.shared.activeSheet = .passwordHistory } }
            Divider()
            Button(L10n.t("sync_command")) { perform { Task { await AppContext.shared.sync() } } }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Button(L10n.t("manage_databases_command")) { perform { AppContext.shared.activeSheet = .manageDatabases } }
            Divider()
            Button(L10n.t("backup_command")) { perform { AppContext.shared.backupNow() } }
        }

        // 工具
        CommandMenu(L10n.t("tools_menu")) {
            Button(L10n.t("setup_command")) { perform { AppContext.shared.activeSheet = .setupPlan } }
            Button(L10n.t("check_passwords_command")) { perform { AppContext.shared.activeSheet = .compromised } }
            Divider()
            Button(L10n.t("change_password_command")) { perform { AppContext.shared.activeSheet = .changePassword } }
            Button(L10n.t("configure_cloud_command")) { perform { AppContext.shared.activeSheet = .configureCloud } }
            Divider()
            Button(L10n.t("restore_templates_command")) { perform { AppContext.shared.activeSheet = .restoreTemplates } }
            Divider()
            Button(L10n.t("erase_data_command"), role: .destructive) { perform { AppContext.shared.activeSheet = .eraseData } }
        }

        // 视图
        CommandMenu(L10n.t("interface_prompt")) {
            Button(L10n.t("main_window_command")) { perform { NSApp.activate(ignoringOtherApps: true) } }
            Divider()
            Button(L10n.t("sorting_command")) { perform { AppContext.shared.activeSheet = .sorting } }
                .keyboardShortcut(",", modifiers: [.command, .shift])
            Button(L10n.t("generator_command")) { perform { AppContext.shared.activeSheet = .generator } }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Divider()
            Button(L10n.t("show_all_command")) { perform { AppContext.shared.selection = .special(.allCards) } }
            Button(L10n.t("clear_recent_command")) { perform { AppContext.shared.clearRecent() } }
            Button(L10n.t("empty_trash_command")) { perform { AppContext.shared.emptyTrash() } }
            Divider()
            Button(L10n.t("lock_command")) { perform { AppContext.shared.lock() } }
                .keyboardShortcut("l", modifiers: [.command, .control])
        }

        // replace default Help with branded help
        CommandGroup(replacing: .help) {
            Button(L10n.t("help_command")) { perform { AppContext.shared.activeSheet = .whatsNew } }
        }

        CommandGroup(after: .appInfo) {
            Button(L10n.t("whats_new_title")) { perform { AppContext.shared.activeSheet = .whatsNew } }
            Divider()
            Button(L10n.t("premium_command")) { perform { AppContext.shared.activeSheet = .premium } }
        }

        // contextual delete-key behavior for the card list
        CommandGroup(after: .pasteboard) {
            Button(L10n.t("delete_card_query")) {
                perform {
                    let ctx = AppContext.shared
                    guard let id = ctx.selectedCardId else { return }
                    if ctx.selection == .special(.trash) {
                        ctx.deleteCardPermanently(id)
                    } else {
                        ctx.trashCard(id)
                    }
                }
            }
            .keyboardShortcut(.delete, modifiers: [])

            Button(L10n.t("duplicate_command")) {
                perform {
                    let ctx = AppContext.shared
                    if let id = ctx.selectedCardId { ctx.duplicateCard(id) }
                }
            }
            .keyboardShortcut("d", modifiers: .command)

            Button(L10n.t("edit_button")) {
                perform {
                    let ctx = AppContext.shared
                    if let c = ctx.selectedCard { ctx.editDraft = EditCardModel(card: c) }
                }
            }
            .keyboardShortcut("e", modifiers: .command)
        }
    }
}
