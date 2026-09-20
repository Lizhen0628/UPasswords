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

/// MainWindowController: 3-pane split — LabelListViewController /
/// CardListViewController / ViewCardViewController.
struct MainWindowView: View {
    @EnvironmentObject var ctx: AppContext
    @EnvironmentObject var settings: AppSettings

    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } content: {
            CardListView()
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 480)
        } detail: {
            CardDetailView()
        }
        .frame(minWidth: 980, minHeight: 560)
        .toolbar { MainWindowToolbar() }
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

// MARK: - Toolbar (46 toolbar icons in the original; condensed equivalents)

struct MainWindowToolbar: ToolbarContent {
    @EnvironmentObject var ctx: AppContext

    var body: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                ctx.activeSheet = .addCard
            } label: {
                Label(L10n.t("add_card_button"), systemImage: "plus")
            }
            .help(L10n.t("add_card_command"))

            Button {
                ctx.activeSheet = .addNote
            } label: {
                Label(L10n.t("add_note_button"), systemImage: "note.text.badge.plus")
            }
            .help(L10n.t("add_note_command"))

            Button {
                ctx.activeSheet = .addLabel
            } label: {
                Label(L10n.t("add_label_button"), systemImage: "tag.badge.plus")
            }
            .help(L10n.t("add_label_command"))

            Divider()

            Button {
                ctx.activeSheet = .generator
            } label: {
                Label(L10n.t("generator_button"), systemImage: "wand.and.stars")
            }
            .help(L10n.t("generator_command"))

            Button {
                Task { await ctx.sync() }
            } label: {
                Label(L10n.t("sync_button"), systemImage: "arrow.triangle.2.circlepath")
            }
            .help(L10n.t("sync_command"))

            Spacer()

            Button {
                ctx.lock()
            } label: {
                Label(L10n.t("lock_button"), systemImage: "lock.fill")
            }
            .help(L10n.t("lock_command"))
        }
    }
}

// MARK: - Sidebar (LabelListViewController + LabelListCell/GroupCell)

struct SidebarView: View {
    @EnvironmentObject var ctx: AppContext
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        List(selection: $ctx.selection) {
            ForEach(SpecialLabel.allCases.filter { $0.section == .top }) { sp in
                SidebarRow(sp: sp)
                    .tag(SidebarSelection.special(sp))
            }

            Section(L10n.t("labels_text")) {
                ForEach(pinnedLabels) { label in
                    SidebarLabelRow(label: label)
                        .tag(SidebarSelection.label(label.id))
                }
                ForEach(otherLabels) { label in
                    SidebarLabelRow(label: label)
                        .tag(SidebarSelection.label(label.id))
                }
                if ctx.database.labels.isEmpty {
                    Text(L10n.t("user_empty_state"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(L10n.db("categories_group")) {
                ForEach(SpecialLabel.allCases.filter { $0.section == .views }) { sp in
                    SidebarRow(sp: sp)
                        .tag(SidebarSelection.special(sp))
                }
            }

            Section(L10n.db("security_group")) {
                ForEach(SpecialLabel.allCases.filter { $0.section == .security }) { sp in
                    SidebarRow(sp: sp)
                        .tag(SidebarSelection.special(sp))
                }
            }

            ForEach(SpecialLabel.allCases.filter { $0.section == .bottom }) { sp in
                SidebarRow(sp: sp)
                    .tag(SidebarSelection.special(sp))
            }

            // 初始化 n/8 — setup plan entry pinned at sidebar bottom
            Button {
                ctx.activeSheet = .setupPlan
            } label: {
                HStack {
                    Image(systemName: "checklist")
                    Text("\(L10n.t("setup_text")) \(ctx.setupCompletedCount)/8")
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            if settings.showCardCount {
                Text("\(ctx.database.activeCards.count) \(L10n.t("cards_title")) · \(ctx.databaseName)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(.bar)
            }
        }
        .contextMenu(forSelectionType: SidebarSelection.self) { selection in
            if let sel = selection.first, case .label(let id) = sel {
                Button(L10n.t("rename_command")) { ctx.activeSheet = .editCardLabel(id: id) }
                Button(L10n.t("pin_to_top_command")) { ctx.toggleLabelPinned(id: id) }
                Button(L10n.t("select_color_command")) { ctx.activeSheet = .selectColorCardLabel(id: id) }
                Button(L10n.t("delete_button"), role: .destructive) { ctx.deleteCardLabel(id: id) }
            }
        } primaryAction: { _ in }
    }

    private var pinnedLabels: [CardLabel] { ctx.database.labels.filter(\.pinToTop) }
    private var otherLabels: [CardLabel] { ctx.database.labels.filter { !$0.pinToTop } }
}

struct SidebarRow: View {
    @EnvironmentObject var ctx: AppContext
    @EnvironmentObject var settings: AppSettings
    let sp: SpecialLabel

    var body: some View {
        HStack {
            Label(sp.name, systemImage: sp.systemImage)
                .foregroundStyle(.primary)
            Spacer()
            if settings.showCardCount {
                let n = ctx.count(for: .special(sp))
                if n > 0 {
                    Text("\(n)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct SidebarLabelRow: View {
    @EnvironmentObject var ctx: AppContext
    @EnvironmentObject var settings: AppSettings
    let label: CardLabel

    var body: some View {
        HStack {
            Label(label.name, systemImage: "tag")
                .foregroundStyle(.primary)
            Spacer()
            if settings.showCardCount {
                let n = ctx.count(for: .label(label.id))
                if n > 0 {
                    Text("\(n)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Card list (CardListViewController + CardListCell)

struct CardListView: View {
    @EnvironmentObject var ctx: AppContext
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            Divider()
            list
        }
        .navigationSubtitle(currentTitle)
        .overlay {
            if cards.isEmpty {
                emptyState
            }
        }
    }

    private var cards: [Card] {
        ctx.cards(for: ctx.selection, search: ctx.searchText)
    }

    private var currentTitle: String {
        switch ctx.selection {
        case .special(let sp): return sp.name
        case .label(let id): return ctx.database.label(id: id)?.name ?? ""
        }
    }

    private var searchField: some View {
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
        .padding(6)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private var list: some View {
        List(selection: $ctx.selectedCardId) {
            ForEach(cards) { card in
                CardListCellView(card: card, preview: ctx.searchText.isEmpty ? nil : ctx.searchPreview(for: card, word: String(ctx.searchText.lowercased().split(separator: " ").first ?? "")))
                    .tag(card.id)
                    .contextMenu {
                        cardContextMenu(card)
                    }
            }
        }
        .listStyle(.plain)
        .onChange(of: ctx.selectedCardId) { _, id in
            if let id {
                ctx.pushRecent(id)
                ctx.touch()
            }
        }
    }

    @ViewBuilder
    private func cardContextMenu(_ card: Card) -> some View {
        Button(L10n.t("edit_button")) { ctx.editDraft = EditCardModel(card: card) }
        Button(card.favorite ? L10n.t("hide_button") : L10n.t("show_button")) { ctx.toggleFavorite(card.id) }
        Button(L10n.t("duplicate_command")) { ctx.duplicateCard(card.id) }
        if card.labelIds.isEmpty == false || true {
            Button(L10n.t("set_labels_button")) { ctx.activeSheet = .labels(cardId: card.id) }
        }
        Divider()
        if card.trashed {
            Button(L10n.t("restore_card_command")) { ctx.restoreCard(card.id) }
            Button(L10n.t("delete_button"), role: .destructive) { ctx.deleteCardPermanently(card.id) }
        } else if card.archived {
            Button(L10n.t("unarchive_command")) { ctx.unarchiveCard(card.id) }
            Button(L10n.t("delete_button")) { ctx.trashCard(card.id) }
        } else {
            Button(L10n.t("archive_command")) { ctx.archiveCard(card.id) }
            Button(L10n.t("delete_button")) { ctx.trashCard(card.id) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            if ctx.searchText.isEmpty {
                Text(emptyStateText)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 320)
            } else {
                Text(L10n.t("search_empty_text")).foregroundStyle(.secondary)
            }
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

/// CardListCell — icon + title + login preview + favorite star + warning marks.
struct CardListCellView: View {
    @EnvironmentObject var ctx: AppContext
    @EnvironmentObject var settings: AppSettings
    let card: Card
    let preview: String?

    var body: some View {
        HStack(spacing: 10) {
            CardIconView(symbol: card.symbol, color: card.color, size: 34,
                         creditCardNumber: card.fields.first { $0.type == .number }?.value)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(card.title.isEmpty ? "—" : card.title)
                        .lineLimit(1)
                    if card.favorite {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                    }
                    if card.isExpired {
                        Image(systemName: "clock.badge.exclamationmark").font(.caption2).foregroundStyle(.red)
                    } else if card.isExpiring {
                        Image(systemName: "hourglass").font(.caption2).foregroundStyle(.orange)
                    }
                    if weakMark { Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.red) }
                }
                if let preview {
                    Text(preview).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        if card.login.isEmpty {
            return card.fields.first(where: { $0.hasValue })?.value ?? card.title
        }
        return card.login
    }

    private var weakMark: Bool { card.hasWeakPasswords }
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
