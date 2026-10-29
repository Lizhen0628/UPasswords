import Foundation

import UPasswordsCore

/// Composes a new encrypted-row plaintext from explicitly selected conflict fields.
public enum ConflictComposer {
    /// One authenticated, decrypted conflict candidate.
    public struct Candidate: Equatable, Identifiable {
        public let candidateID: String
        public var id: String { candidateID }
        public let item: DatabaseItem

        /// Creates a candidate for in-memory conflict review.
        public init(candidateID: String, item: DatabaseItem) {
            self.candidateID = candidateID
            self.item = item
        }
    }

    /// The option supplied by one candidate for a stable field identity.
    public struct FieldOption: Equatable, Identifiable {
        public let candidateID: String
        public var id: String { candidateID }
        public let field: Field?
    }

    /// Candidate options for one persistent field UUID.
    public struct FieldGroup: Equatable, Identifiable {
        public let fieldID: UUID
        public var id: UUID { fieldID }
        public let title: String
        public let options: [FieldOption]
        public let requiresChoice: Bool
        public let defaultCandidateID: String?
    }

    /// A candidate's notes value, for explicit whole-note selection.
    public struct NotesOption: Equatable, Identifiable {
        public let candidateID: String
        public var id: String { candidateID }
        public let value: String
    }

    /// Returns field groups only when every candidate has a compatible, reliable shape.
    public static func fieldGroups(for candidates: [Candidate]) -> [FieldGroup]? {
        guard isComposable(candidates) else {
            return nil
        }
        let fieldSets = candidates.compactMap { fields(in: $0.item) }
        guard fieldSets.count == candidates.count else { return nil }
        let fieldIDs = Set(fieldSets.flatMap { $0.map(\.id) })
        return fieldIDs.sorted { $0.uuidString < $1.uuidString }.compactMap { fieldID in
            let options = zip(candidates, fieldSets).map { candidate, fields in
                FieldOption(candidateID: candidate.candidateID, field: fields.first { $0.id == fieldID })
            }
            let variants = options.reduce(into: [Field?]()) { result, option in
                if !result.contains(where: { $0 == option.field }) {
                    result.append(option.field)
                }
            }
            guard let representative = options.compactMap(\.field).first else { return nil }
            let requiresChoice = variants.count > 1
            return FieldGroup(
                fieldID: fieldID,
                title: representative.name.isEmpty ? representative.type.localizedName : representative.name,
                options: options,
                requiresChoice: requiresChoice,
                defaultCandidateID: requiresChoice ? nil : options.first?.candidateID)
        }
    }

    /// Candidate notes variants. A non-nil result means the item type is composable.
    public static func notesOptions(for candidates: [Candidate]) -> [NotesOption]? {
        guard isComposable(candidates) else { return nil }
        switch candidates.first?.item {
        case .card:
            return candidates.compactMap { candidate in
                guard case .card(let card) = candidate.item else { return nil }
                return NotesOption(candidateID: candidate.candidateID, value: card.notes)
            }
        case .userProfile:
            return []
        case .label, nil:
            return nil
        }
    }

    /// Combines selected field versions over one explicitly chosen candidate's item metadata.
    ///
    /// - Parameters:
    ///   - baseCandidateID: Candidate supplying non-field metadata and field display order.
    ///   - candidates: All authenticated upsert candidates in the current conflict set.
    ///   - fieldSelections: Field UUID to source candidate; omitted only for identical variants.
    ///   - notesCandidateID: Source candidate when card notes differ.
    /// - Returns: Composed item, or nil when the selection is incomplete or unsafe.
    public static func compose(
        baseCandidateID: String,
        candidates: [Candidate],
        fieldSelections: [UUID: String],
        notesCandidateID: String? = nil
    ) -> DatabaseItem? {
        guard let baseCandidate = candidates.first(where: { $0.candidateID == baseCandidateID }),
              let groups = fieldGroups(for: candidates),
              let baseFields = fields(in: baseCandidate.item) else {
            return nil
        }

        var chosenFields: [UUID: Field] = [:]
        for group in groups {
            let selectedCandidateID: String?
            if group.requiresChoice {
                selectedCandidateID = fieldSelections[group.fieldID]
            } else {
                selectedCandidateID = group.defaultCandidateID
            }
            guard let selectedCandidateID,
                  let option = group.options.first(where: { $0.candidateID == selectedCandidateID }) else {
                return nil
            }
            if let field = option.field {
                chosenFields[group.fieldID] = field
            }
        }

        let orderedFields = ordered(chosenFields, baseFields: baseFields, groups: groups)
        let chosenNotes = notesValue(
            candidates: candidates,
            notesCandidateID: notesCandidateID)
        guard chosenNotes.isValid else { return nil }
        let now = Date().millis

        switch baseCandidate.item {
        case .card(var card):
            guard case .value(let notes) = chosenNotes else { return nil }
            card.fields = orderedFields
            card.notes = notes
            card.modified = max(now, card.modified + 1)
            return .card(card)
        case .userProfile(var profile):
            guard case .notApplicable = chosenNotes else { return nil }
            profile.fields = orderedFields
            profile.modified = max(now, profile.modified + 1)
            return .userProfile(profile)
        case .label:
            return nil
        }
    }

    /// Whether a candidate set can be safely composed by persistent field identity.
    public static func isComposable(_ candidates: [Candidate]) -> Bool {
        guard candidates.count >= 2,
              Set(candidates.map(\.candidateID)).count == candidates.count,
              let first = candidates.first,
              candidates.allSatisfy({ $0.item.uuid == first.item.uuid && $0.item.syncKind == first.item.syncKind }) else {
            return false
        }
        return candidates.allSatisfy { fields(in: $0.item) != nil }
    }

    private enum NotesValue {
        case value(String)
        case notApplicable
        case invalid

        var isValid: Bool {
            switch self {
            case .invalid: return false
            case .value, .notApplicable: return true
            }
        }
    }

    private static func fields(in item: DatabaseItem) -> [Field]? {
        let fields: [Field]
        switch item {
        case .card(let card):
            guard card.images.isEmpty, card.files.isEmpty else { return nil }
            fields = card.fields
        case .userProfile(let profile):
            fields = profile.fields
        case .label:
            return nil
        }
        guard fields.allSatisfy(\.hasPersistentID),
              Set(fields.map(\.id)).count == fields.count else {
            return nil
        }
        return fields
    }

    private static func notesValue(
        candidates: [Candidate],
        notesCandidateID: String?
    ) -> NotesValue {
        guard let first = candidates.first else { return .invalid }
        switch first.item {
        case .card:
            let options = candidates.compactMap { candidate -> NotesOption? in
                guard case .card(let card) = candidate.item else { return nil }
                return NotesOption(candidateID: candidate.candidateID, value: card.notes)
            }
            guard options.count == candidates.count else { return .invalid }
            let values = Set(options.map(\.value))
            if values.count == 1, let value = options.first?.value {
                return .value(value)
            }
            guard let notesCandidateID,
                  let selected = options.first(where: { $0.candidateID == notesCandidateID }) else {
                return .invalid
            }
            return .value(selected.value)
        case .userProfile:
            return notesCandidateID == nil ? .notApplicable : .invalid
        case .label:
            return .invalid
        }
    }

    private static func ordered(
        _ fields: [UUID: Field],
        baseFields: [Field],
        groups: [FieldGroup]
    ) -> [Field] {
        var result: [Field] = []
        var appended = Set<UUID>()
        for field in baseFields {
            guard let selected = fields[field.id], appended.insert(field.id).inserted else { continue }
            result.append(selected)
        }
        for group in groups where appended.insert(group.fieldID).inserted {
            if let selected = fields[group.fieldID] {
                result.append(selected)
            }
        }
        return result
    }
}
