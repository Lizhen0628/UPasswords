import SwiftUI

import UPasswordsCore

// MARK: - 条目详情

struct CardDetailView: View {
    @EnvironmentObject var vault: Vault
    let cardID: Int

    @State private var revealed: Set<UUID> = []
    @State private var showEdit = false
    @State private var showDeleteConfirm = false
    @State private var showPurgeConfirm = false
    @State private var expandedHistory: Set<UUID> = []
    @State private var attachmentSheet: AttachmentSheet? = nil
    @State private var qrPayload: String? = nil

    /// 附件交互:图片预览 / 文件经临时文件转系统分享。
    enum AttachmentSheet: Identifiable {
        case preview(Attachment)
        case share(URL)

        var id: String {
            switch self {
            case .preview(let att): return "preview-\(att.id.uuidString)"
            case .share(let url): return "share-\(url.lastPathComponent)"
            }
        }
    }

    private var card: Card? { vault.cards.first { $0.id == cardID } }

    var body: some View {
        Group {
            if let card {
                detailContent(card)
            } else {
                EmptyStateView(icon: "questionmark.folder", title: L10n.t("ios_card_missing_title"))
            }
        }
        .background(Brand.bg)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .sheet(isPresented: $showEdit) {
            if let card { CardEditView(draft: card, isNew: false) }
        }
        .confirmationDialog(L10n.t("ios_delete_card_query"), isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button(L10n.t("ios_move_to_trash_button"), role: .destructive) { if let c = card { vault.trash(c) }; pop() }
            Button(L10n.t("cancel_button"), role: .cancel) {}
        } message: { Text(L10n.t("ios_trash_recoverable_hint")) }
        .confirmationDialog(L10n.t("ios_purge_card_query"), isPresented: $showPurgeConfirm, titleVisibility: .visible) {
            Button(L10n.t("ios_purge_button"), role: .destructive) { if let c = card { vault.deletePermanently(c) }; pop() }
            Button(L10n.t("cancel_button"), role: .cancel) {}
        } message: { Text(L10n.t("ios_irreversible_warning")) }
        .sheet(item: $attachmentSheet) { sheet in
            switch sheet {
            case .preview(let att):
                AttachmentPreviewSheet(attachment: att)
            case .share(let url):
                ActivityView(items: [url])
            }
        }
        .sheet(isPresented: Binding(
            get: { qrPayload != nil },
            set: { if !$0 { qrPayload = nil } }
        )) {
            if let qrPayload {
                QRCodeSheet(title: card?.title ?? "", payload: qrPayload)
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    private func pop() { dismiss() }

    // MARK: 主体

    @ViewBuilder
    private func detailContent(_ card: Card) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header(card)
                securityBanners(card)
                fieldsSection(card)
                if card.hasNotes { notesSection(card) }
                if !card.files.isEmpty || !card.images.isEmpty { attachmentsSection(card) }
                labelsSection(card)
                metaSection(card)
                if card.trashed { trashedActions(card) }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 40)
        }
    }

    private func header(_ card: Card) -> some View {
        HStack(spacing: 14) {
            CardIconView(card: card, size: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(card.title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Brand.fg)
                if !card.website.isEmpty {
                    Text(card.website)
                        .font(.footnote)
                        .foregroundStyle(Brand.muted)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button { vault.toggleFavorite(card) } label: {
                Image(systemName: card.favorite ? "star.fill" : "star")
                    .font(.title3)
                    .foregroundStyle(card.favorite ? Brand.yellow : Brand.muted)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(card.favorite ? L10n.t("ios_unfavorite_button") : L10n.t("ios_cat_favorites"))
        }
        .padding(.top, 8)
    }

    // MARK: 安全横幅

    @ViewBuilder
    private func securityBanners(_ card: Card) -> some View {
        if card.compromised {
            banner(icon: "exclamationmark.shield.fill", tint: Brand.red,
                   title: L10n.t("ios_breach_banner_title"), detail: L10n.t("ios_breach_banner_detail"))
        }
        if card.hasWeakPasswords {
            banner(icon: "exclamationmark.triangle.fill", tint: Brand.yellow,
                   title: L10n.t("ios_weak_banner_title"), detail: L10n.t("ios_weak_banner_detail"))
        }
        if reused(card) {
            banner(icon: "repeat", tint: Brand.yellow,
                   title: L10n.t("ios_reused_banner_title"), detail: L10n.t("ios_reused_banner_detail"))
        }
        if card.isExpired {
            banner(icon: "calendar.badge.exclamationmark", tint: Brand.red,
                   title: L10n.t("ios_expired_banner_title"), detail: L10n.t("ios_expired_banner_detail"))
        } else if card.isExpiring {
            banner(icon: "hourglass", tint: Brand.yellow,
                   title: L10n.t("ios_cat_expiring"),
                   detail: String(format: L10n.t("ios_expiring_banner_detail_fmt"), card.expiringInDays))
        }
    }

    private func reused(_ card: Card) -> Bool {
        vault.reusedGroups.values.contains { $0.contains(card.id) }
    }

    private func banner(icon: String, tint: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Brand.fg)
                Text(detail).font(.footnote).foregroundStyle(Brand.muted)
            }
            Spacer()
        }
        .padding(12)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: 字段

    private func fieldsSection(_ card: Card) -> some View {
        BrandSection(title: L10n.t("ios_fields_section_title")) {
            // 通行密钥凭据字段不进入普通字段流,单独以摘要行展示
            let fields = card.fields.filter { $0.hasValue && !$0.isPasskeyPayload }
            if fields.isEmpty && card.passkey == nil {
                Text(L10n.t("ios_fields_empty"))
                    .font(.subheadline)
                    .foregroundStyle(Brand.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            } else {
                if let passkey = card.passkey {
                    PasskeyRowView(passkey: passkey)
                    if !fields.isEmpty { InsetDivider(leading: 54) }
                }
                ForEach(Array(fields.enumerated()), id: \.element.id) { i, field in
                    fieldRow(field, title: card.title)
                    if i < fields.count - 1 { InsetDivider(leading: 54) }
                }
            }
        }
    }

    @ViewBuilder
    private func fieldRow(_ field: Field, title: String) -> some View {
        let concealed = field.type.isHidden && vault.maskPasswords && !revealed.contains(field.id)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: field.type.systemImage)
                    .font(.body)
                    .foregroundStyle(Brand.accent)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(field.name)
                        .font(.caption)
                        .foregroundStyle(Brand.muted)
                    if field.type.isOneTimePassword {
                        otpValue(field)
                    } else {
                        Text(concealed ? "••••••••" : field.value)
                            .font(field.type.isHidden ? .body.monospaced() : .body)
                            .foregroundStyle(Brand.fg)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
                Spacer(minLength: 8)
                if field.type.isHidden && !field.type.isOneTimePassword {
                    iconButton(concealed ? "eye" : "eye.slash", concealed ? L10n.t("ios_show_button") : L10n.t("ios_hide_button")) {
                        if revealed.contains(field.id) { revealed.remove(field.id) } else { revealed.insert(field.id) }
                    }
                }
                if field.type.isOneTimePassword {
                    iconButton("qrcode", L10n.t("ios_qr_button")) {
                        qrPayload = QRCodeService.otpPayload(secret: field.value, title: title)
                    }
                }
                iconButton("doc.on.doc", L10n.t("copy_command")) {
                    if field.type.isOneTimePassword,
                       let cfg = try? TOTP.parse(field.value),
                       let code = try? TOTP.code(config: cfg) {
                        vault.copyToClipboard(code, label: L10n.t("ios_otp_copied_message"))
                    } else {
                        vault.copyToClipboard(field.value, label: String(format: L10n.t("ios_field_copied_fmt"), field.name))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if field.hasHistory {
                historyDisclosure(field)
            }
        }
    }

    /// TOTP 实时验证码 + 倒计时环。
    private func otpValue(_ field: Field) -> some View {
        if let cfg = try? TOTP.parse(field.value) {
            return AnyView(
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let code = (try? TOTP.code(config: cfg, at: ctx.date)) ?? "——————"
                    let remain = TOTP.remainingSeconds(period: cfg.period, at: ctx.date)
                    HStack(spacing: 10) {
                        Text(grouped(code))
                            .font(.title3.monospaced().weight(.semibold))
                            .foregroundStyle(Brand.green)
                        ZStack {
                            Circle().stroke(Brand.fg.opacity(0.12), lineWidth: 2.5)
                            Circle()
                                .trim(from: 0, to: CGFloat(remain) / CGFloat(cfg.period))
                                .stroke(Brand.green, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            Text("\(remain)")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundStyle(Brand.muted)
                        }
                        .frame(width: 22, height: 22)
                    }
                }
            )
        }
        return AnyView(
            Text(L10n.t("ios_invalid_otp_text"))
                .font(.footnote)
                .foregroundStyle(Brand.red)
        )
    }

    private func grouped(_ code: String) -> String {
        guard code.count == 6 else { return code }
        let i = code.index(code.startIndex, offsetBy: 3)
        return code[..<i] + " " + code[i...]
    }

    private func iconButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(Brand.muted)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: 密码历史

    private func historyDisclosure(_ field: Field) -> some View {
        let open = expandedHistory.contains(field.id)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if open { expandedHistory.remove(field.id) } else { expandedHistory.insert(field.id) }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.caption)
                    Text(String(format: L10n.t("ios_history_count_fmt"), field.history.count))
                        .font(.caption.weight(.medium))
                    Image(systemName: open ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.bold))
                }
                .foregroundStyle(Brand.accent)
                .padding(.horizontal, 54)
                .padding(.bottom, 8)
            }
            .buttonStyle(.plain)

            if open {
                ForEach(field.history.sorted(by: { $0.time > $1.time })) { entry in
                    HStack(spacing: 10) {
                        Text(entry.value)
                            .font(.footnote.monospaced())
                            .foregroundStyle(Brand.muted)
                            .lineLimit(1)
                        Spacer()
                        Text(entry.time.date.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption2)
                            .foregroundStyle(Brand.fg.opacity(0.35))
                        Button(L10n.t("copy_command")) { vault.copyToClipboard(entry.value) }
                            .font(.caption)
                        Button(L10n.t("ios_restore_button")) { restoreHistory(field: field, entry: entry) }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Brand.accent)
                    }
                    .padding(.horizontal, 54)
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private func restoreHistory(field: Field, entry: HistoryEntry) {
        guard var card = vault.cards.first(where: { $0.fields.contains(where: { $0.id == field.id }) }) else { return }
        guard let idx = card.fields.firstIndex(where: { $0.id == field.id }) else { return }
        card.fields[idx].value = entry.value
        vault.updateCard(card)
        vault.showToast(L10n.t("ios_history_restored_message"))
    }

    // MARK: 备注 / 附件 / 标签 / 元信息

    private func notesSection(_ card: Card) -> some View {
        BrandSection(title: L10n.t("ios_notes_section_title")) {
            Text(card.notes)
                .font(.subheadline)
                .foregroundStyle(Brand.fg.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
    }

    private func attachmentsSection(_ card: Card) -> some View {
        BrandSection(title: L10n.t("ios_attachments_section_title")) {
            let all = card.images + card.files
            ForEach(Array(all.enumerated()), id: \.element.id) { i, att in
                Button { openAttachment(att) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "paperclip")
                            .foregroundStyle(Brand.accent)
                            .frame(width: 26)
                        Text(att.name)
                            .font(.subheadline)
                            .foregroundStyle(Brand.fg)
                            .lineLimit(1)
                        Spacer()
                        Text(byteText(att.length))
                            .font(.caption)
                            .foregroundStyle(Brand.muted)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Brand.fg.opacity(0.25))
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 42)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(att.name)
                if i < all.count - 1 { InsetDivider(leading: 54) }
            }
        }
    }

    /// 图片直接预览;其余附件写临时文件交系统分享。
    private func openAttachment(_ att: Attachment) {
        if UIImage(data: att.data) != nil {
            attachmentSheet = .preview(att)
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(att.name)
        do {
            try att.data.write(to: url, options: .atomic)
            attachmentSheet = .share(url)
        } catch {
            Log.error("app", "ios attachment share write \"\(att.name)\" failed: \(error)")
            vault.showToast(L10n.t("ios_import_unreadable_message"))
        }
    }

    private func byteText(_ n: Int) -> String {
        if n < 1024 { return "\(n) B" }
        return String(format: "%.1f KB", Double(n) / 1024)
    }

    @ViewBuilder
    private func labelsSection(_ card: Card) -> some View {
        let labels = vault.labelsOf(card)
        if !labels.isEmpty {
            BrandSection(title: L10n.t("ios_labels_section_title")) {
                FlowChips {
                    ForEach(labels) { label in
                        HStack(spacing: 6) {
                            Circle().fill(Brand.tileColor(label.color)).frame(width: 8, height: 8)
                            Text(label.name)
                        }
                        .font(.subheadline)
                        .foregroundStyle(Brand.fg)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(Brand.fg.opacity(0.07), in: Capsule())
                    }
                }
                .padding(16)
            }
        }
    }

    private func metaSection(_ card: Card) -> some View {
        BrandSection(title: L10n.t("ios_meta_section_title")) {
            metaRow(L10n.t("ios_meta_created"), card.created.date.formatted(date: .abbreviated, time: .shortened))
            InsetDivider()
            metaRow(L10n.t("ios_meta_modified"), card.modified.date.formatted(date: .abbreviated, time: .shortened))
            InsetDivider()
            metaRow(L10n.t("ios_meta_size"), byteText(card.size))
        }
    }

    private func metaRow(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).foregroundStyle(Brand.muted)
            Spacer()
            Text(v).foregroundStyle(Brand.fg)
        }
        .font(.subheadline)
        .padding(.horizontal, 16)
        .frame(height: 40)
    }

    // MARK: 已删除条目操作

    private func trashedActions(_ card: Card) -> some View {
        VStack(spacing: 10) {
            Button { vault.restore(card); pop() } label: {
                Text(L10n.t("ios_restore_item_button"))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Brand.accent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(Brand.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            Button(role: .destructive) { showPurgeConfirm = true } label: {
                Text(L10n.t("ios_purge_button"))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Brand.red)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(Brand.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    // MARK: 工具栏

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if let card, !card.trashed {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    Menu {
                        ShareLink(item: card.asPlainText()) {
                            Label(L10n.t("ios_share_as_text_button"), systemImage: "square.and.arrow.up")
                        }
                        Button { vault.duplicate(card) } label: { Label(L10n.t("ios_duplicate_button"), systemImage: "plus.square.on.square") }
                        Button { vault.saveAsTemplate(card) } label: { Label(L10n.t("ios_save_as_template_button"), systemImage: "doc.badge.plus") }
                        Button { vault.setArchived(card, !card.archived) } label: {
                            Label(card.archived ? L10n.t("ios_unarchive_button") : L10n.t("archive_command"), systemImage: "archivebox")
                        }
                        Divider()
                        Button(role: .destructive) { showDeleteConfirm = true } label: { Label(L10n.t("delete_button"), systemImage: "trash") }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.title3)
                    }
                    Button(L10n.t("edit_button")) { showEdit = true }
                        .font(.body.weight(.semibold))
                }
            }
        }
    }
}

// MARK: - 通行密钥摘要行

/// 详情/编辑页共用:替代机读 JSON 凭据字段的原始展示。
struct PasskeyRowView: View {
    let passkey: Passkey

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.badge.key.fill")
                .font(.body)
                .foregroundStyle(Brand.accent)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t("ios_passkey_field_name"))
                    .font(.caption)
                    .foregroundStyle(Brand.muted)
                Text("\(passkey.relyingParty) · \(passkey.userName)")
                    .font(.body)
                    .foregroundStyle(Brand.fg)
                    .lineLimit(2)
                Text(String(format: L10n.t("ios_db_created_fmt"),
                            Date(timeIntervalSince1970: passkey.created / 1000)
                                .formatted(date: .abbreviated, time: .omitted)))
                    .font(.caption2)
                    .foregroundStyle(Brand.muted)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - 附件图片预览

struct AttachmentPreviewSheet: View {
    let attachment: Attachment
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                if let image = UIImage(data: attachment.data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(8)
                } else {
                    EmptyStateView(icon: "photo", title: attachment.name)
                }
            }
            .background(Brand.bg)
            .navigationTitle(attachment.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("ios_done_button")) { dismiss() }
                }
            }
        }
    }
}
