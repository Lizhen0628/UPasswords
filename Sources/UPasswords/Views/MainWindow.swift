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

/// MainWindowController — per the original nib: 970×640 window, NSSplitView
/// (213 / 355 / rest), `main_toolbar` with 8 icon-only buttons + flexible space.
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
        .navigationTitle(L10n.tBranded("app_title"))
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

// MARK: - Toolbar (main_toolbar: 8 icon-only items + flexible space)

struct MainToolbar: ToolbarContent {
    @EnvironmentObject var ctx: AppContext
    @Binding var floating: Bool

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            button("add_button_Template", L10n.t("add_card_command"), "plus") {
                ctx.activeSheet = .addCard
            }
            button("sync_button_Template", L10n.t("sync_command"), "arrow.triangle.2.circlepath") {
                Task { await ctx.sync() }
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            button("sorting_button_Template", L10n.t("sorting_command"), "arrow.up.arrow.down") {
                ctx.activeSheet = .sorting
            }
            button("generator_button_Template", L10n.t("generator_command"), "wand.and.stars") {
                ctx.activeSheet = .generator
            }
            button("above_all_button_Template", L10n.t("above_all_button"), "pin.fill", isActive: floating) {
                floating.toggle()
                NSApp.keyWindow?.level = floating ? .floating : .normal
            }
            button("delete_button_Template", L10n.t("delete_command"), "trash") {
                if let id = ctx.selectedCardId { ctx.trashCard(id) }
            }
            .disabled(ctx.selectedCardId == nil)
            button("lock_button_Template", L10n.t("lock_command"), "lock.fill") {
                ctx.lock()
            }
            button("preferences_button_Template", L10n.t("preferences_command"), "gearshape") {
                ctx.activeSheet = .preferences
            }
        }
    }

    private func button(_ image: String, _ help: String, _ system: String,
                        isActive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .foregroundStyle(isActive ? Color.accentColor : .primary)
        }
        .help(help)
    }
}

// MARK: - Sidebar (LabelListViewController: source list with collapsible group
// rows — LabelListGroupCell 25pt with chevron + group icon, LabelListCell with
// 16pt icon, name and right-aligned semibold count)

struct SidebarView: View {
    @EnvironmentObject var ctx: AppContext
    @EnvironmentObject var settings: AppSettings

    @State private var expanded: Set<String> = ["labels_group", "categories_group", "security_group"]

    private struct SidebarGroup: Identifiable {
        let key: String
        var id: String { key }
    }

    private let groups: [SidebarGroup] = [
        SidebarGroup(key: "labels_group"),        // user labels render below
        SidebarGroup(key: "categories_group"),
        SidebarGroup(key: "security_group"),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(SpecialLabel.allCases.filter { $0.section == .top }) { sp in
                    SidebarRow(sp: sp)
                        .tag(SidebarSelection.special(sp))
                }

                ForEach(groups) { group in
                    groupRow(key: group.key)
                    if expanded.contains(group.key) {
                        if group.key == "labels_group" {
                            ForEach(ctx.database.labels.sorted { a, b in
                                a.pinToTop == b.pinToTop
                                    ? a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                                    : a.pinToTop && !b.pinToTop
                            }) { label in
                                SidebarLabelRow(label: label)
                            }
                        } else {
                            ForEach(SpecialLabel.allCases.filter { $0.section == sectionOf(group.key) }) { sp in
                                SidebarRow(sp: sp)
                            }
                        }
                    }
                }

                Divider().padding(.vertical, 4)

                ForEach(SpecialLabel.allCases.filter { $0.section == .bottom }) { sp in
                    SidebarRow(sp: sp)
                }

                // 侧栏底部 "初始化 n/8" (SetupPlanViewController entry)
                Button {
                    ctx.activeSheet = .setupPlan
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checklist")
                        Text("\(L10n.t("setup_text")) \(ctx.setupCompletedCount)/8")
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .foregroundStyle(.secondary)
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

    private func sectionOf(_ groupKey: String) -> SidebarSection {
        groupKey == "categories_group" ? .views : .security
    }

    private func groupRow(key: String) -> some View {
        let isOpen = expanded.contains(key)
        return Button {
            if isOpen { expanded.remove(key) } else { expanded.insert(key) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Image(systemName: "folder")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(L10n.db(key))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer()
            }
            .frame(height: 25)
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
                         selected: ctx.selection == .special(sp)) {
            ctx.selection = .special(sp)
        }
        .contextMenu {
            sidebarExtras(sp)
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
                         color: CardColor.color(named: label.color),
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
    var color: Color? = nil
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: system)
                    .font(.system(size: 12))
                    .foregroundStyle(color ?? .secondary)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 13))
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
            .frame(height: 25)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(selected ? Color.accentColor.opacity(0.18) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Card list (CardListViewController: search field inside the pane top,
// database icon button, clipboard toast bar, 48pt rows — CardListCell)

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

    /// Search row: NSSearchField at left, DatabaseIcon button (60×28) at right.
    private var header: some View {
        HStack(spacing: 8) {
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

            Spacer(minLength: 8)

            Button {
                ctx.activeSheet = .manageDatabases
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "cylinder")
                    Text(ctx.databaseName).lineLimit(1)
                }
                .font(.system(size: 11))
                .padding(.horizontal, 8)
                .frame(height: 24)
            }
            .buttonStyle(.bordered)
            .help(L10n.t("manage_databases_command"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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

/// CardListCell — 35×35 icon at (7,7); title over subtitle at x=52;
/// 32×32 blue one-time-password icon and 32×32 star button at the right edge.
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
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.leading, 10)
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
