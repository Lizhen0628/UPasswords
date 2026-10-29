import CryptoKit
import Foundation
import UPasswordsCore

/// One encrypted common ancestor for a synchronized row, without duplicating attachment bytes.
struct RowSyncBaseline: Codable, Equatable {
    private struct FieldSnapshot: Codable, Equatable {
        let id: UUID?
        let name: String
        let type: FieldType
        let value: String
        let autofill: Autofill
        let history: [HistoryEntry]

        init(_ field: Field) {
            id = field.hasPersistentID ? field.id : nil
            name = field.name
            type = field.type
            value = field.value
            autofill = field.autofill
            history = field.history
        }
    }

    private struct AttachmentFingerprint: Codable, Equatable {
        let id: UUID?
        let contentVersion: UUID?
        let name: String
        let sha256: String?

        init(_ attachment: Attachment) {
            id = attachment.hasPersistentID ? attachment.id : nil
            contentVersion = attachment.hasPersistentContentVersion ? attachment.contentVersion : nil
            name = attachment.name
            sha256 = attachment.data.map(SyncConflict.sha256Hex)
        }

        var isValid: Bool {
            guard let sha256 else { return id != nil && contentVersion != nil }
            return sha256.isValidSHA256
        }

        func matches(_ other: AttachmentFingerprint) -> Bool {
            guard id == other.id, contentVersion == other.contentVersion, name == other.name else {
                return false
            }
            if sha256 == nil || other.sha256 == nil {
                return id != nil && contentVersion != nil
            }
            guard let sha256, let otherSHA256 = other.sha256 else { return true }
            return sha256 == otherSHA256
        }
    }

    private struct LabelSnapshot: Codable, Equatable {
        let id: UUID
        let name: String
        let color: String?
        let type: String?
        let pinToTop: Bool
        let timeStamp: TimeInterval

        init(_ label: CardLabel) {
            id = label.id
            name = label.name
            color = label.color
            type = label.type
            pinToTop = label.pinToTop
            timeStamp = 0
        }

        private enum CodingKeys: String, CodingKey {
            case id, name, color, type, pinToTop, timeStamp
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            color = try container.decodeIfPresent(String.self, forKey: .color)
            type = try container.decodeIfPresent(String.self, forKey: .type)
            pinToTop = try container.decodeIfPresent(Bool.self, forKey: .pinToTop) ?? false
            timeStamp = 0
        }
    }

    private struct CardSnapshot: Codable, Equatable {
        let card: Card
        let fields: [FieldSnapshot]
        let images: [AttachmentFingerprint]
        let files: [AttachmentFingerprint]
        let iconDataSHA256: String?

        init(_ source: Card) {
            var card = source
            fields = source.fields.map(FieldSnapshot.init)
            images = source.images.map(AttachmentFingerprint.init)
            files = source.files.map(AttachmentFingerprint.init)
            iconDataSHA256 = source.iconData.map(SyncConflict.sha256Hex)
            card.modified = 0
            card.fields = []
            card.images = []
            card.files = []
            card.iconData = nil
            self.card = card
        }

        private enum CodingKeys: String, CodingKey {
            case card, fields, images, files, iconDataSHA256
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            var card = try container.decode(Card.self, forKey: .card)
            fields = try container.decodeIfPresent([FieldSnapshot].self, forKey: .fields)
                ?? card.fields.map(FieldSnapshot.init)
            card.fields = []
            self.card = card
            images = try container.decode([AttachmentFingerprint].self, forKey: .images)
            files = try container.decode([AttachmentFingerprint].self, forKey: .files)
            iconDataSHA256 = try container.decodeIfPresent(String.self, forKey: .iconDataSHA256)
        }

        var isValid: Bool {
            let imageIDs = images.compactMap(\.id)
            let fileIDs = files.compactMap(\.id)
            let attachmentIDs = imageIDs + fileIDs
            let hasUniqueIDs = Set(fields.compactMap(\.id)).count == fields.compactMap(\.id).count
                && Set(attachmentIDs).count == attachmentIDs.count
            return hasUniqueIDs && images.allSatisfy(\.isValid) && files.allSatisfy(\.isValid)
                && (iconDataSHA256 == nil || iconDataSHA256?.isValidSHA256 == true)
        }

        func matches(_ other: CardSnapshot) -> Bool {
            card == other.card && fields == other.fields
                && fingerprintsMatch(images, other.images)
                && fingerprintsMatch(files, other.files)
                && iconDataSHA256 == other.iconDataSHA256
        }

        private func fingerprintsMatch(
            _ lhs: [AttachmentFingerprint],
            _ rhs: [AttachmentFingerprint]
        ) -> Bool {
            lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { pair in
                pair.0.matches(pair.1)
            }
        }
    }

    private struct UserProfileSnapshot: Codable, Equatable {
        let profile: UserProfile
        let fields: [FieldSnapshot]

        init(_ source: UserProfile) {
            var profile = source
            fields = source.fields.map(FieldSnapshot.init)
            profile.modified = 0
            profile.fields = []
            self.profile = profile
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(profile, forKey: .profile)
            try container.encode(fields, forKey: .fields)
        }

        var isValid: Bool {
            let fieldIDs = fields.compactMap(\.id)
            return Set(fieldIDs).count == fieldIDs.count
        }

        private enum CodingKeys: String, CodingKey {
            case profile, fields, id, registrationAutofillEnabled, created, modified
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if container.contains(.profile) {
                var profile = try container.decode(UserProfile.self, forKey: .profile)
                fields = try container.decode([FieldSnapshot].self, forKey: .fields)
                profile.fields = []
                self.profile = profile
                return
            }

            let decodedFields = try container.decode([Field].self, forKey: .fields)
            fields = decodedFields.map(FieldSnapshot.init)
            var profile = UserProfile(id: try container.decode(UUID.self, forKey: .id))
            profile.registrationAutofillEnabled = try container.decode(
                Bool.self, forKey: .registrationAutofillEnabled)
            profile.created = try container.decode(TimeInterval.self, forKey: .created)
            profile.modified = try container.decode(TimeInterval.self, forKey: .modified)
            profile.fields = []
            self.profile = profile
        }
    }

    private let formatVersion: Int
    private let uuid: UUID
    private let kind: UInt8
    private let card: CardSnapshot?
    private let label: LabelSnapshot?
    private let userProfile: UserProfileSnapshot?

    var syncKind: UInt8 { kind }

    init(item: DatabaseItem) {
        formatVersion = 1
        uuid = item.uuid
        kind = item.syncKind
        switch item {
        case .card(let value):
            card = CardSnapshot(value)
            label = nil
            userProfile = nil
        case .label(let value):
            card = nil
            label = LabelSnapshot(value)
            userProfile = nil
        case .userProfile(let value):
            card = nil
            label = nil
            userProfile = UserProfileSnapshot(value)
        }
    }

    func matches(_ item: DatabaseItem) -> Bool {
        let current = RowSyncBaseline(item: item)
        guard uuid == current.uuid, kind == current.kind, formatVersion == current.formatVersion else {
            return false
        }
        switch (card, current.card, label, current.label, userProfile, current.userProfile) {
        case let (.some(base), .some(value), nil, nil, nil, nil):
            return base.matches(value)
        case let (nil, nil, .some(base), .some(value), nil, nil):
            return base == value
        case let (nil, nil, nil, nil, .some(base), .some(value)):
            return base == value
        default:
            return false
        }
    }

    /// Merges independent changes against this authenticated common ancestor.
    func merging(local: DatabaseItem, remote: DatabaseItem) -> DatabaseItem? {
        guard local.uuid == uuid, remote.uuid == uuid,
              local.syncKind == kind, remote.syncKind == kind else { return nil }
        switch (self.card, local, remote) {
        case let (base?, .card(local), .card(remote)):
            return mergeCard(base: base, local: local, remote: remote).map(DatabaseItem.card)
        case let (nil, .label(local), .label(remote)):
            guard let base = label,
                  let merged = mergeLabel(base: base, local: local, remote: remote) else { return nil }
            return .label(merged)
        case let (nil, .userProfile(local), .userProfile(remote)):
            guard let base = userProfile,
                  let merged = mergeProfile(base: base, local: local, remote: remote) else { return nil }
            return .userProfile(merged)
        default:
            return nil
        }
    }

    func isValid(uuid expectedUUID: UUID, kind expectedKind: UInt8) -> Bool {
        guard formatVersion == 1, uuid == expectedUUID, kind == expectedKind else { return false }
        switch kind {
        case 1:
            return card?.card.id == uuid && card?.isValid == true && label == nil && userProfile == nil
        case 2:
            return card == nil && label?.id == uuid && userProfile == nil
        case 3:
            return card == nil && label == nil && userProfile?.profile.id == uuid
                && userProfile?.isValid == true
        default:
            return false
        }
    }

    private enum MergeChoice<Value> {
        case value(Value)
        case removed
        case conflict
    }

    private func mergeCard(base: CardSnapshot, local: Card, remote: Card) -> Card? {
        guard case let .value(title) = mergeValue(base.card.title, local.title, remote.title),
              case let .value(symbol) = mergeValue(base.card.symbol, local.symbol, remote.symbol),
              case let .value(color) = mergeValue(base.card.color, local.color, remote.color),
              case let .value(customIconName) = mergeValue(
                base.card.customIconName, local.customIconName, remote.customIconName),
              case let .value(template) = mergeValue(base.card.template, local.template, remote.template),
              case let .value(autofillEnabled) = mergeValue(
                base.card.autofillEnabled, local.autofillEnabled, remote.autofillEnabled),
              case let .value(favorite) = mergeValue(base.card.favorite, local.favorite, remote.favorite),
              case let .value(archived) = mergeValue(base.card.archived, local.archived, remote.archived),
              case let .value(trashed) = mergeValue(base.card.trashed, local.trashed, remote.trashed),
              case let .value(expiration) = mergeValue(
                base.card.expiration, local.expiration, remote.expiration),
              case let .value(reminder) = mergeValue(base.card.reminder, local.reminder, remote.reminder),
              case let .value(created) = mergeValue(base.card.created, local.created, remote.created),
              case let .value(useWebsiteIcon) = mergeValue(
                base.card.useWebsiteIcon, local.useWebsiteIcon, remote.useWebsiteIcon),
              case let .value(watch) = mergeValue(base.card.watch, local.watch, remote.watch),
              case let .value(iconSource) = mergeValue(
                base.card.iconSource, local.iconSource, remote.iconSource),
              case let .value(notes) = mergeValue(base.card.notes, local.notes, remote.notes),
              case let .value(labelIDs) = mergeLabelIDs(
                base.card.labelIds, local.labelIds, remote.labelIds),
              case let .value(fields) = mergeFields(base.fields, local.fields, remote.fields),
              case let .value(images) = mergeAttachments(
                base.images, local.images, remote.images),
              case let .value(files) = mergeAttachments(base.files, local.files, remote.files),
              case let .value(iconData) = mergeIconData(
                base.iconDataSHA256, local.iconData, remote.iconData) else { return nil }

        var merged = local
        merged.title = title
        merged.symbol = symbol
        merged.color = color
        merged.customIconName = customIconName
        merged.template = template
        merged.autofillEnabled = autofillEnabled
        merged.favorite = favorite
        merged.archived = archived
        merged.trashed = trashed
        merged.expiration = expiration
        merged.reminder = reminder
        merged.created = created
        merged.useWebsiteIcon = useWebsiteIcon
        merged.watch = watch
        merged.iconSource = iconSource
        merged.iconData = iconData
        merged.notes = notes
        merged.labelIds = labelIDs
        merged.fields = fields
        merged.images = images
        merged.files = files
        return merged
    }

    private func mergeLabel(base: LabelSnapshot, local: CardLabel,
                            remote: CardLabel) -> CardLabel? {
        guard case let .value(name) = mergeValue(base.name, local.name, remote.name),
              case let .value(color) = mergeValue(base.color, local.color, remote.color),
              case let .value(type) = mergeValue(base.type, local.type, remote.type),
              case let .value(pinToTop) = mergeValue(base.pinToTop, local.pinToTop, remote.pinToTop)
        else { return nil }
        var merged = local
        merged.name = name
        merged.color = color
        merged.type = type
        merged.pinToTop = pinToTop
        return merged
    }

    private func mergeProfile(base: UserProfileSnapshot, local: UserProfile,
                              remote: UserProfile) -> UserProfile? {
        guard case let .value(registrationAutofillEnabled) = mergeValue(
            base.profile.registrationAutofillEnabled,
            local.registrationAutofillEnabled,
            remote.registrationAutofillEnabled),
              case let .value(created) = mergeValue(
                base.profile.created, local.created, remote.created),
              case let .value(fields) = mergeFields(base.fields, local.fields, remote.fields)
        else { return nil }
        var merged = local
        merged.registrationAutofillEnabled = registrationAutofillEnabled
        merged.created = created
        merged.fields = fields
        return merged
    }

    private func mergeFields(_ base: [FieldSnapshot], _ local: [Field],
                             _ remote: [Field]) -> MergeChoice<[Field]> {
        let localSnapshots = local.map(FieldSnapshot.init)
        let remoteSnapshots = remote.map(FieldSnapshot.init)
        let hasStableIDs = base.allSatisfy { $0.id != nil }
            && local.allSatisfy(\.hasPersistentID) && remote.allSatisfy(\.hasPersistentID)
        guard hasStableIDs else {
            if localSnapshots == remoteSnapshots { return .value(local) }
            if localSnapshots == base { return .value(remote) }
            if remoteSnapshots == base { return .value(local) }
            return .conflict
        }
        guard let baseByID = uniqueDictionary(base, id: { $0.id }),
              let localByID = uniqueDictionary(local, id: { $0.id }),
              let remoteByID = uniqueDictionary(remote, id: { $0.id }) else { return .conflict }

        let baseOrder = base.compactMap(\.id)
        let localOrder = local.map(\.id)
        let remoteOrder = remote.map(\.id)
        var mergedByID: [UUID: Field] = [:]
        let allIDs = uniqueIDs(baseOrder + localOrder + remoteOrder)
        for id in allIDs {
            switch mergeField(base: baseByID[id], local: localByID[id], remote: remoteByID[id]) {
            case .value(let field): mergedByID[id] = field
            case .removed: break
            case .conflict: return .conflict
            }
        }
        guard let order = mergedOrder(
            base: baseOrder, local: localOrder, remote: remoteOrder,
            survivingIDs: Set(mergedByID.keys)) else { return .conflict }
        return .value(order.compactMap { mergedByID[$0] })
    }

    private func mergeField(base: FieldSnapshot?, local: Field?, remote: Field?) -> MergeChoice<Field> {
        switch (base, local, remote) {
        case let (nil, local?, nil): return .value(local)
        case let (nil, nil, remote?): return .value(remote)
        case let (nil, local?, remote?):
            return FieldSnapshot(local) == FieldSnapshot(remote) ? .value(local) : .conflict
        case (nil, nil, nil): return .removed
        case (.some(_), nil, nil): return .removed
        case let (base?, nil, remote?):
            return FieldSnapshot(remote) == base ? .removed : .conflict
        case let (base?, local?, nil):
            return FieldSnapshot(local) == base ? .removed : .conflict
        case let (base?, local?, remote?):
            guard case let .value(name) = mergeValue(base.name, local.name, remote.name),
                  case let .value(type) = mergeValue(base.type, local.type, remote.type),
                  case let .value(value) = mergeValue(base.value, local.value, remote.value),
                  case let .value(autofill) = mergeValue(base.autofill, local.autofill, remote.autofill),
                  case let .value(history) = mergeValue(base.history, local.history, remote.history)
            else { return .conflict }
            return .value(Field(
                id: local.id, name: name, type: type, value: value,
                autofill: autofill, history: history))
        }
    }

    private func mergeAttachments(_ base: [AttachmentFingerprint], _ local: [Attachment],
                                 _ remote: [Attachment]) -> MergeChoice<[Attachment]> {
        let localFingerprints = local.map(AttachmentFingerprint.init)
        let remoteFingerprints = remote.map(AttachmentFingerprint.init)
        let hasStableIDs = base.allSatisfy { $0.id != nil && $0.contentVersion != nil }
            && local.allSatisfy { $0.hasPersistentID && $0.hasPersistentContentVersion }
            && remote.allSatisfy { $0.hasPersistentID && $0.hasPersistentContentVersion }
        guard hasStableIDs else {
            if localFingerprints == remoteFingerprints { return .value(local) }
            if localFingerprints == base { return .value(remote) }
            if remoteFingerprints == base { return .value(local) }
            return .conflict
        }
        guard let baseByID = uniqueDictionary(base, id: { $0.id }),
              let localByID = uniqueDictionary(local, id: { $0.id }),
              let remoteByID = uniqueDictionary(remote, id: { $0.id }) else { return .conflict }

        let baseOrder = base.compactMap(\.id)
        let localOrder = local.map(\.id)
        let remoteOrder = remote.map(\.id)
        var mergedByID: [UUID: Attachment] = [:]
        let allIDs = uniqueIDs(baseOrder + localOrder + remoteOrder)
        for id in allIDs {
            switch mergeAttachment(
                base: baseByID[id], local: localByID[id], remote: remoteByID[id]) {
            case .value(let attachment): mergedByID[id] = attachment
            case .removed: break
            case .conflict: return .conflict
            }
        }
        guard let order = mergedOrder(
            base: baseOrder, local: localOrder, remote: remoteOrder,
            survivingIDs: Set(mergedByID.keys)) else { return .conflict }
        return .value(order.compactMap { mergedByID[$0] })
    }

    private func mergeAttachment(base: AttachmentFingerprint?, local: Attachment?,
                                 remote: Attachment?) -> MergeChoice<Attachment> {
        switch (base, local, remote) {
        case let (nil, local?, nil): return .value(local)
        case let (nil, nil, remote?): return .value(remote)
        case let (nil, local?, remote?):
            guard attachmentsRepresentSameContent(local, remote) else { return .conflict }
            return .value(Attachment(
                id: local.id, contentVersion: local.contentVersion,
                name: local.name, data: local.data ?? remote.data))
        case (nil, nil, nil): return .removed
        case (.some(_), nil, nil): return .removed
        case let (base?, nil, remote?):
            return base.matches(AttachmentFingerprint(remote)) ? .removed : .conflict
        case let (base?, local?, nil):
            return base.matches(AttachmentFingerprint(local)) ? .removed : .conflict
        case let (base?, local?, remote?):
            guard let baseVersion = base.contentVersion,
                  case let .value(name) = mergeValue(base.name, local.name, remote.name),
                  case let .value(contentVersion) = mergeValue(
                    baseVersion, local.contentVersion, remote.contentVersion),
                  attachmentsHaveConsistentBytes(local, remote, version: contentVersion)
            else { return .conflict }
            let source = local.contentVersion == contentVersion ? local : remote
            let data: Data?
            if local.contentVersion == contentVersion {
                data = local.data ?? (remote.contentVersion == contentVersion ? remote.data : nil)
            } else {
                data = remote.contentVersion == contentVersion ? remote.data : nil
            }
            return .value(Attachment(
                id: local.id, contentVersion: contentVersion, name: name, data: data ?? source.data))
        }
    }

    private func attachmentsRepresentSameContent(_ lhs: Attachment, _ rhs: Attachment) -> Bool {
        guard lhs.hasPersistentID, rhs.hasPersistentID,
              lhs.id == rhs.id,
              lhs.hasPersistentContentVersion, rhs.hasPersistentContentVersion,
              lhs.contentVersion == rhs.contentVersion,
              lhs.name == rhs.name else { return false }
        return attachmentsHaveConsistentBytes(lhs, rhs, version: lhs.contentVersion)
    }

    private func attachmentsHaveConsistentBytes(
        _ lhs: Attachment,
        _ rhs: Attachment,
        version: UUID
    ) -> Bool {
        guard lhs.contentVersion == version, rhs.contentVersion == version else { return true }
        guard let lhsData = lhs.data, let rhsData = rhs.data else { return true }
        return SyncConflict.sha256Hex(lhsData) == SyncConflict.sha256Hex(rhsData)
    }

    private func mergeIconData(_ base: String?, _ local: Data?,
                               _ remote: Data?) -> MergeChoice<Data?> {
        let localDigest = local.map(SyncConflict.sha256Hex)
        let remoteDigest = remote.map(SyncConflict.sha256Hex)
        switch mergeValue(base, localDigest, remoteDigest) {
        case .value(let digest):
            if digest == localDigest { return .value(local) }
            return .value(remote)
        case .conflict: return .conflict
        case .removed: return .conflict
        }
    }

    private func mergeLabelIDs(_ base: [UUID], _ local: [UUID],
                               _ remote: [UUID]) -> MergeChoice<[UUID]> {
        let baseSet = Set(base)
        let localSet = Set(local)
        let remoteSet = Set(remote)
        let allIDs = uniqueIDs(base + local + remote)
        var included = Set<UUID>()
        for id in allIDs {
            guard case let .value(shouldInclude) = mergeValue(
                baseSet.contains(id), localSet.contains(id), remoteSet.contains(id)) else {
                return .conflict
            }
            if shouldInclude { included.insert(id) }
        }
        let ordered = uniqueIDs(base + local + remote).filter { included.contains($0) }
        return .value(ordered)
    }

    private func mergeValue<Value: Equatable>(_ base: Value, _ local: Value,
                                              _ remote: Value) -> MergeChoice<Value> {
        if local == remote { return .value(local) }
        if local == base { return .value(remote) }
        if remote == base { return .value(local) }
        return .conflict
    }

    private func mergedOrder(base: [UUID], local: [UUID], remote: [UUID],
                             survivingIDs: Set<UUID>) -> [UUID]? {
        let baseSet = Set(base)
        let baseSurvivors = base.filter { survivingIDs.contains($0) }
        let localBaseOrder = local.filter { baseSet.contains($0) && survivingIDs.contains($0) }
        let remoteBaseOrder = remote.filter { baseSet.contains($0) && survivingIDs.contains($0) }
        let mergedBaseOrder: [UUID]
        if localBaseOrder == remoteBaseOrder {
            mergedBaseOrder = localBaseOrder
        } else if localBaseOrder == baseSurvivors {
            mergedBaseOrder = remoteBaseOrder
        } else if remoteBaseOrder == baseSurvivors {
            mergedBaseOrder = localBaseOrder
        } else {
            return nil
        }
        let additions = uniqueIDs(
            local.filter { !baseSet.contains($0) && survivingIDs.contains($0) }
                + remote.filter { !baseSet.contains($0) && survivingIDs.contains($0) })
        return mergedBaseOrder + additions
    }

    private func uniqueIDs(_ ids: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return ids.filter { seen.insert($0).inserted }
    }

    private func uniqueDictionary<Value, Key: Hashable>(
        _ values: [Value], id: (Value) -> Key?
    ) -> [Key: Value]? {
        var result: [Key: Value] = [:]
        for value in values {
            guard let key = id(value), result[key] == nil else { return nil }
            result[key] = value
        }
        return result
    }
}

private extension String {
    var isValidSHA256: Bool {
        count == 64 && allSatisfy { $0.isHexDigit }
    }
}
