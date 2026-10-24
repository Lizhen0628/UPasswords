import Foundation

/// Personal information stored independently from password cards inside the encrypted vault.
public struct UserProfile: Codable, Equatable, Identifiable {
    /// 创建空的独立个人资料记录。
    ///
    /// - Parameter id: 跨端稳定 UUID；首次创建默认生成，迁移时可沿用旧卡片身份。
    public init(id: UUID = UUID()) {
        self.id = id
    }

    /// 独立资料记录的稳定 UUID；迁移时沿用原联系卡身份。
    public var id: UUID
    /// 个人资料的明文字段，随密码库加密。
    public var fields: [Field] = []
    /// 是否允许将此资料提供给注册表单自动填充。
    public var registrationAutofillEnabled = true
    /// 创建时间，使用 Unix 毫秒时间戳。
    public var created: TimeInterval = 0
    /// 最后修改时间，使用 Unix 毫秒时间戳，参与同步冲突裁决。
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
