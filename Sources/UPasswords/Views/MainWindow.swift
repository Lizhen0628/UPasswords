import SwiftUI

/// Phase router: SetupWindowController / LockWindowController / MainWindowController.
struct RootView: View {
    @EnvironmentObject var ctx: AppContext
    @EnvironmentObject var settings: AppSettings

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
        // 切换语言时强制重建整棵视图树 → 界面语言立即生效
        .id(settings.languageOverride)
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

    var body: some View {
        VStack(spacing: 0) {
            // 自绘 66pt 工具栏条带(系统 NSToolbar 在 macOS 26 必然附加玻璃胶囊,见 AppKitToolbar.swift)
            SafeTitleBarView(columnVisibility: $columnVisibility)
            Divider()
            NavigationSplitView(columnVisibility: $columnVisibility) {
                SidebarView()
                    .navigationSplitViewColumnWidth(min: 180, ideal: 213, max: 280)
            } content: {
                CardListView()
                    .navigationSplitViewColumnWidth(min: 300, ideal: 355, max: 520)
            } detail: {
                CardDetailView()
            }
        }
        .frame(minWidth: 760, minHeight: 460)
        .ignoresSafeArea(.all, edges: .top)   // 隐藏标题栏后仍有 ~8pt 残留安全区,条带需贴顶
        .background(WindowChromeConfigurator(mode: .main))
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
            }
            .padding(.vertical, 4)
        }
        .background(SidebarMaterial())
        .safeAreaInset(edge: .bottom) {
            setupCard
        }
    }

    /// 侧栏底部圆角卡片 —「初始化 n/8」(SetupPlanViewController 入口) + 居中
    /// 的「显示」胶囊按钮,与原应用一致独立于滚动内容、上方有分隔线。
    private var setupCard: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(spacing: 8) {
                Button {
                    ctx.activeSheet = .setupPlan
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "wrench.and.screwdriver")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text("\(L10n.t("setup_text")) \(ctx.setupCompletedCount)/8")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                showMenu
                    .frame(maxWidth: .infinity)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.045))
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(nsColor: .windowBackgroundColor))
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
                .padding(.horizontal, 16)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(0.10)))
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
            ForEach(safeRows) { sp in
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

    /// Safe 分组行:固定顺序 + 通过「显示」菜单开启的可选行(密码插入
    /// 在全部项目之后,文件/图片插入在笔记之后)。
    private var safeRows: [SpecialLabel] {
        var rows: [SpecialLabel] = []
        for sp in Self.safeOrder {
            rows.append(sp)
            if sp == .allCards,
               settings.sidebarOptionalItems.contains(SpecialLabel.passwords.rawValue) {
                rows.append(.passwords)
            }
            if sp == .notes {
                if settings.sidebarOptionalItems.contains(SpecialLabel.files.rawValue) {
                    rows.append(.files)
                }
                if settings.sidebarOptionalItems.contains(SpecialLabel.images.rawValue) {
                    rows.append(.images)
                }
            }
        }
        return rows
    }

    private func groupRow(_ group: SidebarGroup) -> some View {
        let isOpen = expanded.contains(group.key)
        return Button {
            if isOpen { expanded.remove(group.key) } else { expanded.insert(group.key) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Image(systemName: group.style.icon)
                    .font(.system(size: 12.5))
                    .foregroundStyle(group.style.tint)
                Text(group.key == "safe_group" && !ctx.databaseName.isEmpty
                     ? ctx.databaseName
                     : L10n.db(group.key))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
            }
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }
}

/// LabelListCell — 16pt icon, name, right-aligned count (weight 1000 in nib).
struct SidebarRow: View {
    @EnvironmentObject var ctx: AppContext
    @EnvironmentObject var settings: AppSettings
    let sp: SpecialLabel

    var body: some View {
        SidebarRowButton(title: sp.name, system: sp.systemImage, indent: 27,
                         count: settings.showCardCount ? ctx.count(for: .special(sp)) : nil,
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
        SidebarRowButton(title: label.name, system: "tag", indent: 27,
                         count: settings.showCardCount ? ctx.count(for: .label(label.id)) : nil,
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
    var count: Int? = nil
    var tint: Color? = nil
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: system)
                    .font(.system(size: 12.5))
                    .foregroundStyle(selected ? Color.white : (tint ?? Color.primary))
                    .frame(width: 17)
                Text(title)
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? .white : .primary)
                    .lineLimit(1)
                Spacer()
                if let count {
                    Text("\(count)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(selected ? Color.white.opacity(0.85) : .secondary)
                }
            }
            .padding(.leading, indent == 0 ? 10 : indent)
            .padding(.trailing, 10)
            .frame(height: 27)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? Color.accentColor : Color.clear)
            )
            .padding(.horizontal, 6)
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

    /// Search row: NSSearchField 风格深色圆角框在左;右侧是原应用的
    /// 「黄钥匙 + 云朵」双段连体胶囊(生成器 / 云同步)。
    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                TextField(L10n.t("search_text"), text: $ctx.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                if !ctx.searchText.isEmpty {
                    Button {
                        ctx.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.12), lineWidth: 1))

            syncCapsule
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    /// 双段胶囊:左半纯黄底白钥匙(密码生成器),右半深底白云(同步状态)。
    private var syncCapsule: some View {
        HStack(spacing: 0) {
            Button {
                ctx.activeSheet = .generator
            } label: {
                Image(systemName: "key.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 26)
                    .background(Color(nsColor: .systemYellow))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.t("generator_command"))

            Menu {
                Button(L10n.t("sync_command")) { Task { await ctx.sync() } }
                Divider()
                Button(L10n.t("manage_databases_command")) { ctx.activeSheet = .manageDatabases }
                Button(L10n.t("configure_cloud_command")) {
                    ctx.activeSheet = .configureCloud
                }
            } label: {
                Image(systemName: "icloud.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 26)
                    .background(Color.white.opacity(cloudConfigured ? 0.30 : 0.14))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L10n.t("sync_command"))
        }
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
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
        .onAppear {
            // 与 Safe 一致:进入主界面后始终有选中项
            if ctx.selectedCardId == nil { ctx.selectedCardId = cards.first?.id }
        }
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
