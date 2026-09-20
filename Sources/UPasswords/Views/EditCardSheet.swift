import SwiftUI
import AppKit

/// Mirrors `EditCardModel` (Models/EditCardModel.h) — a working copy of the
/// card plus per-target sub-state for the symbol/color/template pickers.
struct EditCardModel: Identifiable {
    var id: Int { card.id }
    var card: Card
    var isNew: Bool = false
    var pendingFieldTarget: FieldTarget = .none

    enum FieldTarget: Equatable {
        case none
        case card
        case label
    }
}

/// EditCardWindowController — tabbed editor (EditCardFieldsTab / NotesTab /
/// ImagesTab / FilesTab) presented as a sheet over the main window.
struct EditCardSheet: View {
    @EnvironmentObject var ctx: AppContext
    @Binding var draft: EditCardModel?

    @State private var tab: EditTab = .fields

    enum EditTab: String, CaseIterable, Identifiable {
        case fields, notes, images, files
        var id: String { rawValue }
        var name: String {
            switch self {
            case .fields: return L10n.t("fields_tab")
            case .notes: return L10n.t("notes_tab")
            case .images: return L10n.t("images_tab")
            case .files: return L10n.t("files_tab")
            }
        }
    }

    var body: some View {
        if let d = Binding($draft) {
            EditCardBody(draft: d, tab: $tab)
        } else {
            Color.clear.frame(minWidth: 560, minHeight: 480)
        }
    }
}

private struct EditCardBody: View {
    @EnvironmentObject var ctx: AppContext
    @Binding var draft: EditCardModel
    @Binding var tab: EditCardSheet.EditTab
    @State private var fieldEditor: FieldEditorState? = nil

    private var cardBinding: Binding<Card> {
        Binding(get: { draft.card }, set: { draft.card = $0 })
    }
    private var titleBinding: Binding<String> {
        Binding(get: { draft.card.title }, set: { draft.card.title = $0 })
    }
    private var favoriteBinding: Binding<Bool> {
        Binding(get: { draft.card.favorite }, set: { draft.card.favorite = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            header(cardBinding)
            Divider()
            Picker("", selection: $tab) {
                ForEach(EditCardSheet.EditTab.allCases) { t in
                    Text(t.name).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .padding(12)
            Group {
                switch tab {
                case .fields: FieldsTab(card: cardBinding, fieldEditor: $fieldEditor)
                case .notes: NotesTab(card: cardBinding)
                case .images: ImagesTab(card: cardBinding)
                case .files: FilesTab(card: cardBinding)
                }
            }
            .frame(maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 480)
        .background(.regularMaterial)
        .sheet(item: $fieldEditor) { state in
            FieldEditorSheet(state: state) { field in
                if let i = draft.card.fields.firstIndex(where: { $0.id == field.id }) {
                    draft.card.fields[i] = field
                } else {
                    draft.card.fields.append(field)
                }
            }
            .environmentObject(ctx)
        }
    }

    // MARK: Header (title / symbol / color / template)

    private func header(_ card: Binding<Card>) -> some View {
        HStack(spacing: 12) {
            Button {
                ctx.activeSheet = .selectSymbol
            } label: {
                CardIconView(symbol: card.wrappedValue.symbol,
                             color: card.wrappedValue.color, size: 44)
            }
            .buttonStyle(.plain)
            .help(L10n.t("select_symbol_command"))

            Button {
                ctx.activeSheet = .selectColor
            } label: {
                Circle()
                    .fill(CardColor.color(named: card.wrappedValue.color))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .help(L10n.t("select_color_command"))

            TextField(L10n.t("title_hint"), text: titleBinding)
                .textFieldStyle(.roundedBorder)
                .font(.title3)

            Button {
                ctx.activeSheet = .selectTemplate
            } label: {
                Label(L10n.db("templates_label"), systemImage: "square.stack.3d.up")
            }
            .help(L10n.t("select_template_title"))

            Toggle(isOn: favoriteBinding) {
                Image(systemName: "star")
            }
            .toggleStyle(.button)
            .help(L10n.t("favorites_label"))
        }
        .padding(12)
    }

    private var footer: some View {
        HStack {
            if !draft.isNew {
                Button(L10n.t("save_as_template_button")) {
                    var t = draft.card
                    t.template = true
                    t.id = ctx.newCardId()
                    ctx.database.cards.append(t)
                    AppToast.shared.show(L10n.t("template_saved_message"))
                    ctx.editDraft = nil
                }
            }
            Spacer()
            Button(L10n.t("cancel_button")) {
                ctx.editDraft = nil
            }
            .keyboardShortcut(.cancelAction)
            Button(L10n.t("save_and_close_button")) {
                ctx.upsertCard(draft.card)
                ctx.editDraft = nil
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

}

// MARK: - Fields tab (EditCardFieldsTab + EditCardFieldCell / AddField / Password cells)

private struct FieldsTab: View {
    @EnvironmentObject var ctx: AppContext
    @Binding var card: Card
    @Binding var fieldEditor: FieldEditorState?

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    ForEach($card.fields) { $field in
                        FieldEditRow(field: $field, onEdit: {
                            fieldEditor = FieldEditorState(field: field)
                        }, onDelete: {
                            card.fields.removeAll { $0.id == field.id }
                        })
                    }
                    .onMove { card.fields.move(fromOffsets: $0, toOffset: $1) }
                } header: {
                    HStack {
                        Text(L10n.t("fields_tab"))
                        Spacer()
                        Text(L10n.t("organize_fields_button"))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            HStack {
                Button {
                    fieldEditor = FieldEditorState(field: Field(name: ""))
                } label: {
                    Label(L10n.t("add_field_button"), systemImage: "plus")
                }
                Spacer()
                Text("\(card.fields.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
        }
    }
}

/// AddFieldSheetController / EditFieldSheetController state (name/type/autofill).
struct FieldEditorState: Identifiable {
    let id = UUID()
    var field: Field
}

struct FieldEditorSheet: View {
    @Environment(\.dismiss) var dismiss
    let state: FieldEditorState
    let onSave: (Field) -> Void
    @State private var name = ""
    @State private var type: FieldType = .text
    @State private var autofill: Autofill = .off

    var body: some View {
        SheetShell(
            title: state.field.name.isEmpty ? L10n.t("add_field_title") : L10n.t("edit_field_title"),
            okDisabled: name.isEmpty,
            onAppearBody: {
                name = state.field.name
                type = state.field.type
                autofill = state.field.autofill
            },
            onCancel: { dismiss() },
            onOk: {
                var f = state.field
                f.name = name
                f.type = type
                f.autofill = autofill
                onSave(f)
                dismiss()
            },
            content: {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledRow(label: L10n.t("field_name_prompt")) {
                        TextField("", text: $name).textFieldStyle(.roundedBorder)
                    }
                    LabeledRow(label: L10n.t("type_prompt")) {
                        Picker("", selection: $type) {
                            ForEach(FieldType.allCases) { t in
                                Text(t.localizedName).tag(t)
                            }
                        }
                    }
                    LabeledRow(label: L10n.t("autofill_title", fallback: "自动填充")) {
                        Picker("", selection: $autofill) {
                            ForEach(Autofill.allCases) { a in
                                Text(a.localizedName).tag(a)
                            }
                        }
                    }
                }
            }
        )
    }
}

private struct FieldEditRow: View {
    @EnvironmentObject var ctx: AppContext
    @Binding var field: Field
    var onEdit: () -> Void
    var onDelete: () -> Void
    @State private var revealed = false
    @FocusState private var valueFocused: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: field.type.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 22)

            TextField(L10n.t("field_name_prompt"), text: $field.name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 130)

            if field.type.isOneTimePassword {
                TextField(L10n.db("one_time_password_field"), text: $field.value)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                if let cfg = try? TOTP.parse(field.value),
                   let code = try? TOTP.code(config: cfg) {
                    Text(code)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.tint)
                }
            } else if field.type.isHidden {
                HStack(spacing: 4) {
                    TextField(L10n.t("field_value_prompt"),
                              text: $field.value)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .focused($valueFocused)
                    if revealed || field.value.isEmpty == false {
                        if revealed {
                            Button {
                                revealed = false
                            } label: {
                                Image(systemName: "eye.slash")
                            }
                            .buttonStyle(.borderless)
                        } else {
                            Button {
                                revealed = true
                            } label: {
                                Image(systemName: "eye")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            } else {
                TextField(L10n.t("field_value_prompt"), text: $field.value)
                    .textFieldStyle(.roundedBorder)
            }

            if field.type == .password && !field.value.isEmpty {
                StrengthIndicatorView(strength: PasswordStrength.score(field.value))
                    .frame(maxWidth: 160)
            }

            if field.type == .password {
                Menu {
                    ForEach(0..<4) { t in
                        let name = [L10n.t("random_text"), L10n.t("memorable_text"),
                                    L10n.t("letters_and_numbers_text"), L10n.t("numbers_only_text")][t]
                        Button(name) {
                            field.value = PasswordGenerator.instance.password(
                                length: PasswordSettings.shared.passwordLength, type: t)
                            PasswordGenerator.instance.addPasswordToHistory(field.value)
                        }
                    }
                } label: {
                    Image(systemName: "wand.and.stars")
                }
                .buttonStyle(.borderless)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(L10n.t("generate_password_title"))
            }

            Menu {
                Button(L10n.t("edit_field_title")) { onEdit() }
                Divider()
                if field.hasHistory {
                    ForEach(field.history.sorted { $0.time > $1.time }) { h in
                        Button("\(h.value)") { field.value = h.value }
                    }
                    Divider()
                }
                Button(L10n.t("delete_button"), role: .destructive) {
                    onDelete()
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .buttonStyle(.borderless)
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Notes tab (EditCardNotesTab)

private struct NotesTab: View {
    @Binding var card: Card

    var body: some View {
        TextEditor(text: $card.notes)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(12)
    }
}

// MARK: - Images tab (EditCardImagesTab + EditCardImageCell)

private struct ImagesTab: View {
    @Binding var card: Card
    @State private var dropped = false

    var body: some View {
        VStack {
            if card.images.isEmpty {
                Text(L10n.t("attach_image_warning"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                    .padding()
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 12) {
                    ForEach(card.images) { img in
                        VStack(spacing: 4) {
                            if let ns = NSImage(data: img.data) {
                                Image(nsImage: ns)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 110, height: 110)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            Button(role: .destructive) {
                                card.images.removeAll { $0.id == img.id }
                            } label: {
                                Label(L10n.t("delete_button"), systemImage: "trash")
                                    .font(.caption)
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
                .padding(12)
            }
            HStack {
                Button {
                    pickImage()
                } label: {
                    Label(L10n.t("attach_image_button"), systemImage: "photo.badge.plus")
                }
                Spacer()
            }
            .padding(12)
        }
    }

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls {
                if let data = try? Data(contentsOf: url) {
                    // 150 KB image budget matches the original's guidance
                    card.images.append(Attachment(name: url.lastPathComponent, data: data))
                }
            }
        }
    }
}

// MARK: - Files tab (EditCardFilesTab + EditCardFileCell)

private struct FilesTab: View {
    @Binding var card: Card

    private let maxFileBytes = 150 * 1024

    var body: some View {
        VStack {
            if card.files.isEmpty {
                Text(L10n.t("attach_file_warning"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                    .padding()
            }
            List {
                ForEach(card.files) { file in
                    HStack {
                        Image(systemName: "doc")
                        Text(file.name)
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: Int64(file.length), countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary)
                        Button(role: .destructive) {
                            card.files.removeAll { $0.id == file.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            HStack {
                Button {
                    pickFile()
                } label: {
                    Label(L10n.t("attach_file_button"), systemImage: "paperclip.badge.plus")
                }
                Spacer()
            }
            .padding(12)
        }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls {
                guard let data = try? Data(contentsOf: url) else { continue }
                if data.count > maxFileBytes {
                    AppToast.shared.show(L10n.t("attach_file_error"))
                    continue
                }
                card.files.append(Attachment(name: url.lastPathComponent, data: data))
            }
        }
    }
}
