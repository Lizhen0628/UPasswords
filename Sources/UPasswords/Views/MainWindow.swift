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

/// MainWindowController — 参考图实测:970×819 窗口,70pt 自绘工具栏条带,
/// 三列布局(侧栏 225pt / 5pt 凹槽 / 列表 266pt / 5pt 凹槽 / 详情),
/// 不用 NavigationSplitView:其侧栏列在 macOS 26 带 30pt 玻璃内缩且无法关闭。
struct MainWindowView: View {
    @EnvironmentObject var ctx: AppContext
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 0) {
            // 自绘 70pt 工具栏条带(系统 NSToolbar 在 macOS 26 必然附加玻璃胶囊,见 AppKitToolbar.swift)
            SafeTitleBarView()
            HStack(spacing: 0) {
                SidebarView()
                    .frame(width: 225)
                ColumnGroove()
                CardListView()
                    .frame(width: 266)
                ColumnGroove()
                CardDetailView()
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(minWidth: 760, minHeight: 460)
        .ignoresSafeArea(.all, edges: .top)   // 隐藏标题栏后仍有 ~8pt 残留安全区,条带需贴顶
        .background(WindowChromeConfigurator(mode: .main))
        .navigationTitle(ctx.databaseName.isEmpty ? L10n.tBranded("app_title") : ctx.databaseName)
        .sheet(item: Binding(
            get: { ctx.editDraft },
            set: { ctx.editDraft = $0 }   // 打开/关闭的通知由 editDraft.didSet 负责
        )) { draft in
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
            .padding(.top, 7)
            .padding(.bottom, 4)
        }
        .background(SidebarMaterial())
        .safeAreaInset(edge: .bottom) {
            setupCard
        }
    }

    /// 侧栏底部块 — 全宽分隔线 + 居中「初始化 n/8」(SetupPlanViewController 入口)
    /// + 居中的「显示」按钮。参考图实测:分隔线以下整条底色比侧栏深
    /// (windowBackgroundColor 30,30,30),「显示」为深灰圆角按钮。
    private var setupCard: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(spacing: 7) {
                Button {
                    ctx.activeSheet = .setupPlan
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "wrench.and.screwdriver")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.white.opacity(0.22))
                        Text("\(L10n.t("setup_text")) \(ctx.setupCompletedCount)/8")
                            .font(.system(size: 13))
                            .foregroundStyle(.primary)
                    }
                    .frame(height: 22)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                showMenu
            }
            .padding(.top, 15)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)
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
                .font(.system(size: 13))
                .foregroundStyle(.primary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 70, height: 27)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.075)))
        .clipped()
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
            // 参考图实测:折叠箭头 ~26pt、组图标 ~44pt、组名 ~65pt(相对侧栏左缘)
            HStack(spacing: 0) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(isOpen ? 0 : -90))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .frame(width: 13)
                    .padding(.leading, 18)
                Image(systemName: group.style.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(group.style.tint)
                    .frame(width: 20)
                    .padding(.leading, 9)
                Text(group.key == "safe_group" && !ctx.databaseName.isEmpty
                     ? ctx.databaseName
                     : L10n.db(group.key))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .padding(.leading, 5)
                Spacer()
            }
            .frame(height: 27)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
    }
}

/// 参考图的分隔凹槽:两侧 0.75pt 浅边线(white 10%)+ 中间 4pt 深槽 #1A1A1A,
/// 总宽/高 5.5pt。竖向用于列间;横向(horizontal: true)用于工具栏条带底缘。
struct ColumnGroove: View {
    var horizontal = false

    var body: some View {
        Group {
            if horizontal {
                VStack(spacing: 0) {
                    Rectangle().fill(Color.white.opacity(0.10)).frame(height: 0.75)
                    Rectangle().fill(Self.dark).frame(height: 4)
                    Rectangle().fill(Color.white.opacity(0.10)).frame(height: 0.75)
                }
            } else {
                HStack(spacing: 0) {
                    Rectangle().fill(Color.white.opacity(0.10)).frame(width: 0.75)
                    Rectangle().fill(Self.dark).frame(width: 4)
                    Rectangle().fill(Color.white.opacity(0.10)).frame(width: 0.75)
                }
            }
        }
        .allowsHitTesting(false)
    }

    static let dark = Color(red: 26/255.0, green: 26/255.0, blue: 26/255.0)
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
            // 参考图实测:行高 27pt;计数右缘 ~205pt,选中高亮为中性灰圆角矩形。
            // 子行(组内选项)起始位置再右移一档(~65pt,与父级文字对齐),
            // 明确体现「组 → 子选项」层级。
            HStack(spacing: 7) {
                Image(systemName: system)
                    .font(.system(size: 14))
                    .foregroundStyle(selected ? Color.white : (tint ?? Color.primary))
                    .frame(width: 15)
                Text(title)
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? .white : .primary)
                    .lineLimit(1)
                Spacer()
                if let count {
                    Text("\(count)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.white.opacity(0.45))
                }
            }
            .padding(.leading, indent == 0 ? 10 : 55)
            .padding(.trailing, 10)
            .frame(height: 27)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(selected ? Color.white.opacity(0.16) : Color.clear)
            )
            .padding(.horizontal, 10)
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
        .background(Color.safeBackground)
        .overlay {
            if cards.isEmpty {
                emptyState
            }
        }
    }

    private var cards: [Card] {
        ctx.cards(for: ctx.selection, search: ctx.searchText)
    }

    /// Search row(参考图实测):搜索框 25.5pt 高、同底色 + 极淡描边;右侧
    /// 「盾牌 + 云朵」全黄连体胶囊 59.5×27.5pt(生成器 / 云同步)。
    private var header: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.45))
                TextField(L10n.t("search_text"), text: $ctx.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                if !ctx.searchText.isEmpty {
                    Button {
                        ctx.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.white.opacity(0.45))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 25.5)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.012)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.05), lineWidth: 1))

            syncCapsule
                .padding(.leading, 8)
        }
        .padding(.leading, 8.5)
        .padding(.trailing, 6.5)
        .padding(.top, 6)
        .padding(.bottom, 6)
    }

    /// 黄色胶囊:仅云同步菜单(密码生成器已上移到顶部工具栏)。
    /// 黄底尺寸随内容自适应;搜索框用 maxWidth:.infinity 自动占满剩余宽度。
    private var syncCapsule: some View {
        Menu {
            Button(L10n.t("sync_command")) { Task { await ctx.sync() } }
            Divider()
            Button(L10n.t("manage_databases_command")) { ctx.activeSheet = .manageDatabases }
            Button(L10n.t("configure_cloud_command")) {
                ctx.activeSheet = .configureCloud
            }
        } label: {
            Image(systemName: "icloud.fill")
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        // 正圆样式:图标居中,四周留白相等(直径 26,图标 15,四周各 5.5pt)
        .frame(width: 26, height: 26)
        .background(Color(red: 0.30, green: 0.66, blue: 0.96))   // 天蓝色
        .clipShape(Circle())
        .help(L10n.t("sync_command"))
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
                .foregroundStyle(Color.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 280)
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
