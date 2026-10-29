import SwiftUI
import CryptoKit

import UPasswordsCore
import UPasswordsPersistence

struct IOSSyncConflictSection: View {
    @EnvironmentObject private var vault: Vault
    @State private var conflicts: [RelayClient.ConflictRecord] = []
    @State private var selectedConflict: RelayClient.ConflictRecord?
    @State private var loading = false
    @State private var loadError: String?

    var body: some View {
        Section(L10n.t("ios_sync_conflict_section")) {
            HStack {
                Text(L10n.t("ios_sync_conflict_description"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button {
                    Task { await refresh() }
                } label: {
                    if loading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(loading || vault.locked || !vault.relayBound)
                .accessibilityLabel(L10n.t("ios_sync_conflict_refresh"))
            }

            if vault.locked {
                Text(L10n.t("ios_sync_conflict_unlock_required"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if !vault.relayBound {
                Text(L10n.t("ios_sync_conflict_unavailable"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if let loadError {
                Text(loadError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            } else if conflicts.isEmpty && !loading {
                Text(L10n.t("ios_sync_conflict_empty"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ForEach(conflicts) { conflict in
                Button {
                    selectedConflict = conflict
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: conflict.currentDeletedSequence > 0
                              ? "trash" : "arrow.triangle.branch")
                            .foregroundStyle(.orange)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(Self.title(for: conflict, key: vault.vaultKey))
                                .font(.body.weight(.medium))
                                .foregroundStyle(.primary)
                            Text(String(format: L10n.t("ios_sync_conflict_versions_fmt"), conflict.candidates.count))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .task {
            await refresh()
        }
        .onChange(of: vault.relayStateVersion) { _, _ in
            Task { await refresh() }
        }
        .onChange(of: vault.locked) { _, locked in
            if locked { conflicts = [] }
            else { Task { await refresh() } }
        }
        .sheet(item: $selectedConflict) { conflict in
            IOSSyncConflictReviewSheet(conflict: conflict) {
                Task { await refresh() }
            }
            .environmentObject(vault)
        }
    }

    private func refresh() async {
        guard !loading, !vault.locked, vault.relayBound else { return }
        loading = true
        loadError = nil
        defer { loading = false }
        do {
            conflicts = try await vault.syncConflicts()
                .sorted { $0.updatedAt > $1.updatedAt }
        } catch {
            Log.error("sync", "ios conflict list failed: \(error)")
            loadError = error.localizedDescription
        }
    }

    private static func title(for conflict: RelayClient.ConflictRecord, key: SymmetricKey?) -> String {
        guard let key else { return L10n.t("ios_sync_conflict_item") }
        for candidate in conflict.candidates where !candidate.isDelete {
            guard let item = Self.decode(candidate, conflict: conflict, key: key) else { continue }
            switch item {
            case .card(let card): return card.title
            case .label(let label): return label.name
            case .userProfile: return L10n.t("personal_info_title")
            }
        }
        return L10n.t("ios_sync_conflict_item")
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
}

private struct IOSSyncConflictReviewSheet: View {
    @EnvironmentObject private var vault: Vault
    @Environment(\.dismiss) private var dismiss
    @State private var conflict: RelayClient.ConflictRecord
    @State private var resolvingCandidateID: String?
    @State private var errorMessage: String?
    @State private var confirmationCandidate: RelayClient.ConflictCandidate?
    @State private var compositionCandidates: [ConflictComposer.Candidate] = []
    @State private var selectedBaseCandidateID = ""
    @State private var selectedFieldSources: [UUID: String] = [:]
    @State private var selectedNotesCandidateID = ""
    @State private var showingCompositionConfirmation = false
    @State private var compositionError: String?
    let onResolved: () -> Void

    init(conflict: RelayClient.ConflictRecord, onResolved: @escaping () -> Void) {
        _conflict = State(initialValue: conflict)
        self.onResolved = onResolved
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(L10n.t("ios_sync_conflict_choose_whole_version"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if conflict.currentDeletedSequence > 0 {
                        Label(L10n.t("ios_sync_conflict_deleted_current"), systemImage: "trash")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                compositionSection

                ForEach(conflict.candidates.sorted { $0.committedAt < $1.committedAt }) { candidate in
                    IOSConflictCandidateView(
                        candidate: candidate,
                        conflict: conflict,
                        key: vault.vaultKey,
                        isResolving: resolvingCandidateID != nil,
                        choose: { confirmationCandidate = candidate },
                        retry: { Task { await refreshCandidateSet() } },
                        saveAsNew: {
                            try await vault.saveSyncConflictCandidateAsNewItem(
                                conflict,
                                candidateID: candidate.candidateID)
                        })
                }
            }
            .navigationTitle(L10n.t("ios_sync_conflict_review_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("close_button")) { dismiss() }
                }
            }
            .confirmationDialog(
                L10n.t(showingCompositionConfirmation
                    ? "ios_sync_conflict_compose_confirm_title"
                    : "ios_sync_conflict_confirm_title"),
                isPresented: Binding(
                    get: { confirmationCandidate != nil || showingCompositionConfirmation },
                    set: {
                        if !$0 {
                            confirmationCandidate = nil
                            showingCompositionConfirmation = false
                        }
                    }
                ),
                titleVisibility: .visible
            ) {
                if let candidate = confirmationCandidate {
                    Button(
                        candidate.isDelete
                            ? L10n.t("ios_sync_conflict_keep_deleted")
                            : conflict.currentDeletedSequence > 0
                                ? L10n.t("ios_sync_conflict_restore_version")
                                : L10n.t("ios_sync_conflict_keep_version"),
                        role: candidate.isDelete ? .destructive : nil
                    ) {
                        Task { await resolve(candidate) }
                    }
                }
                if showingCompositionConfirmation {
                    Button(L10n.t("ios_sync_conflict_compose_apply")) {
                        Task { await resolveComposition() }
                    }
                }
                Button(L10n.t("cancel_button"), role: .cancel) {}
            } message: {
                Text(L10n.t(showingCompositionConfirmation
                    ? "ios_sync_conflict_compose_confirm_message"
                    : "ios_sync_conflict_confirm_message"))
            }
            .task(id: "\(conflict.conflictID)-\(conflict.generation)") {
                selectedBaseCandidateID = ""
                selectedFieldSources = [:]
                selectedNotesCandidateID = ""
                compositionError = nil
                compositionCandidates = Self.decodeCandidates(conflict, key: vault.vaultKey)
            if let key = vault.vaultKey {
                for candidate in conflict.candidates where !candidate.isDelete {
                    if IOSSyncConflictSection.decode(candidate, conflict: conflict, key: key) == nil {
                        vault.quarantineUnreadableSyncConflictCandidate(candidate, conflict: conflict)
                    }
                }
            }
            }
            .onChange(of: vault.locked) { _, locked in
                if locked { dismiss() }
            }
            .onDisappear {
                confirmationCandidate = nil
            }
        }
    }

    private func resolve(_ candidate: RelayClient.ConflictCandidate) async {
        guard resolvingCandidateID == nil else { return }
        resolvingCandidateID = candidate.candidateID
        errorMessage = nil
        defer { resolvingCandidateID = nil }
        do {
            try await vault.resolveSyncConflict(conflict, candidateID: candidate.candidateID)
            onResolved()
            dismiss()
        } catch {
            Log.error(
                "sync",
                "ios conflict resolution failed for \(conflict.itemUUID.uuidString.prefix(8)): \(error)")
            errorMessage = error.localizedDescription
            let latest = try? await vault.syncConflicts()
            if let refreshed = latest?.first(where: { $0.conflictID == conflict.conflictID }) {
                conflict = refreshed
                errorMessage = L10n.t("ios_sync_conflict_refreshed")
            } else if latest != nil {
                dismiss()
            }
            onResolved()
        }
    }

    @ViewBuilder
    private var compositionSection: some View {
        Section(L10n.t("ios_sync_conflict_compose_title")) {
            if conflict.currentDeletedSequence > 0 || !isCompositionAvailable {
                Label(L10n.t("ios_sync_conflict_compose_unavailable"), systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if let groups = ConflictComposer.fieldGroups(for: compositionCandidates),
                      let notesOptions = ConflictComposer.notesOptions(for: compositionCandidates) {
                Text(L10n.t("ios_sync_conflict_compose_description"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Picker(L10n.t("ios_sync_conflict_metadata_source"), selection: $selectedBaseCandidateID) {
                    Text(L10n.t("ios_sync_conflict_choose_source")).tag("")
                    ForEach(conflict.candidates.filter { !$0.isDelete }) { candidate in
                        Text(sourceTitle(candidate)).tag(candidate.candidateID)
                    }
                }
                .pickerStyle(.menu)
                ForEach(groups) { group in
                    if group.requiresChoice {
                        Picker(group.title, selection: fieldSelection(group.fieldID)) {
                            Text(L10n.t("ios_sync_conflict_choose_source")).tag("")
                            ForEach(group.options) { option in
                                Text(fieldSourceTitle(option)).tag(option.candidateID)
                            }
                        }
                        .pickerStyle(.menu)
                    } else if let candidateID = group.defaultCandidateID {
                        LabeledContent(group.title, value: sourceTitle(candidateID))
                    }
                }
                if Set(notesOptions.map(\.value)).count > 1 {
                    Picker(L10n.t("ios_sync_conflict_notes_source"), selection: $selectedNotesCandidateID) {
                        Text(L10n.t("ios_sync_conflict_choose_source")).tag("")
                        ForEach(notesOptions) { option in
                            Text(sourceTitle(option.candidateID)).tag(option.candidateID)
                        }
                    }
                    .pickerStyle(.menu)
                }
                if let compositionError {
                    Text(compositionError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                Button(L10n.t("ios_sync_conflict_compose_apply")) {
                    showingCompositionConfirmation = true
                }
                .disabled(
                    resolvingCandidateID != nil
                        || !compositionSelectionIsComplete(groups, notesOptions: notesOptions))
            }
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
            return L10n.t("ios_sync_conflict_unknown_device")
        }
        return sourceTitle(candidate)
    }

    private func sourceTitle(_ candidate: RelayClient.ConflictCandidate) -> String {
        "\(IOSConflictCandidateView.source(candidate)) · \(candidate.committedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    private func fieldSourceTitle(_ option: ConflictComposer.FieldOption) -> String {
        let suffix = option.field == nil ? " · \(L10n.t("ios_sync_conflict_field_removed"))" : ""
        return sourceTitle(option.candidateID) + suffix
    }

    private func resolveComposition() async {
        guard resolvingCandidateID == nil, !selectedBaseCandidateID.isEmpty else { return }
        resolvingCandidateID = selectedBaseCandidateID
        compositionError = nil
        defer { resolvingCandidateID = nil }
        do {
            try await vault.resolveSyncConflict(
                conflict,
                candidateID: selectedBaseCandidateID,
                fieldSelections: selectedFieldSources,
                notesCandidateID: selectedNotesCandidateID.isEmpty ? nil : selectedNotesCandidateID)
            onResolved()
            dismiss()
        } catch {
            Log.error(
                "sync",
                "ios conflict composition failed for \(conflict.itemUUID.uuidString.prefix(8)): \(error)")
            compositionError = error.localizedDescription
            let latest = try? await vault.syncConflicts()
            if let refreshed = latest?.first(where: { $0.conflictID == conflict.conflictID }) {
                conflict = refreshed
                compositionError = L10n.t("ios_sync_conflict_refreshed")
            } else if latest != nil {
                dismiss()
            }
            onResolved()
        }
    }

    private func refreshCandidateSet() async {
        do {
            let latest = try await vault.syncConflicts()
            guard let refreshed = latest.first(where: { $0.conflictID == conflict.conflictID }) else {
                errorMessage = L10n.t("sync_conflict_already_resolved")
                return
            }
            conflict = refreshed
            errorMessage = nil
            Log.info("sync", "ios conflict candidate set refreshed id=\(conflict.conflictID)")
        } catch {
            errorMessage = error.localizedDescription
            Log.error("sync", "ios conflict candidate refresh failed: \(error)")
        }
    }

    private static func decodeCandidates(
        _ conflict: RelayClient.ConflictRecord,
        key: SymmetricKey?
    ) -> [ConflictComposer.Candidate] {
        guard conflict.currentDeletedSequence == 0, let key else { return [] }
        return conflict.candidates.compactMap { candidate in
            guard !candidate.isDelete,
                  let item = IOSSyncConflictSection.decode(candidate, conflict: conflict, key: key) else {
                return nil
            }
            return ConflictComposer.Candidate(candidateID: candidate.candidateID, item: item)
        }
    }
}

private struct IOSConflictCandidateView: View {
    let candidate: RelayClient.ConflictCandidate
    let conflict: RelayClient.ConflictRecord
    let key: SymmetricKey?
    let isResolving: Bool
    let choose: () -> Void
    let retry: () -> Void
    let saveAsNew: () async throws -> Void
    @State private var revealSensitive = false
    @State private var copyError: String?
    @State private var copying = false

    private var item: DatabaseItem? {
        guard let key else { return nil }
        return IOSSyncConflictSection.decode(candidate, conflict: conflict, key: key)
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(candidate.isDelete ? L10n.t("ios_sync_conflict_deleted_version") : title)
                            .font(.headline)
                        Text(Self.source(candidate))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(candidate.committedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if candidate.isDelete {
                        Image(systemName: "trash.fill").foregroundStyle(Brand.red)
                    }
                }

                if candidate.isDelete {
                    Text(L10n.t("ios_sync_conflict_delete_explanation"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if let item {
                    itemDetails(item)
                } else {
                    HStack {
                        Label(L10n.t("ios_sync_conflict_unreadable_candidate"), systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(Brand.red)
                        Spacer()
                        Button(action: retry) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(L10n.t("ios_sync_conflict_candidate_retry"))
                    }
                }

                HStack {
                    Button(action: choose) {
                        if isResolving {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text(candidate.isDelete
                                 ? L10n.t("ios_sync_conflict_keep_deleted")
                                 : conflict.currentDeletedSequence > 0
                                    ? L10n.t("ios_sync_conflict_restore_version")
                                    : L10n.t("ios_sync_conflict_keep_version"))
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isResolving || (!candidate.isDelete && item == nil))

                    if canSaveAsNew {
                        Button {
                            copying = true
                            Task {
                                defer { copying = false }
                                do {
                                    try await saveAsNew()
                                    copyError = nil
                                } catch {
                                    copyError = error.localizedDescription
                                    Log.error("sync", "ios conflict candidate copy failed: \(error)")
                                }
                            }
                        } label: {
                            if copying {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "doc.on.doc")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isResolving || copying)
                        .accessibilityLabel(L10n.t("ios_sync_conflict_copy_as_new"))
                    }
                }

                if let copyError {
                    Text(copyError)
                        .font(.footnote)
                        .foregroundStyle(Brand.red)
                }
            }
            .padding(.vertical, 2)
        } header: {
            EmptyView()
        }
    }

    @ViewBuilder
    private func itemDetails(_ item: DatabaseItem) -> some View {
        switch item {
        case .card(let card):
            fieldList(card.fields, notes: card.notes, attachmentCount: card.images.count + card.files.count)
        case .userProfile(let profile):
            fieldList(profile.fields, notes: "", attachmentCount: 0)
        case .label(let label):
            Text(label.name).font(.body)
        }
    }

    private func fieldList(_ fields: [Field], notes: String, attachmentCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(fields) { field in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(field.name.isEmpty ? field.type.localizedName : field.name)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text(field.type.isHidden && !revealSensitive
                         ? String(repeating: "•", count: max(4, min(field.value.count, 12)))
                         : field.value.isEmpty ? L10n.t("ios_sync_conflict_empty_value") : field.value)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                .font(.footnote)
            }
            if !notes.isEmpty {
                DisclosureGroup(L10n.t("notes_prompt")) {
                    Text(revealSensitive ? notes : "••••••••")
                        .font(.footnote)
                        .textSelection(.enabled)
                }
                .font(.footnote)
            }
            if attachmentCount > 0 {
                Label(String(format: L10n.t("ios_sync_conflict_attachments_fmt"), attachmentCount), systemImage: "paperclip")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if fields.contains(where: { $0.type.isHidden }) || !notes.isEmpty {
                Button {
                    revealSensitive.toggle()
                } label: {
                    Label(
                        revealSensitive ? L10n.t("ios_sync_conflict_hide_values") : L10n.t("ios_sync_conflict_reveal_values"),
                        systemImage: revealSensitive ? "eye.slash" : "eye"
                    )
                    .font(.caption)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private var title: String {
        switch item {
        case .card(let card): return card.title
        case .label(let label): return label.name
        case .userProfile: return L10n.t("ios_personal_info_title")
        case nil: return L10n.t("ios_sync_conflict_item")
        }
    }

    private var canSaveAsNew: Bool {
        guard !candidate.isDelete, case .card(let card) = item,
              !card.template, !card.trashed else { return false }
        return true
    }

    fileprivate static func source(_ candidate: RelayClient.ConflictCandidate) -> String {
        let device = candidate.deviceName.isEmpty
            ? L10n.t("ios_sync_conflict_unknown_device") : candidate.deviceName
        let platform: String
        switch candidate.platform {
        case "ios": platform = "iOS"
        case "macos": platform = "macOS"
        case "ext-safari": platform = "Safari"
        case "ext-chrome": platform = "Chrome"
        case "ext-edge": platform = "Edge"
        case "ext-firefox": platform = "Firefox"
        case "": platform = L10n.t("ios_sync_conflict_unknown_device")
        default: platform = candidate.platform
        }
        return "\(device) · \(platform)"
    }
}
