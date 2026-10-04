import SwiftUI

// MARK: - Sidebar (邮件式悬浮侧栏:顶部红绿灯条带 + 四周留边的大圆角
// 玻璃卡片,卡片材质比内容区明显更深;分节小标题 + 28pt 行,行内 SF Symbol
// 图标 + 右对齐计数,选中态为圆角灰底 + 蓝色图标;「显示」菜单挂在卡片底部)

struct SidebarView: View {
    @EnvironmentObject var ctx: AppContext
    @EnvironmentObject var settings: AppSettings

    /// 顶部条带高度:与右侧工具栏同高,红绿灯悬浮于其上(窗口底色)。
    private static let topBandHeight: CGFloat = 52
    /// 悬浮卡片圆角与四周留边(卡片不贴边,产生浮层感)。
    private static let cardCornerRadius: CGFloat = 20
    private static let cardInsetLeading: CGFloat = 8
    private static let cardInsetTrailing: CGFloat = 4
    private static let cardInsetBottom: CGFloat = 8
    /// 卡片底色加深系数:叠加黑罩,使侧栏与右侧两栏明显分层。
    private static let cardTintOpacity: Double = 0.16

    @State private var bandToggleHovering = false

    /// Row order inside the first (database/account) section.
    private static let safeOrder: [SpecialLabel] = [.allCards, .favorites, .creditCards, .notes, .oneTimeCodes, .passkeys, .recent]
    private static let securityOrder: [SpecialLabel] = [.compromised, .weakPasswords, .samePasswords]
    private static let specialOrder: [SpecialLabel] = [.expiring, .expired, .archived, .templates, .trash]
    private static let optionalOrder: [SpecialLabel] = [.passwords, .files, .images]

    var body: some View {
        VStack(spacing: 0) {
            // 红绿灯条带:窗口底色 + 可拖拽,右端是邮件式的侧栏开关(裸图标),
            // 卡片从条带之下悬浮开始
            ZStack(alignment: .trailing) {
                WindowDragArea()
                    .frame(maxWidth: .infinity)
                    .frame(height: Self.topBandHeight)
                sidebarToggleButton
                    .padding(.trailing, 12)
            }

            // 悬浮玻璃卡片:圆角 + 深色材质 + 细描边 + 轻投影
            VStack(spacing: 0) {
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
                    .padding(.top, 2)
                    .padding(.bottom, 8)
                }
                setupBlock
            }
            .background(
                // 层序:玻璃材质在下,黑罩叠其上(behindWindow 材质不会被
                // 窗口内容垫深),行内容在最前 → 卡片整体比右侧明显更深
                ZStack {
                    SidebarMaterial(cornerRadius: Self.cardCornerRadius)
                    Color.black.opacity(Self.cardTintOpacity)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.22), radius: 9, y: 3)
            .padding(.leading, Self.cardInsetLeading)
            .padding(.trailing, Self.cardInsetTrailing)
            .padding(.bottom, Self.cardInsetBottom)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .background(Color.appBackground)
    }

    /// 邮件式侧栏开关:条带内右端、红绿灯同排的裸图标(无胶囊底),
    /// 悬停现圆形浅高亮。
    private var sidebarToggleButton: some View {
        Button {
            settings.sidebarVisible.toggle()
            Log.info("ui", "band toggle sidebar visible=\(settings.sidebarVisible)")
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.72))
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
                .background(Circle().fill(Color.white.opacity(bandToggleHovering ? 0.10 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { bandToggleHovering = $0 }
        .help(L10n.t("toggle_sidebar_command"))
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

    // MARK: 卡片底部块 — 分隔线 + 居中「初始化 n/8」入口 + 居中的「显示」菜单

    private var setupBlock: some View {
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
        .padding(.top, 8)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
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
