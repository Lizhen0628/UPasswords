import SwiftUI

// MARK: - Sidebar (邮件式分节列表:通高材质侧栏,分节小标题 + 28pt 行,
// 行内 SF Symbol 图标 + 右对齐计数,选中态为圆角灰底 + 蓝色图标;
// 分节:数据库(账号位) / 标签 / 安全性 / 特殊,「显示」菜单挂在底部)

struct SidebarView: View {
    @EnvironmentObject var ctx: AppContext
    @EnvironmentObject var settings: AppSettings

    /// 顶部留空高度:红绿灯 + 可拖拽条带区(行内容从其下开始)。
    private static let topStripHeight: CGFloat = 52

    /// Row order inside the first (database/account) section.
    private static let safeOrder: [SpecialLabel] = [.allCards, .favorites, .creditCards, .notes, .oneTimeCodes, .passkeys, .recent]
    private static let securityOrder: [SpecialLabel] = [.compromised, .weakPasswords, .samePasswords]
    private static let specialOrder: [SpecialLabel] = [.expiring, .expired, .archived, .templates, .trash]
    private static let optionalOrder: [SpecialLabel] = [.passwords, .files, .images]

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // 数据库分节(与邮件的账号分节同位:标题即库名)
                section(title: ctx.databaseName.isEmpty ? L10n.tBranded("app_title") : ctx.databaseName) {
                    ForEach(safeRows) { sp in
                        SidebarRow(sp: sp)
                    }
                }
                if !ctx.database.labels.isEmpty {
                    section(title: L10n.db("labels_group")) {
                        ForEach(sortedLabels) { label in
                            SidebarLabelRow(label: label)
                        }
                    }
                }
                section(title: L10n.db("security_group")) {
                    ForEach(Self.securityOrder) { sp in
                        SidebarRow(sp: sp)
                    }
                }
                section(title: L10n.db("special_group")) {
                    ForEach(Self.specialOrder) { sp in
                        SidebarRow(sp: sp)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, Self.topStripHeight + 4)
            .padding(.bottom, 8)
        }
        .background(SidebarMaterial())
        // 顶部条带:遮住滚过的行,并提供红绿灯旁的拖拽区
        .overlay(alignment: .top) {
            WindowDragArea()
                .frame(maxWidth: .infinity)
                .frame(height: Self.topStripHeight)
                .background(SidebarMaterial())
        }
        .safeAreaInset(edge: .bottom) {
            setupCard
        }
    }

    // MARK: 分节(小标题 + 行)

    @ViewBuilder
    private func section(title: String, @ViewBuilder rows: () -> some View) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.42))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 10)
            .padding(.top, 14)
            .padding(.bottom, 4)
        rows()
    }

    /// 「数据库」分节行:固定顺序 + 通过「显示」菜单开启的可选行(密码插入
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

    private var sortedLabels: [CardLabel] {
        ctx.database.labels.sorted { a, b in
            a.pinToTop == b.pinToTop
                ? a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                : a.pinToTop && !b.pinToTop
        }
    }

    // MARK: 底部块 — 分隔线 + 居中「初始化 n/8」入口 + 居中的「显示」菜单

    private var setupCard: some View {
        VStack(spacing: 6) {
            Divider()
            Button {
                ctx.activeSheet = .setupPlan
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.white.opacity(0.35))
                    Text("\(L10n.t("setup_text")) \(ctx.setupCompletedCount)/8")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.6))
                }
                .frame(height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            showMenu
        }
        .padding(.top, 10)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(SidebarMaterial().overlay(Divider(), alignment: .top))
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
                    Log.info("ui", "sidebar optional toggle \(sp.rawValue) now=\(settings.sidebarOptionalItems)")
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
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.6))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(height: 22)
    }
}

/// Sidebar row: 14pt icon, name, right-aligned count (邮件式 28pt 行)。
struct SidebarRow: View {
    @EnvironmentObject var ctx: AppContext
    @EnvironmentObject var settings: AppSettings
    let sp: SpecialLabel

    var body: some View {
        SidebarRowButton(title: sp.name, system: sp.systemImage,
                         count: settings.showCardCount ? ctx.count(for: .special(sp)) : nil,
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
        SidebarRowButton(title: label.name, system: "tag",
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
    var count: Int? = nil
    /// 标签行带身份色(用户自选),特殊分节行保持邮件式的单色图标。
    var tint: Color? = nil
    var selected: Bool
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: system)
                    .font(.system(size: 13.5))
                    .foregroundStyle(iconColor)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .lineLimit(1)
                Spacer()
                if let count {
                    Text("\(count)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Color.white.opacity(selected ? 0.8 : 0.42))
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 10)
            .frame(height: 28)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? Color.white.opacity(0.13)
                          : hovering ? Color.white.opacity(0.06)
                          : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    /// 邮件式选中态:图标转为系统强调色(如选中邮箱的蓝色托盘),文字反白。
    private var iconColor: Color {
        if selected { return .accentColor }
        return tint ?? Color.white.opacity(0.75)
    }
}
