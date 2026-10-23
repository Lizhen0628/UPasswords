import Foundation

/// Personal information stored independently from password cards inside the encrypted vault.
public struct UserProfile: Codable, Equatable, Identifiable {
    public init(id: UUID = UUID()) {
        self.id = id
    }

    public var id: UUID
    public var fields: [Field] = []
    public var registrationAutofillEnabled = true
    public var created: TimeInterval = 0
    public var modified: TimeInterval = 0
}

extension PasswordDatabase {
    /// Moves contact cards created by the initial onboarding implementation into profile records.
    /// Identity is retained so row sync can atomically replace the old encrypted row.
    /// - Returns: Number of migrated records.
    @discardableResult
    public mutating func migrateLegacyPersonalInfo() -> Int {
        let legacy = cards.filter {
            $0.symbol == "person.text.rectangle.fill" && !$0.template && !$0.trashed
        }
        guard !legacy.isEmpty else { return 0 }
        let now = Date().millis
        for card in legacy {
            guard !userProfiles.contains(where: { $0.id == card.id }) else { continue }
            var profile = UserProfile(id: card.id)
            profile.fields = card.fields
            profile.registrationAutofillEnabled = card.autofillEnabled
            profile.created = card.created
            profile.modified = max(now, card.modified + 1)
            userProfiles.append(profile)
        }
        let ids = Set(legacy.map(\.id))
        cards.removeAll { ids.contains($0.id) }
        Log.info("db", "migrated personal information records count=\(legacy.count)")
        return legacy.count
    }
}
