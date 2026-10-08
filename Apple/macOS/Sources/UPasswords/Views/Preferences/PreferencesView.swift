import SwiftUI
import AppKit
import UniformTypeIdentifiers
import UPasswordsCore
import UPasswordsPersistence

/// 邮件式两栏版式的统一定位基准:标签右对齐至 labelWidth,控件列从
/// labelWidth + spacing 起。复选框/按钮行缩进到同一竖线,保证整版对齐。
private let settingsRowSpacing: CGFloat = 8
/// 弹出菜单统一宽度(邮件式定宽列)。
private let popupPickerWidth: CGFloat = 280
/// 锁定屏幕封面预览宽度(略宽于中文标签行块,与英文行块近似齐宽)。
private let lockScreenCoverWidth: CGFloat = 376
/// 云同步页内容统一列宽:说明文字不改变块宽,切换云端类型时单选组与
/// 测试按钮位置保持不动。
private let cloudPaneWidth: CGFloat = 480
/// 自动备份页备份列表宽度:与表单区自然宽度对齐。列表行的 Spacer 会把
/// 还原/删除推到所给宽度的最右端,不限宽时按钮顶到版心远端,
/// 与文件名之间隔出大段空白。
private let backupListWidth: CGFloat = 380

/// 设置窗口——邮件风格:顶部「图标+文字」标签条(选中项圆角高亮),
/// 下方经典设置版式(标签右对齐带冒号 + 弹出菜单/复选框,无分组卡片)。
/// 独立窗口(⌘,)时标题随所选标签变化,同邮件。
struct PreferencesView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case appearance = "appearance_title"
        case shortcuts = "shortcuts_title"
        case security = "security_title"
        case autoBackup = "auto_backup_title"
        case autofill = "autofill_title"
        case lockScreen = "lock_screen_title"
        case cloud = "cloud_sync_title"
        var id: String { rawValue }

        /// 标签条图标(邮件风格:SF Symbol 居上,文字居下)。
        var symbolName: String {
            switch self {
            case .appearance: return "paintpalette"
            case .security: return "lock.shield"
            case .autoBackup: return "externaldrive"
            case .autofill: return "key.horizontal"
            case .lockScreen: return "lock.rectangle"
            case .cloud: return "cloud"
            case .shortcuts: return "command"
            }
        }
    }

    /// 以 sheet 方式呈现在主窗口内时不同步窗口标题(避免改掉主窗标题)。
    var syncWindowTitle = true

    @State private var tab: Tab = .appearance

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            HairlineDivider(horizontal: true)
            Group {
                switch tab {
                case .appearance: AppearancePane()
                case .security: SecurityPane()
                case .autoBackup: AutoBackupPane()
                case .autofill: AutofillPane()
                case .lockScreen: LockScreenPane()
                case .cloud: CloudPane()
                case .shortcuts: ShortcutsPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 560, minHeight: 430)
        .background(WindowTitleSync(title: syncWindowTitle ? L10n.t(tab.rawValue) : nil))
        .onChange(of: tab) { _, newValue in
            Log.info("ui", "preferences tab=\(newValue.rawValue)")
        }
    }

    // MARK: - 标签条

    private var tabStrip: some View {
        HStack(spacing: 14) {
            ForEach(Tab.allCases) { t in
                TabButton(tab: t, isSelected: t == tab) { tab = t }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - 标签条按钮

private struct TabButton: View {
    let tab: PreferencesView.Tab
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: tab.symbolName)
                    .font(.system(size: 22))
                    .frame(height: 25)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                Text(L10n.t(tab.rawValue))
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            }
            .frame(minWidth: 66, minHeight: 56)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(isSelected ? 0.09 : (hovering ? 0.05 : 0)))
                if isSelected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - 邮件风格版式部件

/// 设置内容统一容器:限宽后水平居中(邮件式版心),窄窗口回退占满。
private struct PaneContainer<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
                .padding(.horizontal, 24)
        }
    }
}

/// 邮件式定宽弹出菜单:原生 NSPopUpButton。
/// SwiftUI 的 menu 样式 Picker 按内容自适应宽度,各行参差且无法撑满定宽;
/// 原生控件整列统一宽度,文字左对齐、箭头靠右,同邮件。
private struct PopupPicker<Tag: Hashable>: View {
    var width: CGFloat = popupPickerWidth
    var isEnabled = true
    let selection: Binding<Tag>
    let items: [(String, Tag)]

    var body: some View {
        PopupPickerBacking(selection: selection, items: items, isEnabled: isEnabled)
            .frame(width: width)
    }
}

private struct PopupPickerBacking<Tag: Hashable>: NSViewRepresentable {
    let selection: Binding<Tag>
    let items: [(String, Tag)]
    let isEnabled: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.target = context.coordinator
        popup.action = #selector(Coordinator.selectionChanged(_:))
        rebuild(popup)
        return popup
    }

    func updateNSView(_ popup: NSPopUpButton, context: Context) {
        // .disabled 修饰符不会传导到 NSViewRepresentable,需显式同步
        popup.isEnabled = isEnabled
        context.coordinator.selection = selection
        context.coordinator.items = items
        rebuild(popup)
        if let index = items.firstIndex(where: { $0.1 == selection.wrappedValue }),
           popup.indexOfSelectedItem != index {
            popup.selectItem(at: index)
        }
    }

    /// 菜单项与数据源不一致时(首次挂载、本地化或选项集合变化)重建。
    private func rebuild(_ popup: NSPopUpButton) {
        let titles = items.map(\.0)
        let current = popup.menu?.items.map(\.title) ?? []
        guard current != titles else { return }
        popup.removeAllItems()
        popup.addItems(withTitles: titles)
    }

    final class Coordinator: NSObject {
        var selection: Binding<Tag>?
        var items: [(String, Tag)] = []

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            guard let selection, sender.indexOfSelectedItem < items.count else { return }
            selection.wrappedValue = items[sender.indexOfSelectedItem].1
        }
    }
}

// MARK: - Appearance

struct AppearancePane: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        PaneContainer {
            // Grid 让标签按文字自然宽度紧贴弹窗(同锁定屏幕页);
            // 复选框行以 0×0 占位格对齐到弹窗列
            Grid(alignment: .leading, horizontalSpacing: settingsRowSpacing, verticalSpacing: 14) {
                GridRow {
                    Text(L10n.t("language_prompt"))
                    PopupPicker(selection: $settings.languageOverride, items: [
                        (L10n.t("system_default_text"), ""),
                        ("简体中文", "zh-Hans"),
                        ("English", "en"),
                    ])
                }
                GridRow {
                    Text(L10n.t("sorting_prompt"))
                    PopupPicker(selection: sortingBinding, items: Sorting.allCases.map { ($0.name, $0) })
                }
                GridRow { Color.clear.frame(width: 0, height: 0).gridCellColumns(2) }
                GridRow {
                    Text(L10n.t("favorites_at_top_setting"))
                    Toggle("", isOn: $settings.favoritesAtTop)
                        .labelsHidden()
                }
                GridRow {
                    Text(L10n.t("show_card_count_setting"))
                    Toggle("", isOn: $settings.showCardCount)
                        .labelsHidden()
                }
                GridRow {
                    Text(L10n.t("hide_passwords_setting"))
                    Toggle("", isOn: $settings.hidePasswords)
                        .labelsHidden()
                }
                GridRow {
                    Text(L10n.t("use_website_icons_setting"))
                    Toggle("", isOn: $settings.useWebsiteIcons)
                        .labelsHidden()
                }
                GridRow { Color.clear.frame(width: 0, height: 0).gridCellColumns(2) }
                GridRow {
                    Text(L10n.t("search_by_labels_setting"))
                    Toggle("", isOn: $settings.searchByLabels)
                        .labelsHidden()
                }
                GridRow {
                    Text(L10n.t("search_passwords_setting"))
                    Toggle("", isOn: $settings.searchPasswords)
                        .labelsHidden()
                }
                GridRow {
                    Text(L10n.t("global_search_setting"))
                    Toggle("", isOn: .constant(true))
                        .labelsHidden()
                        .disabled(true)
                        .help(L10n.t("recommended_text"))
                }
            }
        }
    }

    private var sortingBinding: Binding<Sorting> {
        Binding(get: { settings.sortingValue }, set: { settings.sortingValue = $0 })
    }
}

// MARK: - Security

struct SecurityPane: View {
    @EnvironmentObject var ctx: AppContext
    @EnvironmentObject var settings: AppSettings

    private let lockChoices: [(String, Int)] = [
        (L10n.t("never_text"), 0), ("1 m", 60), ("5 m", 300), ("15 m", 900), ("1 h", 3600),
    ]
    private let requireChoices: [(String, Int)] = [
        (L10n.t("never_text"), 0), ("8 h", 28800), ("1 d", 86400), ("7 d", 604800),
    ]
    private let clipboardChoices: [(String, Int)] = [
        (L10n.t("off_text"), 0), ("10 s", 10), ("30 s", 30), ("1 m", 60), ("2 m", 120),
    ]
    private let attemptsChoices: [(String, Int)] = [
        (L10n.t("unlimited_text"), 0), ("5", 5), ("10", 10), ("20", 20),
    ]
    private let breachCheckChoices: [(String, Int)] = [
        ("1" + L10n.t("days_text"), 1), ("7" + L10n.t("days_text"), 7), ("30" + L10n.t("days_text"), 30),
    ]

    /// 上次全量在线检查时间(AppContext 记录,进入本页时读取)。
    private var lastBreachCheckText: String {
        guard let date = ctx.lastBreachCheck else { return L10n.t("never_text") }
        return DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .short)
    }

    var body: some View {
        PaneContainer {
            // Grid 版式同外观页;长说明文字限宽,避免撑大内容列。
            // 分组:密码/剪贴板/自毁在上,锁定行为在下
            Grid(alignment: .leading, horizontalSpacing: settingsRowSpacing, verticalSpacing: 14) {
                GridRow {
                    Text(L10n.t("require_password_setting"))
                    PopupPicker(selection: $settings.requirePasswordSeconds, items: requireChoices)
                }
                GridRow {
                    Text(L10n.t("empty_clipboard_setting"))
                    PopupPicker(selection: $settings.clipboardClearSeconds, items: clipboardChoices)
                }
                GridRow {
                    Text(L10n.t("password_attempts_setting"))
                    PopupPicker(selection: $settings.selfDestructAttempts, items: attemptsChoices)
                }
                GridRow {
                    Text(L10n.t("auto_breach_check_setting"))
                    Toggle("", isOn: $settings.autoBreachCheckEnabled)
                        .labelsHidden()
                }
                GridRow {
                    Text(L10n.t("breach_check_interval_setting"))
                    PopupPicker(selection: $settings.autoBreachCheckDays, items: breachCheckChoices)
                        .disabled(!settings.autoBreachCheckEnabled)
                }
                GridRow {
                    Text(L10n.t("breach_last_check_setting"))
                    Text(lastBreachCheckText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                GridRow { Color.clear.frame(width: 0, height: 0).gridCellColumns(2) }
                GridRow {
                    Text(L10n.t("auto_lock_setting"))
                    PopupPicker(selection: $settings.autoLockSeconds, items: lockChoices)
                }
                GridRow {
                    Text(L10n.t("lock_in_background_button"))
                    Toggle("", isOn: $settings.lockInBackground)
                        .labelsHidden()
                }
                GridRow {
                    Text(L10n.t("lock_if_window_closed_button"))
                    Toggle("", isOn: $settings.lockIfWindowClosed)
                        .labelsHidden()
                }
                GridRow {
                    Text(L10n.t("fast_unlock_setting"))
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("", isOn: fastUnlockBinding)
                            .labelsHidden()
                            .disabled(!ctx.touchIDAvailable)
                        Text(ctx.touchIDAvailable
                             ? L10n.t("touch_id_login_warning")
                             : L10n.t("not_recommended_text") + ": Touch ID unavailable")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 250, alignment: .leading)
                    }
                }
                GridRow {
                    Color.clear.frame(width: 0, height: 0)
                    HStack(spacing: 10) {
                        Button(L10n.t("change_password_button")) {
                            Log.info("ui", "open change password sheet")
                            ctx.activeSheet = .changePassword
                        }
                        Button(L10n.t("erase_data_command"), role: .destructive) {
                            Log.info("ui", "open erase data sheet")
                            ctx.activeSheet = .eraseData
                        }
                    }
                }
            }
        }
    }

    private var fastUnlockBinding: Binding<Bool> {
        Binding(
            get: { settings.fastUnlock },
            set: { on in
                settings.fastUnlock = on
                if on {
                    // 开启时保存当前数据库密码的生物识别副本
                    ctx.enableTouchIDUnlock()
                } else {
                    PasswordStore.removeBiometricPassword(databaseName: ctx.databaseName)
                }
            }
        )
    }
}

// MARK: - Auto backup

struct AutoBackupPane: View {
    @EnvironmentObject var ctx: AppContext
    @EnvironmentObject var settings: AppSettings

    private let intervalChoices: [(String, Int)] = [
        ("1 d", 1), ("3 d", 3), ("7 d", 7), ("30 d", 30),
    ]

    /// 备份文件列表快照。故意不用计算属性直读文件系统:SwiftUI 不感知
    /// 文件系统变化,立即备份/删除后必须显式 reload 才会刷新列表。
    @State private var backups: [URL] = []

    var body: some View {
        PaneContainer {
            // Grid 版式同外观页:标签紧贴内容,复选框/按钮对齐到弹窗列
            Grid(alignment: .leading, horizontalSpacing: settingsRowSpacing, verticalSpacing: 14) {
                GridRow {
                    Text(L10n.t("auto_backup_setting"))
                    Toggle("", isOn: $settings.autoBackupEnabled)
                        .labelsHidden()
                }
                GridRow {
                    Text(L10n.t("backup_interval_setting"))
                    PopupPicker(selection: $settings.backupIntervalDays, items: intervalChoices)
                        .disabled(!settings.autoBackupEnabled)
                }
                GridRow {
                    Text(L10n.t("backup_location_setting"))
                    Text("~/Library/Application Support/UPasswords/Backups")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                    GridRow {
                        Text(L10n.t("logs_location_setting"))
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(Log.fileURL.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: 170, alignment: .leading)
                            Button(L10n.t("open_logs_folder_button")) {
                                Log.info("ui", "open logs folder")
                                NSWorkspace.shared.open(Log.dir)
                            }
                        }
                    }
                    GridRow {
                        Text(L10n.t("logs_level_setting"))
                        PopupPicker(selection: logLevelBinding, items: [
                            (L10n.t("log_level_debug"), Log.Level.debug.rawValue),
                            (L10n.t("log_level_info"), Log.Level.info.rawValue),
                            (L10n.t("log_level_warn"), Log.Level.warn.rawValue),
                            (L10n.t("log_level_error"), Log.Level.error.rawValue),
                        ])
                    }
                    GridRow {
                        Color.clear.frame(width: 0, height: 0)
                        Button(L10n.t("clear_log_button")) {
                            Log.clear()
                            Log.info("ui", "log cleared from preferences")
                            AppToast.shared.show(L10n.t("log_cleared_message"))
                        }
                    }
                GridRow { Color.clear.frame(width: 0, height: 0).gridCellColumns(2) }
                GridRow {
                    Color.clear.frame(width: 0, height: 0)
                    HStack(spacing: 10) {
                        Button(L10n.t("backup_now_button")) {
                            Log.info("ui", "backup now from preferences")
                            ctx.backupNow()
                            reloadBackups()
                        }
                        Button(L10n.t("restore_command")) { restore() }
                    }
                }
            }
            // 备份列表放在 Grid 之外(占满版心宽):列表行的 Spacer 是弹性元素,
            // 放在 Grid 内会把整个 Grid 拉满可用宽度,Grid 把富余宽度分配到
            // 各列轨道,标签列随之被撑宽,标签与值之间出现大段空白
            // (其余设置页的 Grid 无弹性元素,保持贴合内容宽度,无此问题)。
            // 限宽 backupListWidth 与表单区右缘对齐,行尾按钮不至离文件名过远。
            if !backups.isEmpty {
                backupList
                    .frame(maxWidth: backupListWidth, alignment: .leading)
                    .padding(.top, 14)
            }
        }
        .onAppear { reloadBackups() }
    }

    private var backupList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t("last_backup_completed_text"))
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(Array(backups.enumerated()), id: \.element.absoluteString) { i, url in
                    HStack {
                        Image(systemName: "doc.badge.clock")
                            .foregroundStyle(.secondary)
                        Text(url.lastPathComponent)
                        Spacer()
                        Button(L10n.t("restore_button")) { restoreFrom(url) }
                            .buttonStyle(.link)
                        Button(L10n.t("delete_button")) { deleteBackup(url) }
                            .buttonStyle(.link)
                    }
                    .padding(.vertical, 5)
                    if i < backups.count - 1 {
                        HairlineDivider(horizontal: true)
                    }
                }
            }
        }
    }

    /// 从文件系统重读备份列表(进入面板、立即备份、删除之后调用)。
    private func reloadBackups() {
        backups = ctx.store.backups(name: ctx.databaseName)
    }

    /// 日志级别选择(popup 存 Level rawValue,变更即时生效并持久化)。
    private var logLevelBinding: Binding<String> {
        Binding(
            get: { Log.minLevel.rawValue },
            set: { Log.setMinLevel($0) }
        )
    }

    /// 还原…:打开文件浏览选择备份文件(默认定位到当前库的备份目录,
    /// 也可选任意 .upw 文件,如手动挪进来的备份),选定后走统一确认还原。
    @MainActor private func restore() {
        let backupDir = ctx.store.backupDir(for: ctx.databaseName)
        // 备份目录尚不存在(从未备份过)时先建好,面板才能定位进去
        try? FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        let panel = NSOpenPanel()
        panel.title = L10n.t("restore_command")
        panel.directoryURL = backupDir
        panel.allowedContentTypes = [UTType(filenameExtension: "upw")].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else {
            Log.info("ui", "restore pick cancelled")
            return
        }
        Log.info("ui", "restore backup picked from preferences: \(url.lastPathComponent)")
        restoreFrom(url)
    }

    @MainActor private func restoreFrom(_ url: URL) {
        let alert = NSAlert()
        alert.messageText = L10n.t("confirm_restore_query")
        alert.addButton(withTitle: L10n.t("restore_button"))
        alert.addButton(withTitle: L10n.t("cancel_button"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try ctx.store.restore(backup: url, to: ctx.databaseName)
            try ctx.unlock(name: ctx.databaseName, password: ctx.password)
            AppToast.shared.show(L10n.t("database_restored_message"))
        } catch {
            AppToast.shared.show(error.localizedDescription)
        }
        reloadBackups()
    }

    /// 删除单个备份文件,确认后执行并刷新列表。
    @MainActor private func deleteBackup(_ url: URL) {
        let alert = NSAlert()
        alert.messageText = L10n.t("confirm_delete_backup_query")
        alert.informativeText = url.lastPathComponent
        alert.addButton(withTitle: L10n.t("delete_button"))
        alert.addButton(withTitle: L10n.t("cancel_button"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Log.info("ui", "delete backup from preferences: \(url.lastPathComponent)")
        do {
            try ctx.store.deleteBackup(url, name: ctx.databaseName)
            AppToast.shared.show(L10n.t("backup_deleted_message"))
        } catch {
            Log.error("backup", "delete backup \(url.lastPathComponent) failed: \(error)")
            AppToast.shared.show(error.localizedDescription)
        }
        reloadBackups()
    }
}

// MARK: - Autofill

struct AutofillPane: View {
    var body: some View {
        PaneContainer {
            VStack(alignment: .leading, spacing: 16) {
                Label(L10n.t("browser_integration_title"), systemImage: "safari")
                    .font(.headline)
                Text(L10n.t("install_extension_text"))
                    .foregroundStyle(.secondary)
                Label(L10n.t("use_for_autofill_button"), systemImage: "iphone")
                    .font(.headline)
                    .padding(.top, 10)
                Text(L10n.t("autofill_note"))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Lock screen

struct LockScreenPane: View {
    @EnvironmentObject var settings: AppSettings

    /// 背景选项的 tag:壁纸 / 质感 i / 自定图片(与三态背景类型一一对应)。
    private enum BackgroundChoice: Hashable {
        case wallpaper, image
        case texture(Int)
    }

    var body: some View {
        PaneContainer {
            VStack(alignment: .leading, spacing: 22) {
                // Grid 让标签按文字自然宽度紧贴弹窗(中文紧凑、英文不折行),
                // 两行弹窗仍对齐在同一竖线
                Grid(alignment: .leading, horizontalSpacing: settingsRowSpacing, verticalSpacing: 14) {
                    GridRow {
                        Text(L10n.t("lock_screen_background_prompt"))
                        PopupPicker(
                            selection: backgroundSelection,
                            items: [(L10n.t("lock_wallpaper_choice"), BackgroundChoice.wallpaper)]
                                + (0..<LockTextures.count).map { ("\((L10n.t("texture_text"))) \($0 + 1)", BackgroundChoice.texture($0)) }
                                + [(L10n.t("lock_custom_image_choice"), BackgroundChoice.image)]
                        )
                    }
                    if settings.lockBackgroundKind == .image {
                        GridRow {
                            Color.clear.frame(width: 0, height: 0)
                            HStack(spacing: 10) {
                                Button(L10n.t("choose_image_button")) { pickImage() }
                                Text(settings.lockBackgroundImageName.isEmpty
                                     ? L10n.t("no_image_selected_hint")
                                     : settings.lockBackgroundImageName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    GridRow {
                        Text(L10n.t("lock_screen_text_prompt"))
                        PopupPicker(selection: $settings.lockWhiteText, items: [
                            (L10n.t("white_text_text"), true),
                            (L10n.t("black_text_text"), false),
                        ])
                    }
                    GridRow {
                        Color.clear.frame(width: 0, height: 0)
                        Button(L10n.t("restore_defaults_button")) { resetToDefaults() }
                    }
                }
                ZStack {
                    previewBackground
                    VStack {
                        Image(systemName: "lock.circle").font(.system(size: 30))
                        Text(L10n.tBranded("app_title")).font(.headline)
                    }
                    // 黑/白用字面颜色:.primary 在深色模式下渲染为白色,
                    // 会导致「黑色文本」设置在预览中看起来不生效
                    .foregroundStyle(settings.lockWhiteText ? Color.white : Color.black)
                }
                // 封面与标签行同起点左对齐,宽度独立,不与弹窗列右缘对齐
                .frame(width: lockScreenCoverWidth, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    /// 背景 popup 选择:三个背景类型与质感索引共用一个选择值。
    private var backgroundSelection: Binding<BackgroundChoice> {
        Binding(
            get: {
                switch settings.lockBackgroundKind {
                case .wallpaper: return .wallpaper
                case .image: return .image
                case .texture: return .texture(settings.lockTexture)
                }
            },
            set: { choice in
                switch choice {
                case .wallpaper:
                    settings.lockBackgroundKindRaw = LockBackgroundKind.wallpaper.rawValue
                case .image:
                    settings.lockBackgroundKindRaw = LockBackgroundKind.image.rawValue
                case .texture(let index):
                    settings.lockBackgroundKindRaw = LockBackgroundKind.texture.rawValue
                    settings.lockTexture = index
                }
            }
        )
    }

    /// 预览背景:与真实锁屏共用同一渲染(壁纸模糊/质感渐变/自定图片)。
    @ViewBuilder private var previewBackground: some View {
        LockScreenBackground.view(
            kind: settings.lockBackgroundKind,
            textureIndex: settings.lockTexture,
            imageName: settings.lockBackgroundImageName
        )
    }

    @MainActor private func pickImage() {
        let panel = NSOpenPanel()
        panel.title = L10n.t("choose_lock_image_prompt")
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let source = panel.url else {
            Log.info("ui", "lock image pick cancelled")
            return
        }
        do {
            settings.lockBackgroundImageName = try LockScreenImageStore.install(from: source)
            settings.lockBackgroundKindRaw = LockBackgroundKind.image.rawValue
            Log.info("ui", "lock image set name=\(settings.lockBackgroundImageName)")
        } catch {
            Log.error("ui", "lock image install failed: \(error)")
            AppToast.shared.show(error.localizedDescription)
        }
    }

    /// 恢复默认:桌面壁纸模糊(macOS 原生风格)+ 白色文本,清除自定图片及其文件。
    private func resetToDefaults() {
        settings.lockBackgroundKindRaw = LockBackgroundKind.wallpaper.rawValue
        settings.lockBackgroundImageName = ""
        LockScreenImageStore.removeAll()
        settings.lockTexture = AppSettings.defaultLockTexture
        settings.lockWhiteText = true
        Log.info("ui", "lock screen settings reset to defaults")
        AppToast.shared.show(L10n.t("lock_screen_reset_message"))
    }
}

// MARK: - Cloud sync

struct CloudPane: View {
    var body: some View {
        ConfigureCloudSheetContents()
    }
}

/// Body of ConfigureCloudSheet reusable in the preferences pane.
struct ConfigureCloudSheetContents: View {
    @EnvironmentObject var ctx: AppContext
    @EnvironmentObject var settings: AppSettings
    @State private var testing = false
    @State private var testResult: String? = nil

    private let autoSyncChoices: [(String, Int)] = [
        ("30" + L10n.t("seconds_abbr_text"), 30),
        ("1" + L10n.t("minutes_abbr_text"), 60),
        ("5" + L10n.t("minutes_abbr_text"), 300),
        ("15" + L10n.t("minutes_abbr_text"), 900),
        ("1" + L10n.t("hours_text"), 3600),
    ]

    var body: some View {
        PaneContainer {
            VStack(alignment: .leading, spacing: 20) {
                // Grid 版式同其他页:标签按文字自然宽度紧贴内容
                Grid(alignment: .leading, horizontalSpacing: settingsRowSpacing, verticalSpacing: 14) {
                    GridRow {
                        Text(L10n.t("cloud_prompt"))
                        Picker("", selection: Binding(
                            get: { settings.cloud }, set: { settings.cloudType = $0.rawValue }
                        )) {
                            ForEach(CloudType.allCases) { c in
                                Text(c.name).tag(c)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.radioGroup)
                    }
                    if settings.cloud == .webdav {
                        GridRow {
                            Color.clear.frame(width: 0, height: 0)
                            Toggle("HTTPS", isOn: $settings.webdav.useHTTPS)
                        }
                        GridRow {
                            Text(L10n.t("host_prompt"))
                            field("dav.example.com", text: $settings.webdav.host)
                        }
                        GridRow {
                            Text(L10n.t("port_prompt"))
                            field("443", value: $settings.webdav.port)
                        }
                        GridRow {
                            Text(L10n.t("local_path_prompt"))
                            field("/UPasswords/", text: $settings.webdav.path)
                        }
                        GridRow {
                            Text(L10n.t("user_name_prompt"))
                            field("", text: $settings.webdav.user)
                        }
                        GridRow {
                            Text(L10n.t("password_prompt"))
                            SecureField("", text: $settings.webdav.password)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 240)
                        }
                    }
                    if settings.cloud == .icloud {
                        GridRow {
                            Text(L10n.t("ios_icloud_folder_label"))
                            HStack(spacing: 8) {
                                Button(settings.icloudFolderName.isEmpty
                                       ? L10n.t("ios_icloud_pick_folder_button")
                                       : settings.icloudFolderName) {
                                    Log.info("ui", "icloud folder pick from preferences")
                                    ctx.pickICloudFolder()
                                }
                                if !settings.icloudFolderName.isEmpty {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                    }
                    if settings.cloud == .webdav || settings.cloud == .icloud {
                        GridRow {
                            Color.clear.frame(width: 0, height: 0)
                            HStack(spacing: 8) {
                                Button(L10n.t("test_connection_button")) {
                                    Log.info("ui", "cloud connection test from preferences")
                                    Task { await test() }
                                }
                                if testing {
                                    ProgressView().controlSize(.small)
                                }
                                if let testResult {
                                    Text(testResult).font(.caption)
                                }
                            }
                        }
                        GridRow {
                            Text(L10n.t("auto_sync_setting"))
                            Toggle("", isOn: $settings.autoSyncEnabled)
                                .labelsHidden()
                        }
                        GridRow {
                            Text(L10n.t("auto_sync_interval_setting"))
                            PopupPicker(selection: $settings.autoSyncSeconds, items: autoSyncChoices)
                                .disabled(!settings.autoSyncEnabled)
                        }
                    }
                }
                if settings.cloud == .icloud {
                    Label(L10n.t("icloud_sync_info"), systemImage: "icloud")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if settings.cloud != .none && settings.cloud != .webdav {
                    Label(L10n.t("not_configured_state"), systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: cloudPaneWidth, alignment: .leading)
        }
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.roundedBorder)
            .frame(width: 240)
    }

    private func field(_ placeholder: String, value: Binding<Int>) -> some View {
        TextField(placeholder, value: value, format: .number)
            .textFieldStyle(.roundedBorder)
            .frame(width: 240)
    }

    private func test() async {
        guard let driver = ctx.makeCloudDriver() else { return }
        testing = true
        do {
            try await driver.testConnection()
            testResult = L10n.t("success_title")
            ctx.markSetupTaskDone(.cloudSync)
        } catch {
            testResult = error.localizedDescription
        }
        testing = false
    }
}

// MARK: - Shortcuts

/// 快捷键页:录制后即时作用于菜单项(Commands 观察 ShortcutStore)。
struct ShortcutsPane: View {
    @ObservedObject private var shortcuts = ShortcutStore.shared

    var body: some View {
        PaneContainer {
            Grid(alignment: .leading, horizontalSpacing: settingsRowSpacing, verticalSpacing: 14) {
                GridRow {
                    Text(L10n.t("lock_shortcut_setting"))
                    ShortcutRecorder(key: $shortcuts.lockKey, modifiers: $shortcuts.lockModifiers)
                        .frame(width: popupPickerWidth, height: 26)
                }
                GridRow {
                    Text(L10n.t("main_window_shortcut_setting"))
                    ShortcutRecorder(key: $shortcuts.showMainKey, modifiers: $shortcuts.showMainModifiers)
                        .frame(width: popupPickerWidth, height: 26)
                }
            }
        }
    }
}

// MARK: - 窗口标题同步

/// 把所在 NSWindow 的标题同步为当前标签名(邮件设置窗:标题=所选标签)。
/// title 为 nil 时是 sheet 内嵌模式,不触碰宿主窗口标题。
private struct WindowTitleSync: NSViewRepresentable {
    let title: String?

    func makeNSView(context: Context) -> NSView { TitleView(title: title) }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? TitleView)?.title = title
    }

    final class TitleView: NSView {
        var title: String? { didSet { apply() } }

        init(title: String?) {
            self.title = title
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        private func apply() {
            guard let title else { return }
            window?.title = title
        }
    }
}
