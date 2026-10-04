import SwiftUI

// MARK: - Sidebar (邮件式悬浮玻璃面板:从窗口顶部整体悬浮开始,红绿灯与
// 侧栏开关都在面板内部顶行;深色玻璃明显深于内容区;分节小标题 + 32pt 行,
// 行内 SF Symbol 图标 + 右对齐计数,选中态为圆角灰底 + 强调蓝图标与蓝字;
// 「显示」菜单挂在面板底部)

struct SidebarView: View {
    @EnvironmentObject var ctx: AppContext
    @EnvironmentObject var settings: AppSettings

    /// 面板内顶部行高:红绿灯 + 侧栏开关同排(内容行从其下开始;
    /// 高度收紧,保证首行分节标题与邮件一样贴近灯排)。
    private static let topStripHeight: CGFloat = 36
    /// 悬浮面板圆角与四周留边(四边近似均布,面板不贴死窗口边)。
    private static let panelCornerRadius: CGFloat = 22
    private static let panelInset: CGFloat = 6
    /// 面板底色加深系数:叠加黑罩压住透出的壁纸,使面板沉稳、明显深于右侧。
    private static let panelTintOpacity: Double = 0.32
    /// 行相对分节标题的右缩进:体现「标题 → 子项」层级。
    private static let rowIndent: CGFloat = 14

    @State private var bandToggleHovering = false

    /// Row order inside the first (database/account) section.
    private static let safeOrder: [SpecialLabel] = [.allCards, .favorites, .creditCards, .notes, .oneTimeCodes, .passkeys, .recent]
    private static let securityOrder: [SpecialLabel] = [.compromised, .weakPasswords, .samePasswords]
    private static let specialOrder: [SpecialLabel] = [.expiring, .expired, .archived, .templates, .trash]
    private static let optionalOrder: [SpecialLabel] = [.passwords, .files, .images]

    var body: some View {
        panel
            .padding(.top, Self.panelInset)
            .padding(.leading, Self.panelInset)
            .padding(.trailing, Self.panelInset)
            .padding(.bottom, Self.panelInset)
            .background(Color.appBackground)
    }

    /// 悬浮玻璃面板:顶部行(红绿灯区 + 侧栏开关)在面板内部,下接分节
    /// 列表与底部块;圆角 + 深色玻璃 + 细描边 + 轻投影。
    private var panel: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .trailing) {
                WindowDragArea()
                    .frame(maxWidth: .infinity)
                    .frame(height: Self.topStripHeight)
                sidebarToggleButton
                    .padding(.trailing, 12)
            }

            ScrollView {
                VStack(spacing: 0) {
                    // 数据库分节(与邮件的账号分节同位:标题即库名)
                    section(title: ctx.databaseName.isEmpty ? L10n.tBranded("app_title") : ctx.databaseName) {
                        ForEach(safeRows) { sp in
                            SidebarRow(sp: sp)
                                .padding(.leading, Self.rowIndent)
                        }
                    }
                    if !ctx.database.labels.isEmpty {
                        section(title: L10n.db("labels_group")) {
                            ForEach(sortedLabels) { label in
                                SidebarLabelRow(label: label)
                                    .padding(.leading, Self.rowIndent)
                            }
                        }
                    }
                    section(title: L10n.db("security_group")) {
                        ForEach(Self.securityOrder) { sp in
                            SidebarRow(sp: sp)
                                .padding(.leading, Self.rowIndent)
                        }
                    }
                    section(title: L10n.db("special_group")) {
                        ForEach(Self.specialOrder) { sp in
                            SidebarRow(sp: sp)
                                .padding(.leading, Self.rowIndent)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
            setupBlock
        }
        .background(
            // 层序:玻璃材质在下,黑罩叠其上(behindWindow 材质不会被
            // 窗口内容垫深),行内容在最前 → 面板整体深色沉稳
            ZStack {
                SidebarMaterial(cornerRadius: Self.panelCornerRadius)
                Color.black.opacity(Self.panelTintOpacity)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: Self.panelCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Self.panelCornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 9, y: 3)
    }

    /// 邮件式侧栏开关:面板顶行右端、红绿灯同排的裸图标(无胶囊底),
    /// 悬停现圆形浅高亮;提示随状态切换(隐藏/显示边栏)。
    private var sidebarToggleButton: some View {
        Button {
            settings.sidebarVisible.toggle()
            Log.info("ui", "panel toggle sidebar visible=\(settings.sidebarVisible)")
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.72))
                .frame(width: 40, height: 34)
                .contentShape(Rectangle())
                .background(Ellipse().fill(Color.white.opacity(bandToggleHovering ? 0.10 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { bandToggleHovering = $0 }
        .help(settings.sidebarVisible ? L10n.t("hide_sidebar_command") : L10n.t("show_sidebar_command"))
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
                    .foregroundStyle(selected ? Color.accentColor : Color.primary)
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
            .frame(height: 32)
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

    /// 邮件式选中态:图标与文字同为系统强调色(如选中邮箱的蓝色托盘+蓝字)。
    private var iconColor: Color {
        if selected { return .accentColor }
        return tint ?? Color.white.opacity(0.75)
    }
}
