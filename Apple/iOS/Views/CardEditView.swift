import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

import UPasswordsCore

// MARK: - 模板选择(新建入口)

struct TemplatePickerView: View {
    @EnvironmentObject var vault: Vault
    @Environment(\.dismiss) private var dismiss
    let onSelect: (Card) -> Void

    var body: some View {
        NavigationStack {
            List {
                if !vault.customTemplates.isEmpty {
                    Section(L10n.t("ios_my_templates_section")) {
                        ForEach(vault.customTemplates) { t in
                            templateRow(title: t.title, symbol: t.symbol, color: t.color) {
                                var c = t
                                c.id = vault.nextId
                                c.template = false
                                c.created = Date().millis
                                c.modified = Date().millis
                                for i in c.fields.indices { c.fields[i].value = "" }
                                onSelect(c)
                            }
                        }
                    }
                }
                ForEach(TemplateGroups.groups, id: \.name) { group in
                    Section(group.name) {
                        ForEach(group.items) { item in
                            templateRow(title: item.title, symbol: item.symbol, color: item.color) {
                                onSelect(Templates.makeCard(from: item.spec, id: vault.nextId))
                            }
                        }
                    }
                }
            }
            .navigationTitle(L10n.t("ios_pick_template_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("cancel_button")) { dismiss() }
                }
            }
        }
    }

    private func templateRow(title: String, symbol: String?, color: String?, action: @escaping () -> Void) -> some View {
        let tint = Brand.tileColor(color)
        return Button(action: action) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tint.opacity(0.16))
                    .frame(width: 34, height: 34)
                    .overlay(
                        Image(systemName: symbol ?? "rectangle")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(tint)
                    )
                Text(title).foregroundStyle(.primary)
            }
        }
    }
}

// MARK: - 编辑 / 新建条目

struct CardEditView: View {
    @EnvironmentObject var vault: Vault
    @Environment(\.dismiss) private var dismiss

    let isNew: Bool
    @State var draft: Card
    @State private var revealed: Set<UUID> = []
    @State private var hasExpiration: Bool
    @State private var expirationDate: Date
    @State private var showValidation = false
    @State private var photoItem: PhotosPickerItem? = nil
    @State private var showFilePicker = false
    @State private var iconFetching = false
    @State private var showScanner = false
    @State private var scanTarget: UUID? = nil

    /// 单附件上限(XML 里 base64 序列化,过大显著膨胀)。
    private static let maxAttachmentBytes = 8 * 1024 * 1024

    init(draft: Card, isNew: Bool) {
        self.isNew = isNew
        _draft = State(initialValue: draft)
        _hasExpiration = State(initialValue: draft.expiration != nil)
        _expirationDate = State(initialValue: draft.expiration?.date ?? Date(timeIntervalSinceNow: 86400 * 365))
    }

    private var titleValid: Bool { !draft.title.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                titleSection
                iconSection
                fieldsSection
                expirationSection
                labelSection
                notesSection
                attachmentsSection
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(isNew ? L10n.t("ios_new_item_title") : L10n.t("ios_edit_item_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.t("cancel_button")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("ios_save_button")) { save() }.disabled(!titleValid)
                }
            }
            .alert(L10n.t("ios_title_required_error"), isPresented: $showValidation) {
                Button(L10n.t("ios_ok_button"), role: .cancel) {}
            }
        }
    }

    // MARK: 标题与图标

    private var titleSection: some View {
        Section {
            TextField(L10n.t("ios_title_prompt"), text: $draft.title)
                .font(.body.weight(.medium))
            symbolPicker
            colorPicker
        }
    }

    private static let symbolChoices = [
        "globe", "envelope", "key", "lock", "creditcard", "building.columns",
        "wifi", "network", "person.text.rectangle", "umbrella", "car",
        "heart.text.square", "key.horizontal", "timer.circle", "doc.plaintext", "gamecontroller",
        "bag", "cart", "airplane", "house", "briefcase", "graduationcap",
    ]

    private var symbolPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Self.symbolChoices, id: \.self) { sym in
                    let selected = draft.symbol == sym
                    Image(systemName: sym)
                        .font(.system(size: 16))
                        .foregroundStyle(selected ? Brand.tileColor(draft.color) : Brand.muted)
                        .frame(width: 40, height: 40)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(selected ? Brand.tileColor(draft.color).opacity(0.16) : Brand.fg.opacity(0.05))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(selected ? Brand.tileColor(draft.color) : .clear, lineWidth: 1.5)
                        )
                        .onTapGesture { draft.symbol = sym }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var colorPicker: some View {
        HStack(spacing: 14) {
            ForEach(["gray", "blue", "green", "yellow", "red", "purple", "teal"], id: \.self) { c in
                Circle()
                    .fill(Brand.tileColor(c))
                    .frame(width: 28, height: 28)
                    .overlay(Circle().strokeBorder(Brand.fg, lineWidth: draft.color == c ? 2 : 0).padding(-4))
                    .onTapGesture { draft.color = c }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: 网站图标(抓取归一化后随条目加密入库)

    @MainActor
    private var iconSection: some View {
        Section {
            if draft.iconData != nil, draft.iconSource == IconService.sourceWebsite {
                HStack(spacing: 12) {
                    CardIconView(card: draft, size: 44)
                    Text(L10n.t("ios_icon_in_use_text"))
                        .font(.subheadline)
                        .foregroundStyle(Brand.fg)
                    Spacer()
                    Button(L10n.t("ios_icon_remove_button")) {
                        draft.iconData = nil
                        draft.iconSource = nil
                        vault.showToast(L10n.t("ios_icon_cleared_message"))
                    }
                    .font(.subheadline)
                    .foregroundStyle(Brand.red)
                }
                .padding(.vertical, 2)
            } else {
                Button {
                    fetchIcon()
                } label: {
                    HStack {
                        Label(L10n.t("ios_icon_website_button"), systemImage: "globe.badge.arrow.clockwise")
                        if iconFetching {
                            Spacer()
                            ProgressView().tint(Brand.accent)
                        }
                    }
                }
                .disabled(iconFetching)
            }
        } header: {
            Text(L10n.t("ios_icon_section_title"))
        } footer: {
            Text(L10n.t("ios_icon_section_footer"))
        }
    }

    /// 按网址字段抓取站点图标;无有效网址给出可读错误。
    @MainActor
    private func fetchIcon() {
        guard let host = IconService.host(fromWebsite: draft.website) else {
            vault.showToast(L10n.t("icon_url_invalid"))
            return
        }
        iconFetching = true
        Task {
            defer { iconFetching = false }
            do {
                let data = try await IconService.fetchFavicon(host: host)
                draft.iconSource = IconService.sourceWebsite
                draft.iconData = data
                vault.showToast(L10n.t("ios_icon_updated_message"))
                Log.info("icons", "ios icon set for cardId=\(draft.id) host=\(host)")
            } catch {
                vault.showToast(error.localizedDescription)
            }
        }
    }

    // MARK: 字段

    private var fieldsSection: some View {
        Section {
            ForEach($draft.fields) { $field in
                draftFieldRow(field: $field)
            }
            Menu {
                ForEach(FieldType.allCases) { type in
                    Button {
                        draft.fields.append(Field(name: type.localizedName, type: type))
                    } label: {
                        Label(type.localizedName, systemImage: type.systemImage)
                    }
                }
            } label: {
                Label(L10n.t("ios_add_field_button"), systemImage: "plus.circle.fill")
                    .foregroundStyle(Brand.accent)
            }
        } header: {
            Text(L10n.t("ios_fields_section_title"))
        }
    }

    /// 字段行分发:通行密钥凭据字段只读展示,防止误编辑损坏凭据。
    @ViewBuilder
    private func draftFieldRow(field: Binding<Field>) -> some View {
        if let passkey = field.wrappedValue.passkeyPayload {
            PasskeyRowView(passkey: passkey)
        } else {
            fieldEditor(field: field)
        }
    }

    @ViewBuilder
    private func fieldEditor(field: Binding<Field>) -> some View {
        let fieldValue = field.wrappedValue
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: fieldValue.type.systemImage)
                    .font(.caption)
                    .foregroundStyle(Brand.accent)
                TextField(L10n.t("ios_field_name_prompt"), text: field.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Brand.muted)
                Spacer()
                if fieldValue.type == .password {
                    Button {
                        let s = PasswordSettings.shared
                        field.wrappedValue.value = PasswordGenerator.instance.password(length: s.passwordLength, type: s.passwordType)
                        revealed.insert(fieldValue.id)
                        vault.showToast(L10n.t("ios_password_generated_message"))
                    } label: {
                        Label(L10n.t("ios_generate_button"), systemImage: "wand.and.stars")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Brand.accent)
                    }
                }
                if fieldValue.type.isOneTimePassword {
                    Button {
                        scanTarget = fieldValue.id
                        showScanner = true
                    } label: {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.subheadline)
                            .foregroundStyle(Brand.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.t("ios_scan_button"))
                }
                Button(role: .destructive) {
                    draft.fields.removeAll { $0.id == fieldValue.id }
                } label: {
                    Image(systemName: "minus.circle")
                        .font(.subheadline)
                        .foregroundStyle(Brand.red)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.t("ios_delete_field_button"))
            }
            valueInput(field: field)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func valueInput(field: Binding<Field>) -> some View {
        let f = field.wrappedValue
        HStack(spacing: 8) {
            if f.type.isHidden {
                let shown = revealed.contains(f.id)
                Group {
                    if shown {
                        TextField(f.type.valuePlaceholder, text: field.value)
                    } else {
                        SecureField(f.type.valuePlaceholder, text: field.value)
                    }
                }
                .font(.body.monospaced())
                Button {
                    if shown { revealed.remove(f.id) } else { revealed.insert(f.id) }
                } label: {
                    Image(systemName: shown ? "eye.slash" : "eye")
                        .font(.subheadline)
                        .foregroundStyle(Brand.muted)
                }
                .buttonStyle(.plain)
            } else {
                TextField(f.type.valuePlaceholder, text: field.value)
                    .keyboardType(keyboard(for: f.type))
                    .textContentType(.none)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
        }
    }

    private func keyboard(for type: FieldType) -> UIKeyboardType {
        switch type {
        case .number: return .numbersAndPunctuation
        case .phone: return .phonePad
        case .email: return .emailAddress
        case .website: return .URL
        default: return .default
        }
    }

    // MARK: 过期 / 标签 / 备注

    private var expirationSection: some View {
        Section {
            Toggle(L10n.t("ios_set_expiration_toggle"), isOn: $hasExpiration)
            if hasExpiration {
                DatePicker(L10n.t("ios_expiry_date_prompt"), selection: $expirationDate, displayedComponents: .date)
            }
        } header: {
            Text(L10n.t("ios_expiration_section"))
        }
    }

    private var labelSection: some View {
        Section {
            FlowChips {
                ForEach(vault.labels) { label in
                    let on = draft.labelIds.contains(label.id)
                    Button {
                        if on { draft.labelIds.removeAll { $0 == label.id } }
                        else { draft.labelIds.append(label.id) }
                    } label: {
                        HStack(spacing: 6) {
                            Circle().fill(Brand.tileColor(label.color)).frame(width: 8, height: 8)
                            Text(label.name)
                            if on { Image(systemName: "checkmark").font(.caption2.weight(.bold)) }
                        }
                        .font(.subheadline)
                        .foregroundStyle(on ? Brand.fg : Brand.muted)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(
                            Capsule().fill(on ? Brand.tileColor(label.color).opacity(0.18) : Color(uiColor: .tertiarySystemFill))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text(L10n.t("ios_labels_section_title"))
        }
    }

    private var notesSection: some View {
        Section {
            TextEditor(text: $draft.notes)
                .frame(minHeight: 90)
        } header: {
            Text(L10n.t("ios_notes_section_title"))
        }
    }

    // MARK: 附件(图片 + 文件,随条目加密入库)

    private var attachmentsSection: some View {
        Section {
            ForEach(draft.images) { att in
                attachmentRow(att, icon: "photo")
            }
            ForEach(draft.files) { att in
                attachmentRow(att, icon: "paperclip")
            }
            PhotosPicker(selection: $photoItem, matching: .images) {
                Label(L10n.t("ios_add_photo_button"), systemImage: "photo")
            }
            Button { showFilePicker = true } label: {
                Label(L10n.t("ios_add_file_button"), systemImage: "paperclip")
            }
        } header: {
            Text(L10n.t("ios_attachments_section_title"))
        }
        .onChange(of: photoItem) { item in loadPhoto(item) }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                addFile(url)
            }
        }
        .fullScreenCover(isPresented: $showScanner) {
            QRScannerSheet { payload in
                applyScan(payload)
            }
        }
    }

    /// 扫码结果回填目标 OTP 字段(otpauth:// 或裸 base32 均原样入库)。
    @MainActor
    private func applyScan(_ payload: String) {
        guard let id = scanTarget,
              let idx = draft.fields.firstIndex(where: { $0.id == id }) else { return }
        draft.fields[idx].value = payload
        revealed.insert(id)
        vault.showToast(L10n.t("ios_qr_scanned_message"))
        Log.info("app", "ios otp scanned into fieldId=\(id)")
    }

    private func attachmentRow(_ att: Attachment, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(Brand.accent)
                .frame(width: 24)
            Text(att.name)
                .lineLimit(1)
            Spacer()
            Text(byteText(att.length))
                .font(.caption)
                .foregroundStyle(Brand.muted)
            Button(role: .destructive) {
                draft.images.removeAll { $0.id == att.id }
                draft.files.removeAll { $0.id == att.id }
            } label: {
                Image(systemName: "minus.circle")
                    .font(.subheadline)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.t("delete_button"))
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        photoItem = nil
        Task {
            guard let data = (try? await item.loadTransferable(type: Data.self)) ?? nil else {
                Log.warn("app", "ios photo attachment load failed")
                return
            }
            addAttachment(data: data, name: "Photo.jpg", isImage: true)
        }
    }

    private func addFile(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            vault.showToast(L10n.t("ios_import_unreadable_message"))
            return
        }
        addAttachment(data: data, name: url.lastPathComponent, isImage: false)
    }

    private func addAttachment(data: Data, name: String, isImage: Bool) {
        guard data.count <= Self.maxAttachmentBytes else {
            vault.showToast(String(format: L10n.t("ios_attachment_too_large_error"),
                                   Self.maxAttachmentBytes / 1024 / 1024))
            return
        }
        let att = Attachment(name: name, data: data)
        if isImage {
            draft.images.append(att)
        } else {
            draft.files.append(att)
        }
        vault.showToast(L10n.t("ios_attachment_added_message"))
    }

    private func byteText(_ n: Int) -> String {
        if n < 1024 { return "\(n) B" }
        return String(format: "%.1f KB", Double(n) / 1024)
    }

    // MARK: 保存

    private func save() {
        guard titleValid else { showValidation = true; return }
        draft.title = draft.title.trimmingCharacters(in: .whitespaces)
        draft.expiration = hasExpiration ? expirationDate.millis : nil
        if isNew {
            vault.addCard(draft)
            vault.showToast(String(format: L10n.t("ios_card_created_fmt"), draft.title))
        } else {
            vault.updateCard(draft)
            vault.showToast(L10n.t("ios_saved_message"))
        }
        dismiss()
    }
}
