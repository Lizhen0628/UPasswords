//
//  Toolbar.swift
//  UPasswords
//
//  自绘工具栏条带(Safe 布局:红绿灯区 | 数据库名标题 | 8 圆钮,参考图实测)。
//  窗口 chrome 管理见 WindowChrome.swift。
//

import SwiftUI
import AppKit

/// 主窗口自绘工具栏(原版 8 圆钮 + 数据库名标题,布局见文件头注释)。
struct SafeTitleBarView: View {
    @EnvironmentObject var ctx: AppContext

    /// 参考图实测(2x 截图 ÷2):8 个圆钮中心距 574.75…943.75pt,
    /// 相邻间隙(按条目宽 max(35.5, 标签宽) 折算)。
    /// 按钮顺序:密码生成器紧跟「添加」;间距全部统一。
    private let specs: [SafeToolbarButtonSpec] = [
        .add, .generator, .delete, .lock, .sync, .sorting, .aboveAll, .preferences,
    ]
    private static let buttonGap: CGFloat = 8

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Spacer().frame(width: 76) // 红绿灯占位

            Text(ctx.databaseName.isEmpty ? L10n.tBranded("app_title") : ctx.databaseName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.92))
                .padding(.leading, 32)
                .padding(.top, 9)

            Spacer(minLength: 0)

            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(specs.enumerated()), id: \.element.labelKey) { index, spec in
                    if index > 0 { Spacer().frame(width: Self.buttonGap) }
                    if spec.labelKey == "add_button" {
                        SafeAddMenuButton()
                    } else {
                        SafeToolbarButton(spec: spec, ctx: ctx)
                    }
                }
            }
            .padding(.top, 2)
            .padding(.trailing, 8)
        }
        .frame(height: 70)
        .background(WindowDragArea())
        .background(Color.safeBackground)
        // 条带底缘凹槽:与列间竖向凹槽同款(0.75 边线 + 4 深槽 + 0.75 边线)
        .overlay(alignment: .bottom) { ColumnGroove(horizontal: true) }
    }
}

// MARK: - 按钮描述(8 项,与原应用工具栏一一对应)

struct SafeToolbarButtonSpec {
    let labelKey: String
    let helpKey: String
    let symbol: @MainActor () -> String
    let isActive: @MainActor (AppContext) -> Bool
    let isEnabled: @MainActor (AppContext) -> Bool
    let action: @MainActor (AppContext) -> Void

    static let add = SafeToolbarButtonSpec(
        labelKey: "add_button", helpKey: "add_card_command", symbol: { "plus.circle" },
        isActive: { _ in false }, isEnabled: { _ in true },
        action: { $0.activeSheet = .addCard })
    static let delete = SafeToolbarButtonSpec(
        labelKey: "delete_button", helpKey: "delete_command", symbol: { "trash" },
        isActive: { _ in false }, isEnabled: { $0.selectedCardId != nil },
        action: { if let id = $0.selectedCardId { $0.trashCard(id) } })
    static let lock = SafeToolbarButtonSpec(
        labelKey: "lock_button", helpKey: "lock_command", symbol: { "lock.fill" },
        isActive: { _ in false }, isEnabled: { _ in true },
        action: { $0.lock() })
    static let sync = SafeToolbarButtonSpec(
        labelKey: "sync_button", helpKey: "sync_command",
        symbol: { "arrow.triangle.2.circlepath" },
        isActive: { _ in false }, isEnabled: { _ in true },
        action: { ctx in Task { await ctx.sync() } })
    static let generator = SafeToolbarButtonSpec(
        labelKey: "generator_button", helpKey: "generator_command", symbol: { "key" },
        isActive: { _ in false }, isEnabled: { _ in true },
        action: { $0.activeSheet = .generator })
    static let sorting = SafeToolbarButtonSpec(
        labelKey: "sorting_button", helpKey: "sorting_command",
        symbol: { "arrow.up.arrow.down.square" },
        isActive: { _ in false }, isEnabled: { _ in true },
        action: { $0.activeSheet = .sorting })
    static let aboveAll = SafeToolbarButtonSpec(
        labelKey: "above_all_button", helpKey: "above_all_button",
        symbol: { WindowFloatState.shared.floating ? "pin.fill" : "pin" },
        isActive: { _ in WindowFloatState.shared.floating }, isEnabled: { _ in true },
        action: { _ in WindowFloatState.shared.toggle() })
    static let preferences = SafeToolbarButtonSpec(
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

// MARK: - 「添加」下拉菜单(参考原版:按类型直接建卡)

/// 「添加」按钮 = 下拉菜单:互联网帐户/信用卡/一次性代码/身份证护照/Note,
/// 「其他」打开完整模板选择器。选中类型 → 按模板建卡并打开编辑表单。
struct SafeAddMenuButton: View {
    @EnvironmentObject var ctx: AppContext

    var body: some View {
        Menu {
            Button { addTemplate(102) } label: { Label("互联网帐户", systemImage: "globe") }
            Button { addTemplate(101) } label: { Label("信用卡", systemImage: "creditcard") }
            Button { addTemplate(120) } label: { Label("一次性代码", systemImage: "chart.pie.fill") }
            Button { addTemplate(105) } label: { Label("身份证/护照", systemImage: "person.text.rectangle") }
            Button { ctx.activeSheet = .addNote } label: { Label("Note", systemImage: "doc") }
            Button { ctx.activeSheet = .addCard } label: { Label("其他", systemImage: "ellipsis.circle") }
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.20), lineWidth: 1)
                    Image(systemName: "plus.circle")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(.white)
                }
                .frame(width: 35.5, height: 35.5)
                Text(L10n.t("add_button"))
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(0.62))
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(minWidth: 35.5)
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

// MARK: - 圆钮:35.5pt 白色描边圆环 + 16pt 白字形 + 10pt 灰 caption(参考图实测)

struct SafeToolbarButton: View {
    let spec: SafeToolbarButtonSpec
    @ObservedObject var ctx: AppContext
    @ObservedObject private var floatState = WindowFloatState.shared

    var body: some View {
        let active = spec.isActive(ctx)
        Button {
            spec.action(ctx)
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(active ? 0.55 : 0.20), lineWidth: 1)
                    Image(systemName: spec.symbol())
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(active ? Color.accentColor : .white)
                }
                .frame(width: 35.5, height: 35.5)
                Text(L10n.t(spec.labelKey))
                    .font(.system(size: 10))
                    .foregroundStyle(active ? Color.accentColor : Color.white.opacity(0.62))
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(minWidth: 35.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 原应用工具栏按钮不做置灰(删除无选中时为安全空操作),与参考图亮度一致
        .help(L10n.t(spec.helpKey))
    }
}
