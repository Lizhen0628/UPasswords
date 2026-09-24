import SwiftUI

/// Phase router: setup wizard / lock screen / main window.
struct RootView: View {
    @EnvironmentObject var ctx: AppContext
    @EnvironmentObject var settings: AppSettings
    @Environment(\.openWindow) private var openWindow

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
        .onAppear {
            // 菜单栏「显示 UPasswords」/程序坞 reopen:窗口关闭后据此重建
            StatusItemController.registerOpenWindow { openWindow(id: "main") }
        }
        .sheet(item: $ctx.activeSheet) { sheet in
            SheetFactory.view(for: sheet)
                .environmentObject(ctx)
                .environmentObject(ctx.settings)
                .environmentObject(PasswordSettings.shared)
        }
    }
}

/// 主窗口:970×819 窗口,70pt 自绘工具栏条带,
/// 三列布局(侧栏 225pt / 5pt 凹槽 / 列表 266pt / 5pt 凹槽 / 详情),
/// 不用 NavigationSplitView:其侧栏列在 macOS 26 带 30pt 玻璃内缩且无法关闭。
struct MainWindowView: View {
    @EnvironmentObject var ctx: AppContext
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 0) {
            // 自绘 70pt 工具栏条带(系统 NSToolbar 在 macOS 26 必然附加玻璃胶囊,见 Window/Toolbar.swift)
            MainToolbarView()
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
        // 编辑表单关闭时,自动收掉仍挂在根视图上的编辑类弹层(颜色/符号/模板),
        // 防止孤儿弹层残留并把结果错写到下一个打开的编辑草稿
        .onChange(of: ctx.editDraft != nil) { wasOpen, isOpen in
            if wasOpen, !isOpen, let sheet = ctx.activeSheet, sheet.isEditSheetContext {
                Log.info("ui", "sheet auto-close with edit sheet: \(sheet.id)")
                ctx.activeSheet = nil
            }
        }
        .sheet(item: Binding(
            get: { ctx.editDraft },
            set: { nv in
                // 非 nil 的 set 意味着表单在关闭动画中被写穿(会重新弹出)——记录以备排查
                if let nv { Log.info("ui", "edit sheet binding set cardId=\(nv.card.id) isNew=\(nv.isNew)") }
                ctx.editDraft = nv
            }
        )) { draft in
            EditCardSheet(draft: Binding(
                // 不回退到捕获的 draft:关闭动画中回退值会让 onChange 级联
                // 把旧模型写回 ctx.editDraft,表单会自己重新弹出
                get: { ctx.editDraft },
                set: { ctx.editDraft = $0 }
            ))
            .environmentObject(ctx)
            .environmentObject(ctx.settings)
        }
    }
}

