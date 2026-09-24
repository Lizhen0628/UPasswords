import SwiftUI

// MARK: - Sidebar (four collapsible groups — 数据库(数据库名,盾牌图标) /
// 标签 / 安全性 / 特殊 — with colored group icons, neutral selection
// highlight and the 「显示」 optional-item menu)

struct SidebarView: View {
    @EnvironmentObject var ctx: AppContext
    @EnvironmentObject var settings: AppSettings

    @State private var expanded: Set<String> = ["safe_group", "labels_group", "security_group", "special_group"]

    private struct SidebarGroup: Identifiable {
        let key: String
        let style: SidebarGroupStyle
        var id: String { key }
    }

    /// Row order inside each group.
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

    /// 侧栏底部块 — 全宽分隔线 + 居中「初始化 n/8」入口
    /// + 居中的「显示」按钮。分隔线以下整条底色比侧栏深
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

    /// 「数据库」分组行:固定顺序 + 通过「显示」菜单开启的可选行(密码插入
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
            // 折叠箭头 ~26pt、组图标 ~44pt、组名 ~65pt(相对侧栏左缘)
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

/// 分隔凹槽:两侧 0.75pt 浅边线(white 10%)+ 中间 4pt 深槽 #1A1A1A,
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

/// Sidebar row: 16pt icon, name, right-aligned count.
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
            // 行高 27pt;计数右缘 ~205pt,选中高亮为中性灰圆角矩形。
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

