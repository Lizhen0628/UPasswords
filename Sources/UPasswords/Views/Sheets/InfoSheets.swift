import SwiftUI

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
                    Text(L10n.t("about_copyright")).font(.caption)
                    Text(L10n.t("about_replica_note"))
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
                    feature("lock.shield", L10n.t("whats_new_encryption_text"))
                    feature("timer", L10n.t("whats_new_totp_text"))
                    feature("icloud", L10n.t("whats_new_sync_text"))
                    feature("square.and.arrow.down.on.square", L10n.t("whats_new_import_text"))
                    feature("chart.bar", L10n.t("whats_new_strength_text"))
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
                    Text(L10n.t("premium_replica_note"))
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

