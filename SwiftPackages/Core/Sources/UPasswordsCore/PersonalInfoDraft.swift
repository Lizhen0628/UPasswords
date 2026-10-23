import Foundation

/// Contact details collected during onboarding, kept in memory until a vault is ready.
public struct PersonalInfoDraft {
    public init() {}

    public var givenName = ""
    public var familyName = ""
    public var email = ""
    public var phone = ""
    public var addressLine1 = ""
    public var addressLine2 = ""
    public var city = ""
    public var region = ""
    public var postalCode = ""
    public var country = ""

    /// Loads an existing profile into the editing form.
    /// - Parameter profile: Decrypted profile, or nil for an empty form.
    public init(profile: UserProfile?) {
        let fields = profile?.fields ?? []
        givenName = fields.first { $0.autofill == .givenName }?.value ?? ""
        familyName = fields.first { $0.autofill == .familyName }?.value ?? ""
        email = fields.first { $0.autofill == .email }?.value ?? ""
        phone = fields.first { $0.autofill == .telephone }?.value ?? ""
        addressLine1 = fields.first { $0.autofill == .addressLine1 }?.value ?? ""
        addressLine2 = fields.first { $0.autofill == .addressLine2 }?.value ?? ""
        city = fields.first { $0.autofill == .addressLevel2 }?.value ?? ""
        region = fields.first { $0.autofill == .addressLevel1 }?.value ?? ""
        postalCode = fields.first { $0.autofill == .postalCode }?.value ?? ""
        country = fields.first { $0.autofill == .countryName }?.value ?? ""
    }

    /// Creates a profile with nonempty fields and standard HTML autocomplete tokens.
    /// - Parameters:
    ///   - autofillEnabled: Whether registration forms should offer these details.
    ///   - previous: Existing record whose identity and additional fields must be preserved.
    /// - Returns: An independent profile record, or nil if all fields are blank.
    public func makeProfile(autofillEnabled: Bool, updating previous: UserProfile? = nil) -> UserProfile? {
        let values: [(String, String, Autofill)] = [
            ("personal_info_given_name", givenName, .givenName),
            ("personal_info_family_name", familyName, .familyName),
            ("personal_info_email", email, .email),
            ("personal_info_phone", phone, .telephone),
            ("personal_info_address_line_1", addressLine1, .addressLine1),
            ("personal_info_address_line_2", addressLine2, .addressLine2),
            ("personal_info_city", city, .addressLevel2),
            ("personal_info_region", region, .addressLevel1),
            ("personal_info_postal_code", postalCode, .postalCode),
            ("personal_info_country", country, .countryName),
        ]
        var fields = values.compactMap { key, rawValue, token -> Field? in
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            let type: FieldType
            switch token {
            case .email: type = .email
            case .telephone: type = .phone
            default: type = .text
            }
            if var field = previous?.fields.first(where: { $0.autofill == token }) {
                field.value = value
                return field
            }
            return Field(name: L10n.t(key), type: type, value: value, autofill: token)
        }
        guard !fields.isEmpty else { return nil }
        // Preserve fields outside this form, including additional values from migrated records.
        let editedIDs = Set(values.compactMap { _, _, token in
            previous?.fields.first { $0.autofill == token }?.id
        })
        fields.append(contentsOf: previous?.fields.filter { !editedIDs.contains($0.id) } ?? [])
        var profile = previous ?? UserProfile()
        let now = Date().millis
        profile.registrationAutofillEnabled = autofillEnabled
        if previous == nil { profile.created = now }
        profile.modified = max(now, (previous?.modified ?? 0) + 1)
        profile.fields = fields
        return profile
    }
}
