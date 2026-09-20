import SwiftUI

// MARK: - Add card (SelectTemplateSheetController)

struct AddCardSheet: View {
    @EnvironmentObject var ctx: AppContext
    @Environment(\.dismiss) var dismiss

    var body: some View {
        SheetShell(
            title: L10n.t("add_card_title"),
            minWidth: 460,
            okTitle: L10n.db("custom_template"),
            onCancel: { dismiss() },
            onOk: { open(instantiateCustom()) }
        ) {
            Text(L10n.t("select_template_title"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 8)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 10) {
                    ForEach(Templates.all) { spec in
                        Button {
                            open(Templates.makeCard(from: spec, id: ctx.newCardId()))
                        } label: {
                            VStack(spacing: 6) {
                                CardIconView(symbol: spec.symbol, color: "gray", size: 40)
                                Text(L10n.db(spec.titleKey)).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(10)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func instantiateCustom() -> Card {
        var c = Card(id: ctx.newCardId())
        c.created = Date().millis
        c.modified = c.created
        return c
    }

    private func open(_ card: Card) {
        var m = EditCardModel(card: card)
        m.isNew = true
        ctx.editDraft = m
        dismiss()
    }
}

// MARK: - Add note (add_note_command)

struct AddNoteSheet: View {
    @EnvironmentObject var ctx: AppContext
    @Environment(\.dismiss) var dismiss
    @State private var title = ""
    @State private var notes = ""

    var body: some View {
        SheetShell(
            title: L10n.t("add_note_title"),
            okDisabled: title.isEmpty && notes.isEmpty,
            onCancel: { dismiss() },
            onOk: {
                var card = Card(id: ctx.newCardId())
                card.title = title.isEmpty ? L10n.db("notes_label") : title
                card.notes = notes
                card.color = "yellow"
                card.symbol = "note"
                card.created = Date().millis
                card.modified = card.created
                ctx.upsertCard(card)
                dismiss()
            }
        ) {
            VStack(alignment: .leading, spacing: 10) {
                LabeledRow(label: L10n.t("title_hint")) {
                    TextField("", text: $title).textFieldStyle(.roundedBorder)
                }
                Text(L10n.t("notes_prompt"))
                    .font(.callout).foregroundStyle(.secondary)
                TextEditor(text: $notes)
                    .frame(minHeight: 140)
                    .border(Color(nsColor: .separatorColor))
            }
        }
    }
}

// MARK: - Add / rename label (AddLabelSheetController / rename_label_title)

struct AddLabelSheet: View {
    @EnvironmentObject var ctx: AppContext
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var color: String = "blue"

    var body: some View {
        SheetShell(
            title: L10n.t("add_label_title"),
            okDisabled: name.isEmpty,
            onCancel: { dismiss() },
            onOk: {
                ctx.addLabel(name: name, color: color)
                dismiss()
            }
        ) {
            VStack(alignment: .leading, spacing: 10) {
                LabeledRow(label: L10n.t("name_prompt")) {
                    TextField("", text: $name).textFieldStyle(.roundedBorder)
                }
                LabeledRow(label: L10n.t("color_prompt")) {
                    ColorGrid(selection: $color)
                }
            }
        }
    }
}

struct EditLabelSheet: View {
    @EnvironmentObject var ctx: AppContext
    @Environment(\.dismiss) var dismiss
    let labelId: Int
    @State private var name = ""
    @State private var color: String = "blue"

    var body: some View {
        SheetShell(
            title: L10n.t("rename_label_title"),
            okDisabled: name.isEmpty,
            onCancel: { dismiss() },
            onOk: {
                ctx.renameCardLabel(id: labelId, to: name)
                ctx.setLabelColor(id: labelId, color: color)
                dismiss()
            },
            content: {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledRow(label: L10n.t("name_prompt")) {
                        TextField("", text: $name).textFieldStyle(.roundedBorder)
                    }
                    LabeledRow(label: L10n.t("color_prompt")) {
                        ColorGrid(selection: $color)
                    }
                }
            }
        )
        .onAppear {
            if let l = ctx.database.label(id: labelId) {
                name = l.name
                color = l.color ?? "blue"
            }
        }
    }
}

struct SelectColorLabelSheet: View {
    @EnvironmentObject var ctx: AppContext
    @Environment(\.dismiss) var dismiss
    let labelId: Int
    @State private var color: String = "blue"

    var body: some View {
        SheetShell(
            title: L10n.t("select_color_command"),
            onCancel: { dismiss() },
            onOk: {
                ctx.setLabelColor(id: labelId, color: color)
                dismiss()
            }
        ) {
            ColorGrid(selection: $color, large: true)
        }
        .onAppear {
            if let l = ctx.database.label(id: labelId), let c = l.color { color = c }
        }
    }
}

// MARK: - Sorting (SortingSheetController)

struct SortingSheet: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) var dismiss
    @State private var value: Sorting = .titleAsc

    var body: some View {
        SheetShell(
            title: L10n.t("sorting_title"),
            onAppearBody: { value = settings.sortingValue },
            onCancel: { dismiss() },
            onOk: {
                settings.sortingValue = value
                dismiss()
            },
            content: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.t("sorting_text")).font(.callout).foregroundStyle(.secondary)
                    ForEach(Sorting.allCases) { s in
                        Button {
                            value = s
                        } label: {
                            HStack {
                                Image(systemName: value == s ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(value == s ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                Text(s.name)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    Divider()
                    Toggle(L10n.t("favorites_at_top_setting"), isOn: $settings.favoritesAtTop)
                }
            }
        )
    }
}

// MARK: - Generator (PasswordOptionsSheetController + PasswordOptionsViewController)

struct GeneratorSheet: View {
    @EnvironmentObject var pwd: PasswordSettings
    @Environment(\.dismiss) var dismiss
    @State private var generated = ""
    @State private var showOptions = false

    private var typeNames: [(String, Int)] {
        [(L10n.t("random_text"), 0), (L10n.t("memorable_text"), 1),
         (L10n.t("letters_and_numbers_text"), 2), (L10n.t("numbers_only_text"), 3)]
    }

    var body: some View {
        SheetShell(
            title: L10n.t("generate_password_title"),
            minWidth: 460,
            okTitle: L10n.t("close_button"),
            onAppearBody: { regenerate() },
            onCancel: { dismiss() },
            onOk: { dismiss() },
        ) {
            VStack(spacing: 14) {
                DisclosureGroup(isExpanded: $showOptions) {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker(L10n.t("type_prompt"), selection: $pwd.passwordType) {
                            ForEach(typeNames, id: \.1) { t in
                                Text(t.0).tag(t.1)
                            }
                        }
                        Stepper(value: $pwd.passwordLength, in: 4...64) {
                            HStack {
                                Text(L10n.t("length_prompt"))
                                Text("\(pwd.passwordLength)").foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                        LabeledRow(label: L10n.t("password_symbols_prompt")) {
                            TextField("", text: $pwd.symbolsAlphabet).textFieldStyle(.roundedBorder)
                        }
                        LabeledRow(label: L10n.t("password_separators_prompt")) {
                            TextField("", text: $pwd.separatorAlphabet).textFieldStyle(.roundedBorder)
                        }
                        Toggle(L10n.t("exclude_similar_characters_prompt"), isOn: $pwd.excludeSimilarCharacters)
                    }
                    .padding(.top, 8)
                } label: {
                    Label(L10n.t("options_title"), systemImage: "slider.horizontal.3")
                }

                Text(generated)
                    .font(.system(.title2, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity)

                if !generated.isEmpty {
                    StrengthIndicatorView(strength: PasswordStrength.score(generated))
                }

                HStack {
                    Button {
                        regenerate()
                    } label: {
                        Label(L10n.t("generator_button"), systemImage: "arrow.clockwise")
                    }
                    Spacer()
                    Button(L10n.t("copy_command")) {
                        ClipboardModel.shared.copy(generated)
                    }
                    .disabled(generated.isEmpty)
                }

                if !PasswordGenerator.instance.history.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.t("history_title")).font(.caption.bold()).foregroundStyle(.secondary)
                        ForEach(PasswordGenerator.instance.history.prefix(5), id: \.self) { h in
                            HStack {
                                Text(h).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button {
                                    ClipboardModel.shared.copy(h)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        Button(L10n.t("clear_button")) {
                            PasswordGenerator.instance.clearHistory()
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
            }
        }
    }

    private func regenerate() {
        generated = PasswordGenerator.instance.password(length: pwd.passwordLength, type: pwd.passwordType)
        PasswordGenerator.instance.addPasswordToHistory(generated)
    }
}

// MARK: - Set labels (SetLabelsSheetController + SetLabelsViewController)

struct SetLabelsSheet: View {
    @EnvironmentObject var ctx: AppContext
    @Environment(\.dismiss) var dismiss
    let cardId: Int

    @State private var selection: Set<Int> = []
    @State private var newLabelName = ""

    var body: some View {
        SheetShell(
            title: L10n.t("set_labels_button"),
            minWidth: 420,
            okTitle: L10n.t("save_button"),
            onAppearBody: {
                if let c = ctx.database.card(id: cardId) {
                    selection = Set(c.labelIds)
                }
            },
            onCancel: { dismiss() },
            onOk: {
                ctx.setLabels(cardId: cardId, labelIds: selection.sorted())
                dismiss()
            },
            content: {
                VStack(spacing: 0) {
                    List {
                        ForEach(ctx.database.labels) { label in
                            Button {
                                if selection.contains(label.id) {
                                    selection.remove(label.id)
                                } else {
                                    selection.insert(label.id)
                                }
                            } label: {
                                HStack {
                                    Image(systemName: selection.contains(label.id) ? "checkmark.square.fill" : "square")
                                        .foregroundStyle(selection.contains(label.id) ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                    Circle().fill(CardColor.color(named: label.color)).frame(width: 10, height: 10)
                                    Text(label.name)
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .listStyle(.plain)
                    .frame(minHeight: 180)
                    HStack {
                        TextField(L10n.t("add_label_button"), text: $newLabelName)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(addNew)
                        Button(L10n.t("add_button"), action: addNew)
                            .disabled(newLabelName.isEmpty)
                    }
                    .padding(.top, 10)
                }
            }
        )
    }

    private func addNew() {
        guard !newLabelName.isEmpty else { return }
        ctx.addLabelAndAssign(name: newLabelName, color: nil, to: cardId)
        if let c = ctx.database.card(id: cardId) {
            selection = Set(c.labelIds)
        }
        newLabelName = ""
    }
}

// MARK: - Symbol picker (SelectSymbolViewController + SymbolCellItem)

struct SelectSymbolSheet: View {
    @EnvironmentObject var ctx: AppContext
    @Environment(\.dismiss) var dismiss
    @State private var group: String = "internet_group"
    @State private var query = ""

    var body: some View {
        SheetShell(
            title: L10n.t("select_symbol_command"),
            minWidth: 520,
            okTitle: L10n.t("close_button"),
            search: $query,
            onCancel: { dismiss() },
            onOk: { dismiss() },
            content: {
                VStack(spacing: 0) {
                    Picker("", selection: $group) {
                        ForEach(SymbolModel.shared.groupNames, id: \.self) { g in
                            Text(SymbolModel.shared.groupName(g)).tag(g)
                        }
                    }
                    .pickerStyle(.menu)
                    .padding(.bottom, 10)
                    ScrollView {
                        let items = query.isEmpty
                            ? SymbolModel.shared.names(forGroup: group)
                            : SymbolModel.shared.groups.values.flatMap { $0 }.filter { $0.localizedCaseInsensitiveContains(query) }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 72))], spacing: 10) {
                            ForEach(items, id: \.self) { name in
                                Button {
                                    ctx.editDraft?.card.symbol = name
                                    dismiss()
                                } label: {
                                    VStack(spacing: 4) {
                                        Image(systemName: SymbolModel.shared.sfSymbol(for: name))
                                            .font(.title2)
                                        Text(name).font(.caption2).lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(8)
                                    .background(
                                        ctx.editDraft?.card.symbol == name
                                            ? Color.accentColor.opacity(0.2)
                                            : Color(nsColor: .controlBackgroundColor),
                                        in: RoundedRectangle(cornerRadius: 8)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.bottom, 10)
                    }
                }
            }
        )
    }
}

// MARK: - Color picker (SelectColorViewController)

struct SelectColorSheet: View {
    @EnvironmentObject var ctx: AppContext
    @Environment(\.dismiss) var dismiss
    @State private var selection: String = "gray"

    var body: some View {
        SheetShell(
            title: L10n.t("select_color_command"),
            onAppearBody: {
                if let c = ctx.editDraft?.card.color { selection = c }
            },
            onCancel: { dismiss() },
            onOk: {
                ctx.editDraft?.card.color = selection
                dismiss()
            },
            content: {
                VStack(alignment: .leading, spacing: 12) {
                    ColorGrid(selection: $selection, large: true)
                    Toggle(L10n.t("use_website_icon_command"), isOn: Binding(
                        get: { ctx.editDraft?.card.useWebsiteIcon ?? false },
                        set: { ctx.editDraft?.card.useWebsiteIcon = $0 }
                    ))
                }
            }
        )
    }
}

// MARK: - Template picker inside editor (select_template_title)

struct SelectTemplateSheet: View {
    @EnvironmentObject var ctx: AppContext
    @Environment(\.dismiss) var dismiss

    var body: some View {
        SheetShell(
            title: L10n.t("select_template_title"),
            minWidth: 440,
            okTitle: L10n.t("close_button"),
            onCancel: { dismiss() },
            onOk: { dismiss() },
            content: {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.t("select_source_text"))
                        .font(.callout).foregroundStyle(.secondary)
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(Templates.all) { spec in
                                Button {
                                    apply(spec)
                                } label: {
                                    HStack {
                                        CardIconView(symbol: spec.symbol, color: "gray", size: 30)
                                        Text(L10n.db(spec.titleKey))
                                        Spacer()
                                        Text("\(spec.fields.count) \(L10n.t("fields_tab"))")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    .padding(8)
                                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        )
    }

    private func apply(_ spec: Templates.Spec) {
        guard ctx.editDraft != nil else { return }
        let card = Templates.makeCard(from: spec, id: ctx.editDraft!.card.id)
        ctx.editDraft!.card.title = L10n.db(spec.titleKey)
        ctx.editDraft!.card.symbol = spec.symbol
        ctx.editDraft!.card.autofillEnabled = spec.autofill
        ctx.editDraft!.card.fields = card.fields
        dismiss()
    }
}

// MARK: - SelectColorViewController grid

struct ColorGrid: View {
    @Binding var selection: String
    var large = false

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: large ? 40 : 26))], spacing: 8) {
            ForEach(CardColor.allCases) { c in
                Button {
                    selection = c.rawValue
                } label: {
                    ZStack {
                        Circle().fill(c.color)
                            .frame(width: large ? 32 : 20, height: large ? 32 : 20)
                        if selection == c.rawValue {
                            Image(systemName: "checkmark")
                                .font(.caption.bold())
                                .foregroundStyle(c == .white || c == .yellow ? .black : .white)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}
