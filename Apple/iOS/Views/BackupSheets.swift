import SwiftUI

import UPasswordsCore
import UPasswordsPersistence

// MARK: - 备份管理弹层:当前库的备份清单(原生 List 右滑 恢复 / 删除)
//
// 行操作用原生 swipeActions(手势由系统 List 滚动栈仲裁,自绘手势层在
// 真机上不可靠)。行内容必须是「非 Button」的裸视图:实测 Button 行的
// 点按手势会吞掉 leading 边滑动手势,右滑完全无响应;点按改由
// contentShape + onTapGesture 承担(点按与水平滑动不竞争),行内不得
// 再叠加其他自定义手势修饰符。
// 真机 iOS 27.0.1 上原生 swipeActions 仍不响应(iOS 27.0 模拟器同代码
// UI 测试通过,判定为个别真机环境的手势仲裁问题),故行尾加 Menu 作为
// 不依赖手势的可靠入口,swipeActions 保留。

struct BackupListSheet: View {
    @EnvironmentObject var vault: Vault
    @Environment(\.dismiss) private var dismiss

    @State private var backups: [URL] = []
    @State private var restoreTarget: URL? = nil

    var body: some View {
        NavigationStack {
            List {
                if backups.isEmpty {
                    Text(L10n.t("ios_backup_empty"))
                        .font(.subheadline)
                        .foregroundStyle(Brand.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .listRowBackground(Brand.card)
                        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                } else {
                    ForEach(backups, id: \.self) { url in
                        backupSwipeRow(url)
                    }
                }
                Section {
                    Text(L10n.t("ios_backup_list_footer"))
                        .font(.footnote)
                        .foregroundStyle(Brand.muted)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 0, trailing: 16))
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Brand.bg)
            .navigationTitle(L10n.t("backup_command"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("close_button")) { dismiss() }
                }
            }
            .onAppear { reload() }
            .confirmationDialog(L10n.t("ios_backup_restore_query"), isPresented: Binding(
                get: { restoreTarget != nil },
                set: { if !$0 { restoreTarget = nil } }
            ), titleVisibility: .visible, presenting: restoreTarget) { url in
                Button(L10n.t("restore_command")) {
                    vault.restoreBackup(url)
                    dismiss()
                }
                Button(L10n.t("cancel_button"), role: .cancel) {}
            } message: { _ in
                Text(L10n.t("ios_backup_restore_detail"))
            }
        }
        .presentationDetents([.medium])
    }

    /// 备份行:右滑(leading)揭示 恢复/删除,点按弹恢复确认。
    /// 行内容不得是 Button(会吞掉滑动手势),点按走 onTapGesture。
    private func backupSwipeRow(_ url: URL) -> some View {
        backupRow(url)
            .contentShape(Rectangle())
            .onTapGesture {
                restoreTarget = url
            }
            .listRowBackground(Brand.card)
        .listRowInsets(EdgeInsets(top: 11, leading: 16, bottom: 11, trailing: 16))
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                restoreTarget = url
            } label: {
                Label(L10n.t("restore_command"), systemImage: "clock.arrow.circlepath")
            }
            .tint(Brand.accent)

            Button(role: .destructive) {
                vault.deleteBackup(url)
                reload()
            } label: {
                Label(L10n.t("delete_button"), systemImage: "trash")
            }
            .tint(Brand.red)
        }
    }

    private func backupRow(_ url: URL) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.timemachine")
                .foregroundStyle(Brand.accent)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(backupTitle(url))
                    .font(.subheadline)
                    .foregroundStyle(Brand.fg)
                Text(byteText((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0))
                    .font(.caption)
                    .foregroundStyle(Brand.muted)
            }
            Spacer()
            // 不依赖手势的可靠入口:个别真机(iOS 27.0.1)swipeActions 不响应
            Menu {
                Button {
                    restoreTarget = url
                } label: {
                    Label(L10n.t("restore_command"), systemImage: "clock.arrow.circlepath")
                }
                Button(role: .destructive) {
                    vault.deleteBackup(url)
                    reload()
                } label: {
                    Label(L10n.t("delete_button"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.body)
                    .foregroundStyle(Brand.muted)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(L10n.t("actions_button"))
        }
    }

    /// 快照文件名为 yyyyMMdd-HHmmss,还原成可读时间展示。
    private func backupTitle(_ url: URL) -> String {
        let stamp = url.deletingPathExtension().lastPathComponent
        var parsed = Date()
        if let date = DatabaseStore.backupStampFormatter.date(from: stamp) {
            parsed = date
        }
        return parsed.formatted(date: .abbreviated, time: .shortened)
    }

    private func reload() {
        backups = vault.backups()
    }

    private func byteText(_ n: Int) -> String {
        if n < 1024 { return "\(n) B" }
        return String(format: "%.1f KB", Double(n) / 1024)
    }
}
