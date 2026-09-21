import SwiftUI

/// ViewCardViewController — detail pane styled after the original: title block
/// with a large circular icon (star badge at its bottom-left corner), form-style
/// field rows (caption label above, value over a hairline underline, type icon
/// at the right end), and a bottom action bar (编辑 / 设置标签 / 用于自动填充 /
/// share).
struct CardDetailView: View {
    @EnvironmentObject var ctx: AppContext
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        if let card = currentCard {
            detail(card)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "rectangle.and.text.magnifyingglass")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text(L10n.t("cards_subtitle_prompt"))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var currentCard: Card? {
        guard let id = ctx.selectedCardId else { return nil }
        return ctx.database.card(id: id)
    }

    private func detail(_ card: Card) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(card)
                if !card.fields.isEmpty { fieldsSection(card) }
                if card.hasNotes { notesSection(card) }
                if card.hasImages { imagesSection(card) }
                if card.hasFiles { filesSection(card) }
                footer(card)
                if card.trashed || card.archived {
                    trashActions(card)
                }
            }
            .padding(24)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .safeAreaInset(edge: .bottom) {
            bottomBar(card)
        }
    }

    // MARK: Header — big circular icon top-right with a star badge

    private func header(_ card: Card) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(card.title.isEmpty ? "—" : card.title)
                    .font(.system(size: 22, weight: .bold))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    ForEach(card.labelIds, id: \.self) { lid in
                        if let l = ctx.database.label(id: lid) {
                            Text(l.name)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(CardColor.color(named: l.color).opacity(0.18), in: Capsule())
                                .foregroundStyle(CardColor.color(named: l.color))
                        }
                    }
                    Button(L10n.t("set_labels_button")) { ctx.activeSheet = .labels(cardId: card.id) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                warnings(card)
            }
            Spacer(minLength: 12)
            ZStack(alignment: .bottomLeading) {
                CardIconView(symbol: card.symbol, color: card.color, size: 70,
                             creditCardNumber: card.fields.first { $0.type == .number }?.value)
                Button {
                    ctx.toggleFavorite(card.id)
                } label: {
                    Image(systemName: card.favorite ? "star.fill" : "star")
                        .font(.system(size: 13))
                        .foregroundStyle(card.favorite ? .yellow : .secondary)
                        .padding(4)
                        .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                        .offset(x: -10, y: 10)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 10)
        }
    }

    @ViewBuilder
    private func warnings(_ card: Card) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if card.isExpired {
                Label(L10n.t("card_expired_warning"), systemImage: "clock.badge.exclamationmark")
                    .foregroundStyle(.red).font(.caption)
            } else if card.isExpiring {
                Label("\(L10n.t("card_expiring_warning")) \(card.expiringInDays)", systemImage: "hourglass")
                    .foregroundStyle(.orange).font(.caption)
            }
            if card.hasWeakPasswords {
                Label(L10n.t("weak_password_message"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).font(.caption)
            }
            if card.compromised {
                Label(L10n.t("compromised_password_message"), systemImage: "exclamationmark.shield.fill")
                    .foregroundStyle(.red).font(.caption)
            }
        }
    }

    // MARK: Fields — form rows: caption label, value, hairline underline, type icon

    private func fieldsSection(_ card: Card) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(card.fields) { field in
                FieldRowView(card: card, field: field)
            }
            if !card.isTemplate {
                Menu {
                    ForEach(Templates.all) { spec in
                        Button(L10n.db(spec.titleKey)) {
                            addMissingFields(from: spec, to: card)
                        }
                    }
                } label: {
                    Label(L10n.t("add_field_button"), systemImage: "plus.circle")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    @MainActor private func addMissingFields(from spec: Templates.Spec, to card: Card) {
        guard let i = ctx.database.cards.firstIndex(where: { $0.id == card.id }) else { return }
        var c = ctx.database.cards[i]
        for f in spec.fields {
            let name = L10n.db(f.nameKey)
            if !c.fields.contains(where: { $0.name == name }) {
                c.fields.append(Field(name: name, type: f.type, value: "", autofill: f.autofill))
            }
        }
        c.modified = Date().millis
        ctx.database.cards[i] = c
        ctx.saveDebounced()
    }

    // MARK: Notes / images / files / footer

    private func notesSection(_ card: Card) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(L10n.t("notes_tab"))
            Text(card.notes)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func imagesSection(_ card: Card) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(L10n.db("images_label"))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(card.images) { img in
                        if let ns = NSImage(data: img.data) {
                            Image(nsImage: ns)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 96, height: 96)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .contextMenu {
                                    Button(L10n.t("copy_command")) {
                                        ClipboardModel.shared.copy(img.data.base64EncodedString())
                                    }
                                }
                        }
                    }
                }
            }
        }
    }

    private func filesSection(_ card: Card) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(L10n.db("files_label"))
            ForEach(card.files) { file in
                HStack {
                    Image(systemName: "doc")
                    Text(file.name)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(file.length), countStyle: .file))
                        .foregroundStyle(.secondary).font(.caption)
                    Button(L10n.t("save_button")) { saveAttachment(file) }
                        .buttonStyle(.link)
                }
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    @MainActor private func saveAttachment(_ file: Attachment) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.name
        if panel.runModal() == .OK, let url = panel.url {
            try? file.data.write(to: url)
            AppToast.shared.show(L10n.t("file_saved_message") + " " + url.lastPathComponent)
        }
    }

    private func footer(_ card: Card) -> some View {
        HStack(spacing: 18) {
            Label(shortDate(card.created), systemImage: "calendar.badge.plus")
            Label(shortDate(card.modified), systemImage: "pencil")
            Label(ByteCountFormatter.string(fromByteCount: Int64(card.size), countStyle: .file), systemImage: "externaldrive")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func shortDate(_ millis: TimeInterval) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: millis.date)
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s).font(.caption.bold()).foregroundStyle(.secondary)
    }

    private func trashActions(_ card: Card) -> some View {
        HStack {
            if card.trashed {
                Button(L10n.t("restore_card_command")) { ctx.restoreCard(card.id) }
                Button(L10n.t("delete_button"), role: .destructive) { ctx.deleteCardPermanently(card.id) }
            } else if card.archived {
                Button(L10n.t("unarchive_command")) { ctx.unarchiveCard(card.id) }
            }
            Spacer()
        }
    }

    /// Bottom action bar pinned above the pane edge — 编辑 / 设置标签 capsules,
    /// 用于自动填充 checkbox, share button at the far right.
    private func bottomBar(_ card: Card) -> some View {
        HStack(spacing: 10) {
            capsuleButton(L10n.t("edit_button")) {
                ctx.editDraft = EditCardModel(card: card)
            }
            capsuleButton(L10n.t("set_labels_button")) {
                ctx.activeSheet = .labels(cardId: card.id)
            }

            Toggle(L10n.t("use_for_autofill_button"), isOn: Binding(
                get: { ctx.database.card(id: card.id)?.autofillEnabled ?? false },
                set: { on in ctx.setCardAutofill(card.id, on: on) }
            ))
            .toggleStyle(.checkbox)
            .font(.system(size: 12))

            Spacer(minLength: 8)

            ShareLink(item: card.asPlainText()) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 13, weight: .medium))
            }
            .help(L10n.t("share_menu"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(Divider(), alignment: .top)
    }

    private func capsuleButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }
}

/// ViewCardFieldCell + PasswordCell + OneTimePasswordCell — form-style row:
/// caption field name on top, value (or reveal button / live OTP) over a full
/// hairline underline, field-type icon at the right end.
struct FieldRowView: View {
    @EnvironmentObject var ctx: AppContext
    @EnvironmentObject var settings: AppSettings
    let card: Card
    let field: Field

    @State private var revealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(field.name)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline) {
                if field.type.isOneTimePassword {
                    OTPView(rawValue: field.value)
                } else {
                    valueView
                }
                Spacer(minLength: 12)
                if field.hasValue {
                    copyButton
                }
                if field.hasHistory {
                    historyButton
                }
                Image(systemName: typeIcon)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 4)
            Divider()
        }
    }

    /// Field-type glyph shown at the row's right end (original behavior).
    private var typeIcon: String {
        switch field.type {
        case .phone: return "phone"
        case .website: return "globe"
        case .email: return "envelope"
        case .date, .expiry: return "calendar"
        case .password, .pin: return "key"
        case .login: return "person"
        case .oneTimePassword: return "timer"
        default: return "doc.text"
        }
    }

    @ViewBuilder
    private var valueView: some View {
        if field.type.isHidden && !revealed && settings.hidePasswords {
            Button(L10n.t("show_password_button")) { revealed = true }
                .buttonStyle(.link)
                .font(.callout)
        } else if field.type.isHidden {
            HStack(spacing: 6) {
                Text(field.value)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                if !field.value.isEmpty {
                    StrengthIndicatorView(strength: PasswordStrength.score(field.value))
                        .frame(maxWidth: 180)
                }
                Button {
                    revealed = false
                } label: {
                    Image(systemName: "eye.slash")
                }
                .buttonStyle(.borderless)
            }
        } else if field.type == .website, let url = URL(string: field.value.hasPrefix("http") ? field.value : "https://\(field.value)") {
            Link(field.value, destination: url)
                .font(.callout)
        } else {
            Text(field.value)
                .font(.callout)
                .textSelection(.enabled)
        }
    }

    private var copyButton: some View {
        Button {
            ClipboardModel.shared.copy(field.value)
        } label: {
            Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .help(L10n.t("copy_command"))
    }

    private var historyButton: some View {
        Menu {
            ForEach(field.history.sorted { $0.time > $1.time }) { e in
                Text("\(e.value) — \(e.time.date.formatted(date: .abbreviated, time: .shortened))")
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L10n.t("history_title"))
    }
}

/// ViewCardOneTimePasswordCell — live RFC 6238 code with rollover progress.
struct OTPView: View {
    let rawValue: String

    @State private var code: String? = nil
    @State private var remaining: Int = 0
    @State private var error: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            if let code {
                Text(code)
                    .font(.system(.title3, design: .monospaced).bold())
                    .foregroundStyle(.tint)
                Button {
                    ClipboardModel.shared.copyOTP(code)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                Text("(\(remaining)s)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(remaining <= 5 ? .red : .secondary)
            } else if let error {
                Text(error).font(.caption).foregroundStyle(.secondary)
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: tick)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in tick() }
    }

    private func tick() {
        guard let cfg = try? TOTP.parse(rawValue) else {
            error = L10n.t("invalid_value_text")
            code = nil
            return
        }
        code = try? TOTP.code(config: cfg)
        remaining = TOTP.remainingSeconds(period: cfg.period)
    }
}
