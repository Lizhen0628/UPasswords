import SwiftUI

import UPasswordsCore
import UPasswordsPersistence

// MARK: - 设置 Tab

/// 设置根页:按域分组的导航菜单。原单页长表单拆分为各域子页面
/// (安全/云同步/密码库/备份/数据/外观/语言),根页只保留入口与当前值摘要,
/// 功能不变。
struct SettingsView: View {
    @EnvironmentObject var vault: Vault

    /// 设置域全部弹层的单一出口:同一视图链式多个 `.sheet` 的呈现会互相冲突
    /// (实测 iOS 27 上首个 sheet 永不呈现),统一由枚举驱动唯一 sheet;
    /// 子页面经 `@Binding` 共享该出口。
    enum ActiveSheet: Identifiable {
        case changePassword, autoFillGuide, export, importData, backups
        case manageVaults, createDatabase, importDatabase

        var id: Self { self }
    }

    @State private var activeSheet: ActiveSheet? = nil

    var body: some View {
        Form {
            accessGroup
            dataGroup
            generalGroup
            aboutSection
        }
        .navigationTitle(L10n.t("ios_tab_settings"))
        .onAppear {
            // UI 测试钩子(UPW_UITEST_MANAGE 环境变量):直接打开管理密码库弹层
            if ProcessInfo.processInfo.environment["UPW_UITEST_MANAGE"] == "1" {
                activeSheet = .manageVaults
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .changePassword: ChangePasswordSheet()
            case .autoFillGuide: AutoFillGuideView()
            case .export: ExportAsSheet()
            case .importData: ImportDataSheet()
            case .backups: BackupListSheet()
            case .manageVaults: VaultManageSheet()
            case .createDatabase: DatabaseCreateSheet()
            case .importDatabase: DatabaseImportSheet()
            }
        }
    }

    // MARK: 安全与同步

    private var accessGroup: some View {
        Section {
            SettingsLinkRow(icon: "lock.shield", title: L10n.t("ios_tab_security")) {
                SecuritySettingsView(activeSheet: $activeSheet)
            }
            SettingsLinkRow(icon: "icloud", title: L10n.t("cloud_sync_title"),
                            detail: vault.cloud.name) {
                SyncSettingsView()
            }
        } header: {
            Text(L10n.t("ios_settings_group_security"))
        }
    }

    // MARK: 数据管理

    private var dataGroup: some View {
        Section {
            SettingsLinkRow(icon: "externaldrive", title: L10n.t("ios_databases_section_title")) {
                VaultsSettingsView(activeSheet: $activeSheet)
            }
            SettingsLinkRow(icon: "externaldrive.badge.timemachine",
                            title: L10n.t("ios_backup_section_title")) {
                BackupSettingsView(activeSheet: $activeSheet)
            }
            SettingsLinkRow(icon: "arrow.up.arrow.down", title: L10n.t("ios_data_section")) {
                DataSettingsView(activeSheet: $activeSheet)
            }
        } header: {
            Text(L10n.t("ios_settings_group_data"))
        }
    }

    // MARK: 通用

    private var generalGroup: some View {
        Section {
            SettingsLinkRow(icon: "paintpalette", title: L10n.t("ios_appearance_section")) {
                AppearanceSettingsView()
            }
            // 生成器从底部 Tab 收进设置(低频工具,主生成场景在编辑卡片时内联完成)
            SettingsLinkRow(icon: "wand.and.stars", title: L10n.t("ios_tab_generator")) {
                GeneratorView()
            }
            SettingsLinkRow(icon: "globe", title: L10n.t("ios_language_section"),
                            detail: languageDetail) {
                LanguageSettingsView()
            }
            Button {
                activeSheet = .autoFillGuide
            } label: {
                Label {
                    Text(L10n.t("ios_autofill_section"))
                        .foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "safari")
                        .foregroundStyle(Brand.accent)
                }
            }
        } header: {
            Text(L10n.t("ios_settings_group_general"))
        }
    }

    /// 语言行的当前值摘要(语言名按各自语言展示,与语言设置页一致)。
    private var languageDetail: String {
        switch vault.language {
        case "en": return "English"
        case "zh-Hans": return "简体中文"
        default: return L10n.t("ios_language_system")
        }
    }

    // MARK: 关于

    private var aboutSection: some View {
        Section {
            HStack(spacing: 14) {
                // 品牌标识放入与应用一致的圆角方块底,避免裸 Canvas 悬浮于表单行
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LinearGradient(colors: [Brand.elev, Brand.card], startPoint: .top, endPoint: .bottom))
                        .frame(width: 44, height: 44)
                    BrandLogo(size: 30)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.t("ios_about_title"))
                        .font(.body.weight(.semibold))
                    Text(L10n.t("ios_about_subtitle"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text(L10n.t("about_title"))
        }
    }
}

// MARK: - 导航行

/// 设置根页导航行:品牌色图标 + 标题 + 可选当前值摘要(如当前云同步类型)。
private struct SettingsLinkRow<Destination: View>: View {
    let icon: String
    let title: String
    var detail: String? = nil
    @ViewBuilder let destination: Destination

    var body: some View {
        NavigationLink {
            destination
        } label: {
            Label {
                HStack {
                    Text(title)
                    if let detail {
                        Spacer()
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: icon)
                    .foregroundStyle(Brand.accent)
            }
        }
    }
}
