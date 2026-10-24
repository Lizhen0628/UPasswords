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

/// 设置窗口侧边页签按钮，选择状态由外层容器持有。
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

/// 为弹出选择器提供 AppKit 样式适配的背景视图。
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

/// 编辑应用外观和密码展示偏好，不修改密码库内容。
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

/// 安全偏好面板，协调生物识别、锁定策略与主密码修改入口。
struct SecurityPane: View {
    @EnvironmentObject var ctx: AppContext
    @EnvironmentObject var settings: AppSettings

    private let lockChoices: [(String, Int)] = [
        (L10n.t("never_text"), 0), ("1" + L10n.t("minutes_abbr_text"), 60), ("5" + L10n.t("minutes_abbr_text"), 300), ("15" + L10n.t("minutes_abbr_text"), 900), ("1" + L10n.t("hours_text"), 3600),
    ]
    private let requireChoices: [(String, Int)] = [
        (L10n.t("never_text"), 0), ("8" + L10n.t("hours_text"), 28800), ("1" + L10n.t("days_text"), 86400), ("7" + L10n.t("days_text"), 604800),
    ]
    private let clipboardChoices: [(String, Int)] = [
        (L10n.t("off_text"), 0), ("10" + L10n.t("seconds_abbr_text"), 10), ("30" + L10n.t("seconds_abbr_text"), 30), ("1" + L10n.t("minutes_abbr_text"), 60), ("2" + L10n.t("minutes_abbr_text"), 120),
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
                             : L10n.t("not_recommended_text") + ": " + L10n.t("touch_id_unavailable_hint"))
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

/// 管理自动备份周期、备份清单与日志维护入口。
struct AutoBackupPane: View {
    @EnvironmentObject var ctx: AppContext
    @EnvironmentObject var settings: AppSettings

    private let intervalChoices: [(String, Int)] = [
        ("1" + L10n.t("days_text"), 1), ("3" + L10n.t("days_text"), 3), ("7" + L10n.t("days_text"), 7), ("30" + L10n.t("days_text"), 30),
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
            Log.info("backup", "restored from \(url.lastPathComponent)")
            AppToast.shared.show(L10n.t("database_restored_message"))
        } catch {
            Log.error("backup", "restore from \(url.lastPathComponent) failed: \(error)")
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

/// 展示浏览器扩展与自动填充相关配置。
struct AutofillPane: View {
    @EnvironmentObject private var ctx: AppContext
    @EnvironmentObject private var settings: AppSettings
    @State private var personalInfoPresented = false

    var body: some View {
        PaneContainer {
            VStack(alignment: .leading, spacing: 16) {
                Toggle(L10n.t("registration_autofill_setting"), isOn: Binding(
                    get: {
                        ctx.database.userProfiles.first?.registrationAutofillEnabled
                            ?? settings.registrationAutofillEnabled
                    },
                    set: ctx.setRegistrationAutofillEnabled
                ))
                Button(L10n.t("personal_info_title")) {
                    Log.info("ui", "personal information editor opened")
                    personalInfoPresented = true
                }
                Text(L10n.t("registration_autofill_setting_hint"))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
        .sheet(isPresented: $personalInfoPresented) { PersonalInfoSheet() }
    }

}

// MARK: - Lock screen

/// 编辑锁屏背景和纹理选择，图片持久化交由专用存储服务。
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

/// 云同步设置入口，组合账户授权、库绑定与同步状态。
struct CloudPane: View {
    var body: some View {
        ConfigureCloudSheetContents()
    }
}

/// Body of ConfigureCloudSheet reusable in the preferences pane.
struct ConfigureCloudSheetContents: View {
    @EnvironmentObject var ctx: AppContext
    @EnvironmentObject var settings: AppSettings
    @State private var relayEmail = ""
    @State private var relayCode = ""
    @State private var relayBusy = false
    @State private var relayDevices: [RelayClient.DeviceSession] = []
    @StateObject private var resend = ResendCountdown()
    @State private var showRelayDevices = false
    @State private var relayCodePrompt: RelayCodePrompt? = nil
    @State private var relayCodeInput = ""
    @State private var showRelayTransfer = false

    /// 需要敏感验证码确认的操作(解绑库 / 注销账户)。
    enum RelayCodePrompt {
        case unbind, deregister
    }

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
                // 同步通道为账户中继(注册表信封 + 服务端库体副本):
                // 自动同步开关/间隔与账户登录/设备管理都在本面板
                Grid(alignment: .leading, horizontalSpacing: settingsRowSpacing, verticalSpacing: 14) {
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
                    GridRow {
                        Text(L10n.t("relay_account_label"))
                        relayAccountControl
                    }
                }
                Text(L10n.t("relay_account_footer"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // 远端密文解不开(对端改过主密码/数据损坏)时的修复入口:
                // 统一收进一个对话框(接管/覆盖两条路都在里面),避免与弹窗重复
                if ctx.syncRemoteUnreadable {
                    HStack(spacing: 10) {
                        Label(L10n.t("sync_remote_unreadable_error"), systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.red)
                        Button(L10n.t("sync_repair_button")) {
                            Log.info("ui", "sync repair dialog from preferences")
                            ctx.promptAdoptRemotePassword()
                        }
                    }
                }
            }
            .sheet(isPresented: $showRelayTransfer) {
                RelayTransferSheet()
            }
            .alert(L10n.t("relay_sensitive_code_title"), isPresented: Binding(
                get: { relayCodePrompt != nil },
                set: { if !$0 { relayCodePrompt = nil } }
            )) {
                TextField(L10n.t("relay_code_placeholder"), text: $relayCodeInput)
                Button(L10n.t("ok_button")) {
                    let code = relayCodeInput
                    let prompt = relayCodePrompt
                    relayCodeInput = ""
                    relayCodePrompt = nil
                    guard let prompt else { return }
                    Task {
                        if prompt == .unbind {
                            await ctx.relayUnbindVault(code: code)
                        } else {
                            await ctx.relayDeregisterAccount(code: code)
                        }
                    }
                }
                Button(L10n.t("cancel_button"), role: .cancel) {
                    relayCodePrompt = nil
                }
            } message: {
                Text(relayCodePrompt == .deregister
                     ? L10n.t("relay_deregister_message") : L10n.t("relay_sensitive_code_sent"))
            }
            .frame(width: cloudPaneWidth, alignment: .leading)
        }
    }


    /// UPasswords 云同步账户:未登录=邮箱+验证码登录(登录即为当前库启用);
    /// 已登录=账户邮箱 + 登出/设备管理/解绑/注销。登录需库处于解锁态(要上传本地信封)。
    /// 管理设备行的平台图标(与会话表 platform 列对齐)。
    private static func relayDeviceIcon(for platform: String) -> String {
        switch platform {
        case "ios", "autofill": return "iphone"
        case "macos": return "macbook"
        case "ext-safari", "ext-chrome", "ext-edge", "ext-firefox": return "puzzlepiece.extension"
        default: return "desktopcomputer.and.iphone"
        }
    }

    @ViewBuilder
    private var relayAccountControl: some View {
        if let email = ctx.relayAccountEmail, ctx.relayBound {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(email)
                    Button(L10n.t("relay_logout_button")) {
                        Log.info("ui", "relay logout from preferences")
                        Task { await ctx.relayLogout() }
                    }
                }
                Text(L10n.t("relay_enabled_label"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button(L10n.t("relay_devices_button")) {
                        Log.info("ui", "relay devices toggle from preferences")
                        Task {
                            relayDevices = await ctx.relaySessions()
                            showRelayDevices.toggle()
                        }
                    }
                    Button(L10n.t("relay_transfer_button")) {
                        Log.info("ui", "relay transfer sheet from preferences")
                        showRelayTransfer = true
                    }
                    Button(L10n.t("relay_unbind_button")) {
                        Log.info("ui", "relay unbind prompt from preferences")
                        Task {
                            await ctx.relayRequestSensitiveCode()
                            relayCodeInput = ""
                            relayCodePrompt = .unbind
                        }
                    }
                    Button(L10n.t("relay_deregister_button"), role: .destructive) {
                        Log.info("ui", "relay deregister prompt from preferences")
                        Task {
                            await ctx.relayRequestSensitiveCode()
                            relayCodeInput = ""
                            relayCodePrompt = .deregister
                        }
                    }
                }
                if showRelayDevices {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(relayDevices) { device in
                            HStack(spacing: 8) {
                                Image(systemName: Self.relayDeviceIcon(for: device.platform))
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 6) {
                                        Text(device.deviceName.isEmpty
                                             ? String(device.id.prefix(8)) + "…" : device.deviceName)
                                        if device.isCurrent {
                                            Text(L10n.t("relay_device_current_badge"))
                                                .font(.system(size: 9, weight: .medium))
                                                .foregroundStyle(.tint)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 0.5)
                                                .background(Color.accentColor.opacity(0.16), in: Capsule())
                                        }
                                    }
                                    if let seen = device.lastSeenAt {
                                        Text(String(
                                            format: L10n.t("relay_device_last_active_fmt"),
                                            DateFormatter.localizedString(from: seen, dateStyle: .short, timeStyle: .short)))
                                            .font(.system(size: 9))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                // 本机会话不提供「撤销」——登出按钮就是它的撤销
                                if !device.isCurrent {
                                    Button(L10n.t("relay_revoke_button")) {
                                        Log.info("ui", "relay session revoke from preferences")
                                        Task {
                                            await ctx.relayRevokeSession(id: device.id)
                                            relayDevices = await ctx.relaySessions()
                                        }
                                    }
                                    .controlSize(.small)
                                }
                            }
                            .font(.caption)
                        }
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TextField(L10n.t("relay_email_placeholder"), text: $relayEmail)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                    Button(resend.buttonTitle(L10n.t("relay_send_code_button"))) {
                        let email = relayEmail.trimmingCharacters(in: .whitespaces)
                        guard email.contains("@"), email.contains(".") else {
                            AppToast.shared.show(L10n.t("invalid_email_error"))
                            return
                        }
                        relayBusy = true
                        Log.info("ui", "relay code request from preferences")
                        Task {
                            resend.start(await ctx.relaySendCode(email: email))
                            relayBusy = false
                        }
                    }
                    .disabled(resend.isRunning)
                    if relayBusy { ProgressView().controlSize(.small) }
                }
                HStack(spacing: 8) {
                    SecureField(L10n.t("relay_code_placeholder"), text: $relayCode)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                    Button(L10n.t("relay_login_button")) {
                        relayBusy = true
                        Log.info("ui", "relay login from preferences")
                        let email = relayEmail.trimmingCharacters(in: .whitespaces)
                        let code = relayCode
                        relayCode = ""
                        Task {
                            await ctx.relayLoginAndEnable(email: email, code: code)
                            relayBusy = false
                        }
                    }
                    .disabled(relayEmail.isEmpty || relayCode.count < RelayClient.verificationCodeLength || ctx.phase != .unlocked)
                }
            }
        }
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

/// 换绑邮箱表单:当前主密码(本地验证) + 新邮箱(收敏感码) + 验证码 →
/// 注册表记录迁移到新邮箱名下,云端同步结构随之换主。
private struct RelayTransferSheet: View {
    @EnvironmentObject var ctx: AppContext
    @Environment(\.dismiss) var dismiss

    @State private var masterPassword = ""
    @State private var currentCode = ""
    @State private var currentSending = false
    @State private var newEmail = ""
    @State private var code = ""
    @State private var busy = false
    @State private var sending = false

    var body: some View {
        SheetShell(
            title: L10n.t("relay_transfer_title"),
            okTitle: L10n.t("relay_transfer_button"),
            okDisabled: masterPassword.isEmpty || !newEmail.contains("@") || code.count < RelayClient.verificationCodeLength
                || currentCode.count < RelayClient.verificationCodeLength || busy,
            onCancel: { dismiss() },
            onOk: {
                busy = true
                let pw = masterPassword
                masterPassword = ""
                let email = newEmail.trimmingCharacters(in: .whitespaces)
                let entered = code
                code = ""
                let currentEntered = currentCode
                currentCode = ""
                Task {
                    if await ctx.relayTransferVault(masterPassword: pw, newEmail: email, code: entered,
                                                    currentCode: currentEntered) {
                        dismiss()
                    }
                    busy = false
                }
            },
            content: {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.t("relay_transfer_hint"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    LabeledRow(label: L10n.t("relay_transfer_master_password")) {
                        SecureField("", text: $masterPassword)
                            .textFieldStyle(.roundedBorder)
                    }
                    // 服务端门槛一:当前账户的 sensitive 码(令牌被盗不足以过户库)
                    LabeledRow(label: L10n.t("relay_transfer_current_code")) {
                        HStack(spacing: 8) {
                            SecureField("", text: $currentCode)
                                .textFieldStyle(.roundedBorder)
                            Button(L10n.t("relay_send_code_button")) {
                                Log.info("ui", "relay transfer current-email code request")
                                currentSending = true
                                Task {
                                    await ctx.relaySendSensitiveCode(to: ctx.relayAccountEmail ?? "")
                                    currentSending = false
                                }
                            }
                            .disabled(ctx.relayAccountEmail == nil || currentSending)
                            if currentSending { ProgressView().controlSize(.small) }
                        }
                    }
                    LabeledRow(label: L10n.t("relay_transfer_new_email")) {
                        TextField("", text: $newEmail)
                            .textFieldStyle(.roundedBorder)
                    }
                    HStack(spacing: 8) {
                        SecureField(L10n.t("relay_code_placeholder"), text: $code)
                            .textFieldStyle(.roundedBorder)
                        Button(L10n.t("relay_send_code_button")) {
                            Log.info("ui", "relay transfer code request")
                            sending = true
                            let email = newEmail.trimmingCharacters(in: .whitespaces)
                            Task {
                                await ctx.relaySendSensitiveCode(to: email)
                                sending = false
                            }
                        }
                        .disabled(!newEmail.contains("@") || sending)
                        if sending { ProgressView().controlSize(.small) }
                    }
                }
                .frame(maxWidth: 380)
            }
        )
    }
}
