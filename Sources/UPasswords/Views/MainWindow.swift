import SwiftUI

/// Phase router: SetupWindowController / LockWindowController / MainWindowController.
struct RootView: View {
    @EnvironmentObject var ctx: AppContext

    var body: some View {
        ZStack {
            switch ctx.phase {
            case .setup:
                SetupWindowView()
            case .locked:
                LockWindowView()
            case .unlocked:
                MainWindowView()
            }
        }
        .withToastAndActivity()
        .sheet(item: $ctx.activeSheet) { sheet in
            SheetFactory.view(for: sheet)
                .environmentObject(ctx)
                .environmentObject(ctx.settings)
                .environmentObject(PasswordSettings.shared)
        }
    }
}

/// MainWindowController — per the original app: 970×640 window, NSSplitView
/// (213 / 355 / rest) and a unified toolbar with 8 icon+label buttons.
struct MainWindowView: View {
    @EnvironmentObject var ctx: AppContext
    @EnvironmentObject var settings: AppSettings

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var floating = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 213, max: 280)
        } content: {
            CardListView()
                .navigationSplitViewColumnWidth(min: 300, ideal: 355, max: 520)
        } detail: {
            CardDetailView()
        }
        .frame(minWidth: 760, minHeight: 460)
        .toolbar { MainToolbar(floating: $floating) }
        .navigationTitle(ctx.databaseName.isEmpty ? L10n.tBranded("app_title") : ctx.databaseName)
        .sheet(item: $ctx.editDraft) { draft in
            EditCardSheet(draft: Binding(
                get: { ctx.editDraft ?? draft },
                set: { ctx.editDraft = $0 }
            ))
            .environmentObject(ctx)
            .environmentObject(ctx.settings)
        }
    }
}

// MARK: - Toolbar (main_toolbar: icon + caption label items, original order)

struct MainToolbar: ToolbarContent {
    @EnvironmentObject var ctx: AppContext
    @Binding var floating: Bool

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            button("add_button", "plus.circle", L10n.t("add_card_command")) {
                ctx.activeSheet = .addCard
            }
            button("delete_button", "trash", L10n.t("delete_command")) {
                if let id = ctx.selectedCardId { ctx.trashCard(id) }
            }
            .disabled(ctx.selectedCardId == nil)
            button("lock_button", "lock.fill", L10n.t("lock_command")) {
                ctx.lock()
            }
            button("sync_button", "arrow.triangle.2.circlepath", L10n.t("sync_command")) {
                Task { await ctx.sync() }
            }
            button("generator_button", "key", L10n.t("generator_command")) {
                ctx.activeSheet = .generator
            }
            button("sorting_button", "arrow.up.arrow.down", L10n.t("sorting_command")) {
                ctx.activeSheet = .sorting
            }
            button("above_all_button", floating ? "pin.fill" : "pin", L10n.t("above_all_button"),
                   isActive: floating) {
                floating.toggle()
                NSApp.keyWindow?.level = floating ? .floating : .normal
            }
            button("preferences_button", "gearshape", L10n.t("preferences_command")) {
                ctx.activeSheet = .preferences
            }
        }
    }

    /// Toolbar item matching the original: glyph on top, small caption below.
    private func button(_ labelKey: String, _ system: String, _ help: String,
                        isActive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Image(systemName: system)
                    .font(.system(size: 15))
                    .foregroundStyle(isActive ? Color.accentColor : Color.primary)
                Text(L10n.t(labelKey))
                    .font(.system(size: 9))
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(width: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Sidebar (LabelListViewController: four collapsible groups —
// Safe (database name, shield) / 标签 / 安全性 / 特殊 — with colored group
// icons, neutral selection highlight and the 「显示」 optional-item menu)

struct SidebarView: View {
    @EnvironmentObject var ctx: AppContext
    @EnvironmentObject var settings: AppSettings

    @State private var expanded: Set<String> = ["safe_group", "labels_group", "security_group", "special_group"]

    private struct SidebarGroup: Identifiable {
        let key: String
        let style: SidebarGroupStyle
        var id: String { key }
    }

    /// Original row order inside each group.
    private static let safeOrder: [SpecialLabel] = [.allCards, .favorites, .creditCards, .notes, .oneTimeCodes, .passkeys, .recent]
    private static let securityOrder: [SpecialLabel] = [.compromised, .weakPasswords, .samePasswords]
    private static let specialOrder: [SpecialLabel] = [.expiring, .expired, .archived, .templates, .trash]
    private static let optionalOrder: [SpecialLabel] = [.passwords, .files, .images]

    private var groups: [SidebarGroup] {
        [
            SidebarGroup(key: "safe_group", style: .safe),
            SidebarGroup(key: "labels_group", style: .labels),
            SidebarGroup(key: "security_group", style: .security),
            SidebarGroup(key: "special_group", style: .special),
        ]
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(groups) { group in
                    groupRow(group)
                    if expanded.contains(group.key) {
                        rows(for: group)
                    }
                }

                Spacer(minLength: 8)

                // 侧栏底部 "初始化 n/8" (SetupPlanViewController entry) + 「显示」
                HStack(spacing: 6) {
                    Button {
                        ctx.activeSheet = .setupPlan
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "checklist")
                            Text("\(L10n.t("setup_text")) \(ctx.setupCompletedCount)/8")
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))

                    Spacer(minLength: 4)

                    showMenu
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }
            .padding(.vertical, 6)
        }
        .background(SidebarMaterial())
        .safeAreaInset(edge: .bottom) {
            if settings.showCardCount {
                Text("\(ctx.database.activeCards.count) \(L10n.t("cards_title"))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(.bar)
            }
        }
    }

    /// 「显示」button — toggles the optional sidebar rows (密码/文件/图片).
    private var showMenu: some View {
        Menu {
            ForEach(Self.optionalOrder) { sp in
                Button {
                    if settings.sidebarOptionalItems.contains(sp.rawValue) {
                        settings.sidebarOptionalItems.removeAll { $0 == sp.rawValue }
                    } else {
                        settings.sidebarOptionalItems.append(sp.rawValue)
                    }
                } label: {
                    if settings.sidebarOptionalItems.contains(sp.rawValue) {
                        Label(sp.name, systemImage: "checkmark")
                    } else {
                        Text(sp.name)
                    }
                }
            }
        } label: {
            Text(L10n.t("show_button"))
                .font(.system(size: 11))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(height: 18)
    }

    @ViewBuilder
    private func rows(for group: SidebarGroup) -> some View {
        switch group.style {
        case .safe:
            ForEach(Self.safeOrder) { sp in
                SidebarRow(sp: sp)
                    .tag(SidebarSelection.special(sp))
            }
        case .labels:
            ForEach(ctx.database.labels.sorted { a, b in
                a.pinToTop == b.pinToTop
                    ? a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                    : a.pinToTop && !b.pinToTop
            }) { label in
                SidebarLabelRow(label: label)
            }
        case .security:
            ForEach(Self.securityOrder) { sp in
                SidebarRow(sp: sp)
            }
        case .special:
            ForEach(Self.specialOrder) { sp in
                SidebarRow(sp: sp)
            }
        }
    }

    private func groupRow(_ group: SidebarGroup) -> some View {
        let isOpen = expanded.contains(group.key)
        return Button {
            if isOpen { expanded.remove(group.key) } else { expanded.insert(group.key) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Image(systemName: group.style.icon)
                    .font(.system(size: 12))
                    .foregroundStyle(group.style.tint)
                Text(group.key == "safe_group" && !ctx.databaseName.isEmpty
                     ? ctx.databaseName
                     : L10n.db(group.key))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
            }
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
    }
}

/// LabelListCell — 16pt icon, name, right-aligned count (weight 1000 in nib).
struct SidebarRow: View {
    @EnvironmentObject var ctx: AppContext
    @EnvironmentObject var settings: AppSettings
    let sp: SpecialLabel

    var body: some View {
        SidebarRowButton(title: sp.name, system: sp.systemImage, indent: 35,
                         count: settings.showCardCount ? ctx.count(for: .special(sp)) : 0,
                         tint: tint,
                         selected: ctx.selection == .special(sp)) {
            ctx.selection = .special(sp)
        }
        .contextMenu {
            sidebarExtras(sp)
        }
    }

    private var tint: Color {
        switch sp.iconColor {
        case "yellow": return .yellow
        case "red": return .red
        case "orange": return .orange
        case "blue": return .blue
        default: return .secondary
        }
    }

    @ViewBuilder
    private func sidebarExtras(_ sp: SpecialLabel) -> some View {
        if sp == .recent {
            Button(L10n.t("clear_recent_command")) { ctx.clearRecent() }
        }
        if sp == .trash {
            Button(L10n.t("empty_trash_command")) { ctx.emptyTrash() }
        }
        if sp == .templates {
            Button(L10n.t("restore_templates_command")) { ctx.activeSheet = .restoreTemplates }
        }
    }
}

struct SidebarLabelRow: View {
    @EnvironmentObject var ctx: AppContext
    @EnvironmentObject var settings: AppSettings
    let label: CardLabel

    var body: some View {
        SidebarRowButton(title: label.name, system: "tag", indent: 35,
                         count: settings.showCardCount ? ctx.count(for: .label(label.id)) : 0,
                         tint: CardColor.color(named: label.color),
                         selected: ctx.selection == .label(label.id)) {
            ctx.selection = .label(label.id)
        }
        .contextMenu {
            Button(L10n.t("rename_command")) { ctx.activeSheet = .editCardLabel(id: label.id) }
            Button(L10n.t("pin_to_top_command")) { ctx.toggleLabelPinned(id: label.id) }
            Button(L10n.t("select_color_command")) { ctx.activeSheet = .selectColorCardLabel(id: label.id) }
            Divider()
            Button(L10n.t("export_command")) { ctx.activeSheet = .exportAs }
            Button(L10n.t("delete_button"), role: .destructive) { ctx.deleteCardLabel(id: label.id) }
        }
    }
}

private struct SidebarRowButton: View {
    let title: String
    let system: String
    var indent: CGFloat = 0
    var count: Int = 0
    var tint: Color? = nil
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: system)
                    .font(.system(size: 12))
                    .foregroundStyle(tint ?? .secondary)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? .primary : .primary)
                    .lineLimit(1)
                Spacer()
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, indent == 0 ? 10 : indent)
            .padding(.trailing, 8)
            .frame(height: 26)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(selected ? Color.primary.opacity(0.10) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Card list (CardListViewController: search field inside the pane top,
// yellow generator key + cloud sync circles at the right, 48pt rows)

struct CardListView: View {
    @EnvironmentObject var ctx: AppContext
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var toast: AppToast

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if toast.message != nil {
                toastBar
            }
            list
        }
        .overlay {
            if cards.isEmpty {
                emptyState
            }
        }
    }

    private var cards: [Card] {
        ctx.cards(for: ctx.selection, search: ctx.searchText)
    }

    /// Search row: NSSearchField at left; generator key (yellow circle) and
    /// cloud status (white circle) buttons at the right.
    private var header: some View {
        HStack(spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L10n.t("search_text"), text: $ctx.searchText)
                    .textFieldStyle(.plain)
                if !ctx.searchText.isEmpty {
                    Button {
                        ctx.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))

            // Yellow key circle — opens the password generator.
            Button {
                ctx.activeSheet = .generator
            } label: {
                Image(systemName: "key.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color(nsColor: .systemYellow)))
            }
            .buttonStyle(.plain)
            .help(L10n.t("generator_command"))

            // Cloud circle — sync status / actions.
            Menu {
                Button(L10n.t("sync_command")) { Task { await ctx.sync() } }
                Divider()
                Button(L10n.t("manage_databases_command")) { ctx.activeSheet = .manageDatabases }
                Button(L10n.t("configure_cloud_command")) {
                    ctx.activeSheet = .configureCloud
                }
            } label: {
                Image(systemName: cloudConfigured ? "icloud.fill" : "icloud")
                    .font(.system(size: 12))
                    .foregroundStyle(cloudConfigured ? Color.accentColor : Color.secondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 24, height: 24)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var cloudConfigured: Bool {
        settings.cloud != .none
    }

    /// clipboardToast — "Text copied to clipboard" bar at the top of the pane.
    private var toastBar: some View {
        HStack {
            Spacer()
            Label(toast.message ?? "", systemImage: "doc.on.doc")
                .font(.system(size: 11))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var list: some View {
        List(selection: $ctx.selectedCardId) {
            ForEach(cards) { card in
                CardListCellView(card: card, preview: ctx.searchText.isEmpty ? nil : ctx.searchPreview(for: card, word: String(ctx.searchText.lowercased().split(separator: " ").first ?? "")))
                    .tag(card.id)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .frame(height: 48)
                    .contextMenu {
                        cardContextMenu(card)
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .onChange(of: ctx.selectedCardId) { _, id in
            if let id {
                ctx.pushRecent(id)
                ctx.touch()
            }
        }
    }

    /// CardListViewController contextMenu — exact item list from the nib.
    @ViewBuilder
    private func cardContextMenu(_ card: Card) -> some View {
        Button(L10n.t("add_card_command")) { ctx.activeSheet = .addCard }
        Button(L10n.t("add_note_command")) { ctx.activeSheet = .addNote }
        Button(L10n.t("add_template_command")) { ctx.activeSheet = .addCard }
        Divider()
        Button(L10n.t("edit_command")) { ctx.editDraft = EditCardModel(card: card) }
        Button(L10n.t("delete_command")) { ctx.trashCard(card.id) }
        Button(L10n.t("move_command")) { ctx.activeSheet = .labels(cardId: card.id) }
        Button(L10n.t("duplicate_command")) { ctx.duplicateCard(card.id) }
        Button(L10n.t("merge_command")) {}
        Button(L10n.t("save_as_template_command")) {
            var t = card
            t.template = true
            t.id = ctx.newCardId()
            ctx.database.cards.append(t)
        }
        if card.archived {
            Button(L10n.t("unarchive_command")) { ctx.unarchiveCard(card.id) }
        } else {
            Button(L10n.t("archive_command")) { ctx.archiveCard(card.id) }
        }
        if card.trashed {
            Button(L10n.t("restore_card_command")) { ctx.restoreCard(card.id) }
        }
        Divider()
        Button(L10n.t("copy_as_text_command")) {
            ClipboardModel.shared.copy(card.asPlainText())
        }
        Menu(L10n.t("share_menu")) {
            Button(L10n.t("export_command")) { ctx.activeSheet = .exportAs }
        }
        Divider()
        Button(L10n.t("set_labels_command")) { ctx.activeSheet = .labels(cardId: card.id) }
        Button(L10n.t("use_website_icon_command")) {
            if let i = ctx.database.cards.firstIndex(where: { $0.id == card.id }) {
                ctx.database.cards[i].useWebsiteIcon.toggle()
                ctx.saveDebounced()
            }
        }
        Button(L10n.t("select_symbol_command")) { ctx.activeSheet = .selectSymbol }
        Button(L10n.t("select_color_command")) { ctx.activeSheet = .selectColor }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text(emptyStateText)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .padding()
    }

    private var emptyStateText: String {
        switch ctx.selection {
        case .special(let sp): return sp.emptyState
        case .label: return L10n.t("user_empty_state")
        }
    }
}

/// CardListCell — 35pt circular icon at (7,7); title over subtitle at x=52
/// (single centered title when there is no subtitle); blue one-time-password
/// icon and star button at the right edge.
struct CardListCellView: View {
    @EnvironmentObject var ctx: AppContext
    @EnvironmentObject var settings: AppSettings
    let card: Card
    let preview: String?

    var body: some View {
        HStack(spacing: 0) {
            CardIconView(symbol: card.symbol, color: card.color, size: 35,
                         creditCardNumber: card.fields.first { $0.type == .number }?.value)
                .padding(.leading, 7)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(card.title.isEmpty ? "—" : card.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if card.isExpired {
                        Image(systemName: "clock.badge.exclamationmark").font(.caption2).foregroundStyle(.red)
                    } else if card.isExpiring {
                        Image(systemName: "hourglass").font(.caption2).foregroundStyle(.orange)
                    }
                    if card.hasWeakPasswords {
                        Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.red)
                    }
                }
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.leading, 10)
            .frame(maxHeight: .infinity, alignment: subtitle.isEmpty ? .center : .top)
            .padding(.top, subtitle.isEmpty ? 0 : 7)
            Spacer(minLength: 8)
            if card.fields.contains(where: { $0.type == .oneTimePassword }) {
                Image(systemName: "timer")
                    .font(.system(size: 14))
                    .foregroundStyle(.blue)
                    .frame(width: 32, height: 32)
            }
            Button {
                ctx.toggleFavorite(card.id)
            } label: {
                Image(systemName: card.favorite ? "star.fill" : "star")
                    .font(.system(size: 14))
                    .foregroundStyle(card.favorite ? .yellow : .secondary.opacity(0.4))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
        }
        .frame(height: 48)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        if let preview { return preview }
        if card.login.isEmpty {
            return card.fields.first(where: { $0.hasValue })?.value ?? ""
        }
        return card.login
    }
}

extension Card {
    /// Weak-password flag recomputed on demand (XCard.hasWeakPasswords).
    var hasWeakPasswords: Bool {
        fields.contains { $0.type.needsScoring && !$0.value.isEmpty && PasswordStrength.score($0.value).score <= 1 }
    }

    /// Offline compromised flag (fast mark; full HIBP check runs in the sheet).
    var compromised: Bool {
        fields.contains { $0.type.needsScoring && CompromisedService.offlineDemoSet.contains($0.value) }
    }
}
