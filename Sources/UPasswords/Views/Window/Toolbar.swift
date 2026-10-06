//
//  Toolbar.swift
//  UPasswords
//
//  邮件式自绘工具栏(布局:侧栏开关 | 标题+副标题 | 胶囊按钮组 | 搜索框)。
//  窗口 chrome 管理见 WindowChrome.swift。
//

import SwiftUI
import AppKit

/// 主窗口工具栏(52pt,邮件风格):左一为侧栏显隐开关,标题为当前侧栏选中项,
/// 副标题为列表条数;右侧 4 组胶囊按钮 + 邮件式搜索框。
struct MainToolbarView: View {
    @EnvironmentObject var ctx: AppContext
    @EnvironmentObject var settings: AppSettings

    @State private var fallbackToggleHovering = false

    /// 胶囊按钮分组(组间留空隙,组内以发丝竖线分隔,同邮件回复/转发组)。
    private static let groups: [[ToolbarButtonSpec]] = [
        [.add, .generator],
        [.sync, .sorting],
        [.delete, .lock],
        [.aboveAll, .preferences],
    ]
    private static let groupGap: CGFloat = 8
    private static let searchWidth: CGFloat = 150

    var body: some View {
        // 侧栏隐藏时内容列从窗口左缘开始,需先让开红绿灯区(邮件式:灯后跟开关)
        HStack(spacing: 10) {
            // 侧栏显示时开关在侧栏面板顶行(邮件式);这里只在侧栏隐藏时兜底,
            // 否则收起后没有入口再打开
            if !settings.sidebarVisible {
                Button {
                    settings.sidebarVisible.toggle()
                    Log.info("ui", "toolbar toggle sidebar visible=\(settings.sidebarVisible)")
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.72))
                        .frame(width: 40, height: 34)
                        .contentShape(Rectangle())
                        .background(Ellipse().fill(Color.white.opacity(fallbackToggleHovering ? 0.12 : 0)))
                }
                .buttonStyle(.plain)
                .onHover { fallbackToggleHovering = $0 }
                .help(L10n.t("show_sidebar_command"))
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(selectionTitle)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.95))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .lineLimit(1)
            }
            .frame(minWidth: 60)
            .padding(.leading, 6)

            Spacer(minLength: 12)

            HStack(spacing: Self.groupGap) {
                ForEach(Array(Self.groups.enumerated()), id: \.offset) { _, group in
                    MailToolbarGroup {
                        ForEach(Array(group.enumerated()), id: \.element.labelKey) { i, spec in
                            if i > 0 { groupDivider }
                            if spec.labelKey == "add_button" {
                                AddMenuButton()
                            } else {
                                ToolbarButton(spec: spec, ctx: ctx)
                            }
                        }
                    }
                }
            }

            searchField
        }
        .padding(.leading, settings.sidebarVisible ? 10 : 96)
        .padding(.trailing, 12)
        .frame(height: 52)
        .background(WindowDragArea())
        .background(Color.appBackground)
    }

    // MARK: 标题/副标题

    private var selectionTitle: String {
        switch ctx.selection {
        case .special(let sp): return sp.name
        case .label(let id): return ctx.database.label(id: id)?.name ?? L10n.tBranded("app_title")
        }
    }

    /// 副标题:当前选择 + 搜索过滤后的条数(同邮件「过滤条件: 未读 (n 封邮件)」)。
    /// 用防抖后的 searchQuery(逐键 searchText 不重算,也不为计数付出排序开销)。
    private var subtitle: String {
        let count = ctx.count(for: ctx.selection, search: ctx.searchQuery)
        return String.localizedStringWithFormat(L10n.t("items_count_text"), count)
    }

    // MARK: 右区:邮件式搜索框

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.45))
            TextField(L10n.t("search_text"), text: Binding(
                get: { ctx.searchText },
                set: { ctx.setSearchText($0) }
            ))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.white)
            if !ctx.searchText.isEmpty {
                Button {
                    ctx.clearSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.45))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .frame(width: Self.searchWidth, height: 26)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.055)))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.07), lineWidth: 1))
    }

    /// 组内按钮间的发丝竖线(邮件回复/转发组分隔样式)。
    private var groupDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.10))
            .frame(width: 1, height: 16)
    }
}

// MARK: - 按钮描述(8 项,纯图标无文字标签)

struct ToolbarButtonSpec {
    let labelKey: String
    let helpKey: String
    let symbol: @MainActor () -> String
    let isActive: @MainActor (AppContext) -> Bool
    let isEnabled: @MainActor (AppContext) -> Bool
    let action: @MainActor (AppContext) -> Void

    static let add = ToolbarButtonSpec(
        labelKey: "add_button", helpKey: "add_card_command", symbol: { "plus.circle" },
        isActive: { _ in false }, isEnabled: { _ in true },
        action: { $0.activeSheet = .addCard })
    static let delete = ToolbarButtonSpec(
        labelKey: "delete_button", helpKey: "delete_command", symbol: { "trash" },
        isActive: { _ in false }, isEnabled: { $0.selectedCardId != nil },
        action: { if let id = $0.selectedCardId { $0.trashCard(id) } })
    static let lock = ToolbarButtonSpec(
        labelKey: "lock_button", helpKey: "lock_command", symbol: { "lock.fill" },
        isActive: { _ in false }, isEnabled: { _ in true },
        action: { $0.lock() })
    static let sync = ToolbarButtonSpec(
        labelKey: "sync_button", helpKey: "sync_command",
        symbol: { "arrow.triangle.2.circlepath" },
        isActive: { _ in false }, isEnabled: { _ in true },
        action: { ctx in Task { await ctx.sync() } })
    static let generator = ToolbarButtonSpec(
        labelKey: "generator_button", helpKey: "generator_command", symbol: { "key" },
        isActive: { _ in false }, isEnabled: { _ in true },
        action: { $0.activeSheet = .generator })
    static let sorting = ToolbarButtonSpec(
        labelKey: "sorting_button", helpKey: "sorting_command",
        symbol: { "arrow.up.arrow.down.square" },
        isActive: { _ in false }, isEnabled: { _ in true },
        action: { $0.activeSheet = .sorting })
    static let aboveAll = ToolbarButtonSpec(
        labelKey: "above_all_button", helpKey: "above_all_button",
        symbol: { WindowFloatState.shared.floating ? "pin.fill" : "pin" },
        isActive: { _ in WindowFloatState.shared.floating }, isEnabled: { _ in true },
        action: { _ in WindowFloatState.shared.toggle() })
    static let preferences = ToolbarButtonSpec(
        labelKey: "preferences_button", helpKey: "preferences_command", symbol: { "gearshape" },
        isActive: { _ in false }, isEnabled: { _ in true },
        action: { $0.activeSheet = .preferences })

    private init(labelKey: String, helpKey: String,
                 symbol: @MainActor @escaping () -> String,
                 isActive: @MainActor @escaping (AppContext) -> Bool,
                 isEnabled: @MainActor @escaping (AppContext) -> Bool,
                 action: @MainActor @escaping (AppContext) -> Void) {
        self.labelKey = labelKey
        self.helpKey = helpKey
        self.symbol = symbol
        self.isActive = isActive
        self.isEnabled = isEnabled
        self.action = action
    }
}

// MARK: - 胶囊按钮组(发丝描边 + 组内发丝竖线分段,悬停逐段高亮)

struct MailToolbarGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 0) {
            content
        }
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.10), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

// MARK: - 「添加」下拉菜单(按类型直接建卡)

/// 「添加」按钮 = 下拉菜单:互联网帐户/信用卡/一次性代码/身份证护照/Note,
/// 「其他」打开完整模板选择器。选中类型 → 按模板建卡并打开编辑表单。
struct AddMenuButton: View {
    @EnvironmentObject var ctx: AppContext

    var body: some View {
        Menu {
            Button { addTemplate(102) } label: { Label(L10n.db("web_account_template"), systemImage: "globe") }
            Button { addTemplate(101) } label: { Label(L10n.db("credit_card_template"), systemImage: "creditcard") }
            Button { addTemplate(120) } label: { Label(L10n.db("totp_template"), systemImage: "chart.pie.fill") }
            Button { addTemplate(105) } label: { Label(L10n.db("id_passport_template"), systemImage: "person.text.rectangle") }
            Button { ctx.activeSheet = .addNote } label: { Label(L10n.db("note_template"), systemImage: "doc") }
            Button { ctx.activeSheet = .addCard } label: { Label(L10n.t("other_button"), systemImage: "ellipsis.circle") }
        } label: {
            Image(systemName: "plus.circle")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.85))
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L10n.t("add_card_command"))
    }

    /// 按模板实例化新卡并进入编辑表单(与模板选择器的行为一致)。
    private func addTemplate(_ id: Int) {
        guard let spec = Templates.spec(id: id) else { return }
        var m = EditCardModel(card: Templates.makeCard(from: spec, id: ctx.newCardId()))
        m.isNew = true
        Log.info("ui", "add draft template=\(id) cardId=\(m.card.id)")
        ctx.editDraft = m
    }
}

// MARK: - 胶囊分段按钮:14pt 字形,悬停段内高亮,激活/禁用三态

struct ToolbarButton: View {
    let spec: ToolbarButtonSpec
    @ObservedObject var ctx: AppContext
    @ObservedObject private var floatState = WindowFloatState.shared

    @State private var hovering = false

    var body: some View {
        let active = spec.isActive(ctx)
        let enabled = spec.isEnabled(ctx)
        Button {
            spec.action(ctx)
        } label: {
            Image(systemName: spec.symbol())
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(iconColor(active: active, enabled: enabled))
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(hovering && enabled ? Color.white.opacity(0.08) : Color.clear)
                )
                .padding(.horizontal, 1)
        }
        .buttonStyle(.plain)
        // 工具栏按钮不做置灰(删除无选中时为安全空操作)
        .help(L10n.t(spec.helpKey))
        .onHover { hovering = $0 }
    }

    private func iconColor(active: Bool, enabled: Bool) -> Color {
        if active { return .accentColor }
        if !enabled { return Color.white.opacity(0.28) }
        return Color.white.opacity(0.85)
    }
}
