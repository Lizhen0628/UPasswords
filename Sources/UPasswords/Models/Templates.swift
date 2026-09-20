import Foundation

/// The 15 built-in card templates, reproduced one-to-one from the original
/// `Resources/database.xml` (see ../PasswordsCodes/resources/templates-database.xml).
/// `@string/…` references are resolved through database.strings at access time.
enum Templates {
    struct Spec: Identifiable {
        let id: Int
        let titleKey: String
        let symbol: String?
        let autofill: Bool
        let fields: [(nameKey: String, type: FieldType, autofill: Autofill)]
    }

    static let all: [Spec] = [
        Spec(id: 101, titleKey: "credit_card_template", symbol: "credit_card", autofill: true, fields: [
            ("number_field", .number, .ccNumber),
            ("owner_field", .text, .ccName),
            ("expires_field", .expiry, .ccExp),
            ("cvv_field", .pin, .ccCsc),
            ("pin_field", .pin, .off),
            ("blocking_field", .phone, .off),
        ]),
        Spec(id: 102, titleKey: "web_account_template", symbol: "web_site", autofill: true, fields: [
            ("login_field", .login, .username),
            ("password_field", .password, .currentPassword),
            ("url_field", .website, .url),
            ("one_time_password_field", .oneTimePassword, .oneTimeCode),
        ]),
        Spec(id: 103, titleKey: "email_account_template", symbol: "email", autofill: true, fields: [
            ("email_field", .login, .username),
            ("password_field", .password, .currentPassword),
            ("url_field", .website, .url),
            ("one_time_password_field", .oneTimePassword, .oneTimeCode),
        ]),
        Spec(id: 104, titleKey: "login_password_template", symbol: "key", autofill: false, fields: [
            ("login_field", .login, .username),
            ("password_field", .password, .currentPassword),
        ]),
        Spec(id: 100, titleKey: "code_template", symbol: "lock", autofill: false, fields: [
            ("code_field", .password, .currentPassword),
        ]),
        Spec(id: 105, titleKey: "id_passport_template", symbol: "id", autofill: false, fields: [
            ("number_field", .number, .off),
            ("name_field", .text, .off),
            ("birthday_field", .date, .off),
            ("issued_field", .date, .off),
            ("expires_field", .expiry, .off),
        ]),
        Spec(id: 106, titleKey: "insurance_template", symbol: "insurance", autofill: false, fields: [
            ("number_field", .number, .off),
            ("expires_field", .expiry, .off),
            ("phone_field", .phone, .off),
        ]),
        Spec(id: 107, titleKey: "membership_template", symbol: "membership", autofill: true, fields: [
            ("number_field", .number, .off),
            ("login_field", .login, .username),
            ("password_field", .password, .currentPassword),
            ("url_field", .website, .url),
            ("phone_field", .phone, .off),
        ]),
        Spec(id: 108, titleKey: "bank_account_template", symbol: "bank", autofill: true, fields: [
            ("bank_field", .text, .off),
            ("holder_field", .text, .off),
            ("account_field", .number, .off),
            ("type_field", .text, .off),
            ("swift_field", .text, .off),
            ("iban_field", .text, .off),
            ("phone_field", .phone, .off),
            ("login_field", .login, .username),
            ("password_field", .password, .currentPassword),
            ("url_field", .website, .url),
        ]),
        Spec(id: 109, titleKey: "driving_license_template", symbol: "id", autofill: false, fields: [
            ("number_field", .text, .off),
            ("name_field", .text, .off),
            ("birthday_field", .date, .off),
            ("class_field", .text, .off),
            ("expires_field", .expiry, .off),
        ]),
        Spec(id: 110, titleKey: "social_security_template", symbol: "social_security", autofill: false, fields: [
            ("number_field", .text, .off),
            ("name_field", .text, .off),
        ]),
        Spec(id: 111, titleKey: "wifi_router_template", symbol: "router", autofill: false, fields: [
            ("network_field", .text, .off),
            ("ip_address_field", .number, .off),
            ("admin_password_field", .password, .off),
            ("wifi_password_field", .password, .currentPassword),
        ]),
        Spec(id: 112, titleKey: "internet_provider_template", symbol: "network", autofill: true, fields: [
            ("protocol_field", .text, .off),
            ("login_field", .login, .username),
            ("password_field", .password, .currentPassword),
            ("dns_field", .number, .off),
            ("dns_2_field", .number, .off),
            ("url_field", .website, .url),
        ]),
        Spec(id: 113, titleKey: "software_license_template", symbol: "cd", autofill: true, fields: [
            ("email_field", .login, .username),
            ("password_field", .password, .currentPassword),
            ("key_field", .text, .off),
            ("url_field", .website, .url),
        ]),
        Spec(id: 120, titleKey: "totp_template", symbol: "key", autofill: true, fields: [
            ("one_time_password_field", .oneTimePassword, .oneTimeCode),
            ("url_field", .website, .url),
        ]),
        Spec(id: 114, titleKey: "custom_template", symbol: nil, autofill: false, fields: []),
    ]

    static func spec(id: Int) -> Spec? { all.first { $0.id == id } }

    static var defaultLabelKeys: [(nameKey: String, id: Int, type: String?)] = [
        ("busines_label", 1, nil),
        ("private_label", 2, nil),
        ("web_accounts_label", 4, "web_accounts"),
    ]

    /// Instantiates a card from a template spec (template=false — a real card).
    static func makeCard(from spec: Spec, id: Int, now: Date = Date()) -> Card {
        var card = Card(id: id)
        card.title = L10n.db(spec.titleKey)
        card.symbol = spec.symbol
        card.color = "gray"
        card.autofillEnabled = spec.autofill
        card.created = now.millis
        card.modified = now.millis
        card.fields = spec.fields.map {
            Field(name: L10n.db($0.nameKey), type: $0.type, value: "", autofill: $0.autofill)
        }
        return card
    }

    /// A template card instance (template=true) stored inside the database.
    static func makeTemplateCard(_ spec: Spec) -> Card {
        var c = makeCard(from: spec, id: spec.id)
        c.template = true
        return c
    }

    static let templateIds: Set<Int> = Set(all.map(\.id))
}

extension Date {
    var millis: TimeInterval { timeIntervalSince1970 * 1000 }
}

extension TimeInterval {
    var date: Date { Date(timeIntervalSince1970: self / 1000) }
}
