import SwiftUI
import AppKit

// MARK: - Export

struct ExportAsSheet: View {
    @EnvironmentObject var ctx: AppContext
    @Environment(\.dismiss) var dismiss
    @State private var format: ExportFormat = .xml

    var body: some View {
        SheetShell(
            title: L10n.t("export_as_title"),
            onCancel: { dismiss() },
            onOk: { export() },
            content: {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.t("export_as_text")).font(.callout)
                    Picker("", selection: $format) {
                        ForEach(ExportFormat.allCases) { f in
                            Text(f.name).tag(f)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    Label(L10n.t("export_warning_message"), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }
        )
    }

    @MainActor private func export() {
        let cards = ctx.database.cards.filter { !$0.template }
        let text = ExportCardsTask.export(cards, labels: ctx.database.labels, format: format)
        let panel = NSSavePanel()
        panel.allowedContentTypes = format == .xml ? [.xml] : [.plainText]
        panel.nameFieldStringValue = "\(ctx.databaseName).\(format.rawValue)"
        if panel.runModal() == .OK, let url = panel.url {
            try? text.data(using: .utf8)?.write(to: url)
            AppToast.shared.show(L10n.t("data_exported_message") + " " + url.path)
        }
        dismiss()
    }
}

// MARK: - Import

struct ImportSheet: View {
    @EnvironmentObject var ctx: AppContext
    @Environment(\.dismiss) var dismiss

    @State private var formatId: String? = nil
    @State private var log: [String] = []
    @State private var imported = 0
    @State private var ranOnce = false

    var body: some View {
        SheetShell(
            title: L10n.t("import_command"),
            minWidth: 520,
            okTitle: ranOnce ? L10n.t("close_button") : L10n.t("continue_button"),
            okDisabled: !ranOnce && formatId == nil,
            onCancel: { dismiss() },
            onOk: { ranOnce ? dismiss() : run() },
            content: {
                VStack(alignment: .leading, spacing: 10) {
                    if !ranOnce {
                        Text(L10n.t("select_source_text"))
                            .font(.callout).foregroundStyle(.secondary)
                        ScrollView {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 8) {
                                ForEach(ImportFormatFactory.all, id: \.id) { f in
                                    Button {
                                        formatId = f.id
                                    } label: {
                                        Text(f.title)
                                            .lineLimit(1)
                                            .padding(8)
                                            .frame(maxWidth: .infinity)
                                            .background(
                                                formatId == f.id ? Color.accentColor.opacity(0.2) : Color(nsColor: .controlBackgroundColor),
                                                in: RoundedRectangle(cornerRadius: 6)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    } else {
                        Text(L10n.t("log_title")).font(.headline)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(log, id: \.self) { l in
                                    Text(l).font(.system(.callout, design: .monospaced))
                                }
                            }
                        }
                        Label("\(imported) \(L10n.t("cards_title"))", systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                    }
                }
            }
        )
    }

    private func run() {
        guard let id = formatId, let format = ImportFormatFactory.format(id: id) else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .xml, .json, .commaSeparatedText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.urls.first,
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            log = [L10n.t("operation_canceled_text")]
            return
        }
        log.append("\(L10n.t("source_prompt")) \(format.title)")
        log.append("\(L10n.t("conversion_started_message"))")
        var db = ctx.database
        do {
            let n = try format.parse(text, into: &db, now: Date())
            ctx.database = db
            ctx.save()
            imported = n
            log.append("\(L10n.t("conversion_completed_message")) — \(n) \(L10n.t("cards_title"))")
        } catch {
            log.append("\(L10n.t("conversion_failed_message")): \(error.localizedDescription)")
        }
        ranOnce = true
        ctx.markSetupTaskDone(.importPasswords)
    }
}

