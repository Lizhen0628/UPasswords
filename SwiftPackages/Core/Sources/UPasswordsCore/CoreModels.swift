import Foundation

/// The 12 field types of the database XML, plus the HTML-autofill token set.
public enum FieldType: String, CaseIterable, Codable, Identifiable {
    case login
    case password
    case pin
    case number
    case date
    case phone
    case website
    case email
    case oneTimePassword = "one_time_password"
    case text
    case expiry
    case secret

    public var id: String { rawValue }

    /// Localized type name (strings table `*_type`).
    public var localizedName: String {
        switch self {
        case .login: return L10n.db("login_type")
        case .password: return L10n.db("password_type")
        case .pin: return L10n.db("pin_type")
        case .number: return L10n.db("number_type")
        case .date: return L10n.db("date_type")
        case .phone: return L10n.db("phone_type")
        case .website: return L10n.db("website_type")
        case .email: return L10n.db("email_type")
        case .oneTimePassword: return L10n.db("one_time_password_type")
        case .text: return L10n.db("text_type")
        case .expiry: return L10n.db("expiry_type")
        case .secret: return L10n.db("secret_type")
        }
    }

    // Type predicates
    public var isHidden: Bool {
        switch self {
        case .password, .pin, .oneTimePassword, .secret: return true
        default: return false
        }
    }
    public var isOneTimePassword: Bool { self == .oneTimePassword }
    public var isLogin: Bool { self == .login || self == .email }
    public var isNumber: Bool { self == .number }
    public var isSearchable: Bool { self != .oneTimePassword }
    /// Password-like fields participate in weak/same/compromised analysis.
    public var needsScoring: Bool { self == .password }

    public var systemImage: String {
        switch self {
        case .login: return "person.crop.circle"
        case .password: return "lock.circle"
        case .pin: return "number.circle"
        case .number: return "number"
        case .date: return "calendar"
        case .phone: return "phone"
        case .website: return "safari"
        case .email: return "envelope"
        case .oneTimePassword: return "clock.badge.checkmark"
        case .text: return "textformat"
        case .expiry: return "hourglass"
        case .secret: return "key.slash"
        }
    }

    /// 编辑表单值输入框的占位提示(按字段类型给出针对性示例,替代千篇一律的「字段值:」)
    public var valuePlaceholder: String {
        switch self {
        case .login: return L10n.t("field_ph_login", fallback: "用户名或邮箱")
        case .password: return L10n.t("field_ph_password", fallback: "输入密码")
        case .pin: return L10n.t("field_ph_pin", fallback: "输入 PIN 码")
        case .number: return L10n.t("field_ph_number", fallback: "输入数字")
        case .date: return L10n.t("field_ph_date", fallback: "如 2026-01-01")
        case .phone: return L10n.t("field_ph_phone", fallback: "输入电话号码")
        case .website: return L10n.t("field_ph_website", fallback: "https://example.com")
        case .email: return L10n.t("field_ph_email", fallback: "name@example.com")
        case .oneTimePassword: return L10n.t("field_ph_otp", fallback: "粘贴 otpauth:// 链接或密钥")
        case .text: return L10n.t("field_ph_text", fallback: "输入内容")
        case .expiry: return L10n.t("field_ph_expiry", fallback: "如 2030-12-31")
        case .secret: return L10n.t("field_ph_secret", fallback: "输入机密内容")
        }
    }
}

/// HTML autocomplete-aligned tokens (XML `autofill` attribute).
public enum Autofill: String, CaseIterable, Codable, Identifiable {
    case off
    case username
    case currentPassword = "current-password"
    case url
    case oneTimeCode = "one-time-code"
    case ccNumber = "cc-number"
    case ccName = "cc-name"
    case ccExp = "cc-exp"
    case ccCsc = "cc-csc"

    public var id: String { rawValue }

    /// Localized autofill name (strings table `*_autofill`).
    public var localizedName: String {
        switch self {
        case .off: return L10n.db("off_autofill")
        case .username: return L10n.db("username_autofill")
        case .currentPassword: return L10n.db("password_autofill")
        case .url: return L10n.db("url_autofill")
        case .oneTimeCode: return L10n.db("one_time_code_autofill")
        case .ccNumber: return L10n.db("cc_number_autofill")
        case .ccName: return L10n.db("cc_name_autofill")
        case .ccExp: return L10n.db("cc_exp_autofill")
        case .ccCsc: return L10n.db("cc_csc_autofill")
        }
    }
}

/// A single field value change, kept per-field
/// (stored as JSON on the field: values + modification times).
public struct HistoryEntry: Codable, Equatable, Identifiable {
    public init(value: String, time: TimeInterval) {
        self.value = value
        self.time = time
    }

    public var value: String
    public var time: TimeInterval // millis since epoch
    public var id: TimeInterval { time }
}

/// A single named field on a card.
public struct Field: Codable, Equatable, Identifiable {
    public init(id: UUID = UUID(), name: String, type: FieldType = .text, value: String = "",
                autofill: Autofill = .off, history: [HistoryEntry] = []) {
        self.id = id
        self.name = name
        self.type = type
        self.value = value
        self.autofill = autofill
        self.history = history
    }

    public var id: UUID = UUID()
    public var name: String
    public var type: FieldType = .text
    public var value: String = ""
    public var autofill: Autofill = .off
    public var history: [HistoryEntry] = []

    public var hasValue: Bool { !value.isEmpty }
    public var hasHistory: Bool { !history.isEmpty }

    public mutating func putHistoryValue(_ v: String, time: TimeInterval) {
        guard !v.isEmpty, v != value else { return }
        history.removeAll { $0.value == v }
        history.append(HistoryEntry(value: v, time: time))
        if history.count > 20 { history.removeFirst(history.count - 20) }
    }
}

/// Attached binary payload (base64 in XML).
public struct Attachment: Codable, Equatable, Identifiable {
    public init(id: UUID = UUID(), name: String, data: Data) {
        self.id = id
        self.name = name
        self.data = data
    }

    public var id: UUID = UUID()
    public var name: String
    public var data: Data // decoded bytes; serialized base64 into XML

    public var length: Int { data.count }
}

/// A user label (`<label name id/>`).
public struct CardLabel: Codable, Equatable, Identifiable {
    public init(id: Int, name: String, color: String? = nil, type: String? = nil,
                pinToTop: Bool = false, timeStamp: TimeInterval = 0) {
        self.id = id
        self.name = name
        self.color = color
        self.type = type
        self.pinToTop = pinToTop
        self.timeStamp = timeStamp
    }

    public var id: Int
    public var name: String
    public var color: String? = nil
    public var type: String? = nil            // e.g. "web_accounts"
    public var pinToTop: Bool = false
    public var timeStamp: TimeInterval = 0    // millis

    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    public static func == (l: CardLabel, r: CardLabel) -> Bool { l.id == r.id }
}

/// Deletion tombstone used for convergent sync merges.
public struct Ghost: Codable, Equatable {
    public init(id: Int, time: TimeInterval) {
        self.id = id
        self.time = time
    }

    public var id: Int
    public var time: TimeInterval // millis
}

/// A card. Attribute names match the XML exchange format
/// (title/id/symbol/color/template/autofill/favorite/archived/
/// trashed/expiration/reminder/created/modified).
public struct Card: Codable, Equatable, Identifiable {
    public init(id: Int, title: String = "") {
        self.id = id
        self.title = title
    }

    public var id: Int
    public var title: String = ""
    public var symbol: String? = nil
    public var color: String? = nil
    public var customIconName: String? = nil
    public var template: Bool = false
    public var autofillEnabled: Bool = false          // card-level autofill="on|off"
    public var favorite: Bool = false                 // favorite="true"
    public var archived: Bool = false                 // archived="true"
    public var trashed: Bool = false                  // trashed="true"
    public var expiration: TimeInterval? = nil        // expiration millis
    public var reminder: TimeInterval? = nil          // reminder millis
    public var created: TimeInterval = 0              // created millis
    public var modified: TimeInterval = 0             // modified millis
    public var useWebsiteIcon: Bool = false
    public var watch: Bool = false                    // atWatch
    /// 图标来源词表（IconService 常量）：website / custom / url:<…> / builtin:<key>。
    /// nil = 未设置，走默认符号/颜色圆形图标。
    public var iconSource: String? = nil
    /// 图标像素数据（≤128×128 PNG，XML 里 base64 存 <icon> 元素）。
    /// builtin 来源不带数据（随 App 分发），其余来源均有数据。
    public var iconData: Data? = nil
    public var fields: [Field] = []
    public var notes: String = ""
    public var labelIds: [Int] = []
    public var images: [Attachment] = []
    public var files: [Attachment] = []

    // XCard derived accessors ---------------------------------------------
    public var isTemplate: Bool { template }

    public var loginField: Field? { fields.first { $0.type.isLogin } }
    public var passwordField: Field? { fields.first { $0.type == .password } }
    public var websiteField: Field? { fields.first { $0.type == .website } }

    public var login: String { loginField?.value ?? "" }
    public var password: String { passwordField?.value ?? "" }
    public var website: String { websiteField?.value ?? "" }
    public var hasNotes: Bool { !notes.isEmpty }
    public var hasImages: Bool { !images.isEmpty }
    public var hasFiles: Bool { !files.isEmpty }

    public static func days(fromMillis ms: TimeInterval, to date: Date = Date()) -> Int {
        let d = Date(timeIntervalSince1970: ms / 1000)
        return Calendar.current.dateComponents([.day], from: date, to: d).day ?? 0
    }
    public var isExpiring: Bool {
        guard let e = expiration else { return false }
        let d = Card.days(fromMillis: e)
        return d >= 0 && d <= 30
    }
    public var expiringInDays: Int {
        expiration.map { Card.days(fromMillis: $0) } ?? 0
    }
    public var isExpired: Bool {
        guard let e = expiration else { return false }
        return Card.days(fromMillis: e) < 0
    }

    /// XCard.size — total byte size of the card payload.
    public var size: Int {
        notes.utf8.count
            + fields.reduce(0) { $0 + $1.value.utf8.count }
            + images.reduce(0) { $0 + $1.length }
            + files.reduce(0) { $0 + $1.length }
            + (iconData?.count ?? 0)
    }

    /// XCard.asPlainText — plain-text dump used by TXT export.
    public func asPlainText() -> String {
        var lines = [title]
        for f in fields { lines.append("\(f.name): \(f.value)") }
        if !notes.isEmpty { lines.append(notes) }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Security flags (from XCard)

extension Card {
    /// Weak-password flag recomputed on demand (XCard.hasWeakPasswords).
    public var hasWeakPasswords: Bool {
        fields.contains { $0.type.needsScoring && !$0.value.isEmpty && PasswordStrength.score($0.value).score <= 1 }
    }
}
