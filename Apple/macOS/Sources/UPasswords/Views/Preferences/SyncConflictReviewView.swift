import CryptoKit
import SwiftUI

import UPasswordsCore
import UPasswordsPersistence

struct MacSyncConflictSection: View {
    @EnvironmentObject private var ctx: AppContext
    @State private var conflicts: [RelayClient.ConflictRecord] = []
    @State private var loading = false
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.t("sync_conflict_section"))
                        .font(.headline)
                    Text(L10n.t("sync_conflict_description"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await refresh() }
                } label: {
                    if loading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(loading || ctx.phase != .unlocked || !ctx.relayBound)
                .help(L10n.t("sync_conflict_refresh"))
            }

            if ctx.phase != .unlocked {
                Text(L10n.t("sync_conflict_unlock_required"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !ctx.relayBound {
                Text(L10n.t("sync_conflict_unavailable"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let loadError {
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if conflicts.isEmpty && !loading {
                Text(L10n.t("sync_conflict_empty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(conflicts) { conflict in
                MacSyncConflictGroup(conflict: conflict) {
                    Task { await refresh() }
                }
                .environmentObject(ctx)
            }
        }
        .padding(.top, 8)
        .task { await refresh() }
        .onChange(of: ctx.relayStateVersion) { _, _ in
            Task { await refresh() }
        }
        .onChange(of: ctx.phase) { _, phase in
            if phase != .unlocked { conflicts = [] }
            else { Task { await refresh() } }
        }
    }

    private func refresh() async {
        guard !loading, ctx.phase == .unlocked, ctx.relayBound else { return }
        loading = true
        loadError = nil
        defer { loading = false }
        do {
            conflicts = try await ctx.syncConflicts()
                .sorted { $0.updatedAt > $1.updatedAt }
        } catch {
            Log.error("sync", "macOS conflict list failed: \(error)")
            loadError = error.localizedDescription
        }
    }
}

private struct MacSyncConflictGroup: View {
    @EnvironmentObject private var ctx: AppContext
    let conflict: RelayClient.ConflictRecord
    let onChanged: () -> Void
    @State private var compositionCandidates: [ConflictComposer.Candidate] = []
    @State private var selectedBaseCandidateID = ""
    @State private var selectedFieldSources: [UUID: String] = [:]
    @State private var selectedNotesCandidateID = ""
    @State private var showingCompositionConfirmation = false
    @State private var composing = false
    @State private var compositionError: String?

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(format: L10n.t("sync_conflict_versions_fmt"), conflict.candidates.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if conflict.currentDeletedSequence > 0 {
                    Label(L10n.t("sync_conflict_deleted_current"), systemImage: "trash")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                compositionControls
                ForEach(conflict.candidates.sorted { $0.committedAt < $1.committedAt }) { candidate in
                    MacSyncConflictCandidate(
                        candidate: candidate,
                        conflict: conflict,
                        key: ctx.vaultKey,
                        isBusy: ctx.syncState == .syncing,
                        onResolved: onChanged)
                        .environmentObject(ctx)
                }
            }
            .padding(.vertical, 6)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: conflict.currentDeletedSequence > 0
                      ? "trash" : "arrow.triangle.branch")
                    .foregroundStyle(.orange)
                Text(Self.title(for: conflict, key: ctx.vaultKey))
                    .fontWeight(.medium)
                Spacer()
                Text(conflict.itemUUID.uuidString.prefix(8))
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .padding(9)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
        .task(id: conflict.generation) {
            selectedBaseCandidateID = ""
            selectedFieldSources = [:]
            selectedNotesCandidateID = ""
            compositionError = nil
            compositionCandidates = Self.decodeCandidates(conflict, key: ctx.vaultKey)
            if let key = ctx.vaultKey {
                for candidate in conflict.candidates where !candidate.isDelete {
                    if MacSyncConflictCandidate.decode(candidate, conflict: conflict, key: key) == nil {
                        ctx.quarantineUnreadableSyncConflictCandidate(candidate, conflict: conflict)
                    }
                }
            }
        }
    }

    private static func title(for conflict: RelayClient.ConflictRecord, key: SymmetricKey?) -> String {
        guard let key else { return L10n.t("sync_conflict_item") }
        for candidate in conflict.candidates where !candidate.isDelete {
            guard let item = MacSyncConflictCandidate.decode(candidate, conflict: conflict, key: key) else {
                continue
            }
            switch item {
            case .card(let card): return card.title
            case .label(let label): return label.name
            case .userProfile: return L10n.t("personal_info_title")
            }
        }
        return L10n.t("sync_conflict_item")
    }

    @ViewBuilder
    private var compositionControls: some View {
        if conflict.currentDeletedSequence > 0 || !isCompositionAvailable {
            Label(L10n.t("sync_conflict_compose_unavailable"), systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let groups = ConflictComposer.fieldGroups(for: compositionCandidates),
                  let notesOptions = ConflictComposer.notesOptions(for: compositionCandidates) {
            VStack(alignment: .leading, spacing: 7) {
                Text(L10n.t("sync_conflict_compose_title"))
                    .font(.subheadline.weight(.semibold))
                Text(L10n.t("sync_conflict_compose_description"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker(L10n.t("sync_conflict_metadata_source"), selection: $selectedBaseCandidateID) {
                    Text(L10n.t("sync_conflict_choose_source")).tag("")
                    ForEach(conflict.candidates.filter { !$0.isDelete }) { candidate in
                        Text(sourceTitle(candidate)).tag(candidate.candidateID)
                    }
                }
                ForEach(groups) { group in
                    if group.requiresChoice {
                        Picker(group.title, selection: fieldSelection(group.fieldID)) {
                            Text(L10n.t("sync_conflict_choose_source")).tag("")
                            ForEach(group.options) { option in
                                Text(fieldSourceTitle(option)).tag(option.candidateID)
                            }
                        }
                    } else if let candidateID = group.defaultCandidateID {
                        HStack {
                            Text(group.title)
                            Spacer(minLength: 8)
                            Text(sourceTitle(candidateID))
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }
                if Set(notesOptions.map(\.value)).count > 1 {
                    Picker(L10n.t("sync_conflict_notes_source"), selection: $selectedNotesCandidateID) {
                        Text(L10n.t("sync_conflict_choose_source")).tag("")
                        ForEach(notesOptions) { option in
                            Text(sourceTitle(option.candidateID)).tag(option.candidateID)
                        }
                    }
                }
                if let compositionError {
                    Text(compositionError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Button {
                    showingCompositionConfirmation = true
                } label: {
                    if composing {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(L10n.t("sync_conflict_compose_apply"))
                    }
                }
                .disabled(
                    ctx.syncState == .syncing
                        || composing
                        || !compositionSelectionIsComplete(groups, notesOptions: notesOptions))
                .confirmationDialog(
                    L10n.t("sync_conflict_compose_confirm_title"),
                    isPresented: $showingCompositionConfirmation,
                    titleVisibility: .visible
                ) {
                    Button(L10n.t("sync_conflict_compose_apply")) {
                        Task { await resolveComposition() }
                    }
                    Button(L10n.t("cancel_button"), role: .cancel) {}
                } message: {
                    Text(L10n.t("sync_conflict_compose_confirm_message"))
                }
            }
            .padding(.vertical, 7)
        }
    }

    private var isCompositionAvailable: Bool {
        compositionCandidates.count == conflict.candidates.count
            && ConflictComposer.isComposable(compositionCandidates)
    }

    private func fieldSelection(_ fieldID: UUID) -> Binding<String> {
        Binding(
            get: { selectedFieldSources[fieldID] ?? "" },
            set: { selectedFieldSources[fieldID] = $0 })
    }

    private func compositionSelectionIsComplete(
        _ groups: [ConflictComposer.FieldGroup],
        notesOptions: [ConflictComposer.NotesOption]
    ) -> Bool {
        !selectedBaseCandidateID.isEmpty
            && groups.allSatisfy {
                !$0.requiresChoice || !(selectedFieldSources[$0.fieldID] ?? "").isEmpty
            }
            && (Set(notesOptions.map(\.value)).count <= 1 || !selectedNotesCandidateID.isEmpty)
    }

    private func sourceTitle(_ candidateID: String) -> String {
        guard let candidate = conflict.candidates.first(where: { $0.candidateID == candidateID }) else {
            return L10n.t("sync_conflict_unknown_device")
        }
        return sourceTitle(candidate)
    }

    private func sourceTitle(_ candidate: RelayClient.ConflictCandidate) -> String {
        "\(MacSyncConflictCandidate.source(candidate)) · \(candidate.committedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    private func fieldSourceTitle(_ option: ConflictComposer.FieldOption) -> String {
        let suffix = option.field == nil ? " · \(L10n.t("sync_conflict_field_removed"))" : ""
        return sourceTitle(option.candidateID) + suffix
    }

    private func resolveComposition() async {
        guard !composing, !selectedBaseCandidateID.isEmpty else { return }
        composing = true
        compositionError = nil
        defer { composing = false }
        do {
            try await ctx.resolveSyncConflict(
                conflict,
                candidateID: selectedBaseCandidateID,
                fieldSelections: selectedFieldSources,
                notesCandidateID: selectedNotesCandidateID.isEmpty ? nil : selectedNotesCandidateID)
            onChanged()
        } catch {
            Log.error(
                "sync",
                "macOS conflict composition failed for \(conflict.itemUUID.uuidString.prefix(8)): \(error)")
            compositionError = error.localizedDescription
            onChanged()
        }
    }

    private static func decodeCandidates(
        _ conflict: RelayClient.ConflictRecord,
        key: SymmetricKey?
    ) -> [ConflictComposer.Candidate] {
        guard conflict.currentDeletedSequence == 0, let key else { return [] }
        return conflict.candidates.compactMap { candidate in
            guard !candidate.isDelete,
                  let item = MacSyncConflictCandidate.decode(candidate, conflict: conflict, key: key) else {
                return nil
            }
            return ConflictComposer.Candidate(candidateID: candidate.candidateID, item: item)
        }
    }
}

private struct MacSyncConflictCandidate: View {
    @EnvironmentObject private var ctx: AppContext
    let candidate: RelayClient.ConflictCandidate
    let conflict: RelayClient.ConflictRecord
    let key: SymmetricKey?
    let isBusy: Bool
    let onResolved: () -> Void
    @State private var revealSensitive = false
    @State private var showingConfirmation = false
    @State private var showingCopyConfirmation = false
    @State private var errorMessage: String?
    @State private var resolving = false
    @State private var copying = false

    private var item: DatabaseItem? {
        guard let key else { return nil }
        return Self.decode(candidate, conflict: conflict, key: key)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(candidate.isDelete ? L10n.t("sync_conflict_deleted_version") : title)
                        .font(.callout.weight(.semibold))
                    Text(Self.source(candidate))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(candidate.committedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if !candidate.isDelete, isCardCandidate {
                    Button {
                        showingCopyConfirmation = true
                    } label: {
                        if copying {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "doc.on.doc")
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(isBusy || resolving || copying || !canSaveAsNew)
                    .help(L10n.t("sync_conflict_copy_as_new"))
                    .confirmationDialog(
                        L10n.t("sync_conflict_copy_confirm_title"),
                        isPresented: $showingCopyConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button(L10n.t("sync_conflict_copy_as_new")) {
                            copying = true
                            Task {
                                defer { copying = false }
                                do {
                                    try await ctx.saveSyncConflictCandidateAsNewItem(
                                        conflict,
                                        candidateID: candidate.candidateID)
                                    errorMessage = nil
                                } catch {
                                    errorMessage = error.localizedDescription
                                    Log.error("sync", "macOS conflict candidate copy failed: \(error)")
                                }
                            }
                        }
                        Button(L10n.t("cancel_button"), role: .cancel) {}
                    } message: {
                        Text(L10n.t("sync_conflict_copy_confirm_message"))
                    }
                }
                Button {
                    showingConfirmation = true
                } label: {
                    if resolving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(buttonTitle)
                    }
                }
                .controlSize(.small)
                .disabled(isBusy || resolving || (!candidate.isDelete && item == nil))
                .confirmationDialog(
                    L10n.t("sync_conflict_confirm_title"),
                    isPresented: $showingConfirmation,
                    titleVisibility: .visible
                ) {
                    Button(buttonTitle, role: candidate.isDelete ? .destructive : nil) {
                        Task { await resolve() }
                    }
                    Button(L10n.t("cancel_button"), role: .cancel) {}
                } message: {
                    Text(L10n.t("sync_conflict_confirm_message"))
                }
            }

            if candidate.isDelete {
                Text(L10n.t("sync_conflict_delete_explanation"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let item {
                details(item)
            } else {
                HStack {
                    Label(L10n.t("sync_conflict_unreadable_candidate"), systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Spacer()
                    Button {
                        onResolved()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.t("sync_conflict_candidate_retry"))
                }
            }

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(9)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 5))
    }

    @ViewBuilder
    private func details(_ item: DatabaseItem) -> some View {
        switch item {
        case .card(let card): fieldList(card.fields, notes: card.notes, attachmentCount: card.images.count + card.files.count)
        case .userProfile(let profile): fieldList(profile.fields, notes: "", attachmentCount: 0)
        case .label(let label): Text(label.name).font(.caption)
        }
    }

    private func fieldList(_ fields: [Field], notes: String, attachmentCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(fields) { field in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(field.name.isEmpty ? field.type.localizedName : field.name)
                        .foregroundStyle(.secondary)
                    Text(field.type.isHidden && !revealSensitive
                         ? String(repeating: "•", count: max(4, min(field.value.count, 12)))
                         : field.value.isEmpty ? L10n.t("sync_conflict_empty_value") : field.value)
                        .textSelection(.enabled)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .font(.caption)
            }
            if !notes.isEmpty {
                DisclosureGroup(L10n.t("notes_prompt")) {
                    Text(revealSensitive ? notes : "••••••••")
                        .font(.caption)
                        .textSelection(.enabled)
                }
                .font(.caption)
            }
            if attachmentCount > 0 {
                Label(String(format: L10n.t("sync_conflict_attachments_fmt"), attachmentCount), systemImage: "paperclip")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if fields.contains(where: { $0.type.isHidden }) || !notes.isEmpty {
                Button {
                    revealSensitive.toggle()
                } label: {
                    Label(
                        revealSensitive ? L10n.t("sync_conflict_hide_values") : L10n.t("sync_conflict_reveal_values"),
                        systemImage: revealSensitive ? "eye.slash" : "eye"
                    )
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
    }

    private var title: String {
        switch item {
        case .card(let card): return card.title
        case .label(let label): return label.name
        case .userProfile: return L10n.t("personal_info_title")
        case nil: return L10n.t("sync_conflict_item")
        }
    }

    private var canSaveAsNew: Bool {
        guard case .card(let card) = item, !card.template, !card.trashed else { return false }
        return true
    }

    private var isCardCandidate: Bool {
        guard case .card = item else { return false }
        return true
    }

    private var buttonTitle: String {
        if candidate.isDelete { return L10n.t("sync_conflict_keep_deleted") }
        return conflict.currentDeletedSequence > 0
            ? L10n.t("sync_conflict_restore_version")
            : L10n.t("sync_conflict_keep_version")
    }

    private func resolve() async {
        guard !resolving else { return }
        resolving = true
        errorMessage = nil
        defer { resolving = false }
        do {
            try await ctx.resolveSyncConflict(conflict, candidateID: candidate.candidateID)
            onResolved()
        } catch {
            Log.error(
                "sync",
                "macOS conflict resolution failed for \(conflict.itemUUID.uuidString.prefix(8)): \(error)")
            errorMessage = error.localizedDescription
            if let refreshed = try? await ctx.syncConflicts().first(where: {
                $0.conflictID == conflict.conflictID
            }), refreshed != conflict {
                errorMessage = L10n.t("sync_conflict_refreshed")
            }
            onResolved()
        }
    }

    fileprivate static func decode(
        _ candidate: RelayClient.ConflictCandidate,
        conflict: RelayClient.ConflictRecord,
        key: SymmetricKey
    ) -> DatabaseItem? {
        guard !candidate.isDelete,
              let bodyB64 = candidate.bodyB64,
              let ciphertext = Data(base64Encoded: bodyB64),
              let plaintext = RowSyncCipher.decrypt(
                ciphertext,
                key: RowSyncKey(raw: key.withUnsafeBytes { Data($0) }),
                uuid: conflict.itemUUID) else {
            return nil
        }
        return DatabaseItemCodec.parse(kind: candidate.kind, uuid: conflict.itemUUID, data: plaintext)
    }

    fileprivate static func source(_ candidate: RelayClient.ConflictCandidate) -> String {
        let device = candidate.deviceName.isEmpty
            ? L10n.t("sync_conflict_unknown_device") : candidate.deviceName
        let platform: String
        switch candidate.platform {
        case "ios": platform = "iOS"
        case "macos": platform = "macOS"
        case "ext-safari": platform = "Safari"
        case "ext-chrome": platform = "Chrome"
        case "ext-edge": platform = "Edge"
        case "ext-firefox": platform = "Firefox"
        case "": platform = L10n.t("sync_conflict_unknown_device")
        default: platform = candidate.platform
        }
        return "\(device) · \(platform)"
    }
}
