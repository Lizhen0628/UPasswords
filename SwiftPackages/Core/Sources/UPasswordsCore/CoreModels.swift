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

    /// 持久化类型词条，也是列表中的稳定标识。
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
    /// 字段是否默认遮蔽显示；不代表字段被单独加密。
    public var isHidden: Bool {
        switch self {
        case .password, .pin, .oneTimePassword, .secret: return true
        default: return false
        }
    }
    /// 字段是否保存一次性密码配置。
    public var isOneTimePassword: Bool { self == .oneTimePassword }
    /// 字段是否可作为登录标识，包含用户名与邮箱。
    public var isLogin: Bool { self == .login || self == .email }
    /// 字段是否使用数字输入语义。
    public var isNumber: Bool { self == .number }
    /// 字段是否参加搜索；一次性密码配置除外。
    public var isSearchable: Bool { self != .oneTimePassword }
    /// Password-like fields participate in weak/same/compromised analysis.
    public var needsScoring: Bool { self == .password }

    /// 该字段类型使用的 SF Symbols 名称。
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
    case givenName = "given-name"
    case familyName = "family-name"
    case email
    case telephone = "tel"
    case streetAddress = "street-address"
    case addressLine1 = "address-line1"
    case addressLine2 = "address-line2"
    case addressLevel1 = "address-level1"
    case addressLevel2 = "address-level2"
    case postalCode = "postal-code"
    case countryName = "country-name"
    case ccNumber = "cc-number"
    case ccName = "cc-name"
    case ccExp = "cc-exp"
    case ccCsc = "cc-csc"

    /// HTML autocomplete 词条，也是列表中的稳定标识。
    public var id: String { rawValue }

    /// Localized autofill name (strings table `*_autofill`).
    public var localizedName: String {
        switch self {
        case .off: return L10n.db("off_autofill")
        case .username: return L10n.db("username_autofill")
        case .currentPassword: return L10n.db("password_autofill")
        case .url: return L10n.db("url_autofill")
        case .oneTimeCode: return L10n.db("one_time_code_autofill")
        case .givenName: return L10n.db("given_name_autofill")
        case .familyName: return L10n.db("family_name_autofill")
        case .email: return L10n.db("email_autofill")
        case .telephone: return L10n.db("telephone_autofill")
        case .streetAddress: return L10n.db("street_address_autofill")
        case .addressLine1: return L10n.db("address_line_1_autofill")
        case .addressLine2: return L10n.db("address_line_2_autofill")
        case .addressLevel1: return L10n.db("address_level_1_autofill")
        case .addressLevel2: return L10n.db("address_level_2_autofill")
        case .postalCode: return L10n.db("postal_code_autofill")
        case .countryName: return L10n.db("country_name_autofill")
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
    /// 创建一条字段历史记录。
    ///
    /// - Parameters:
    ///   - value: 旧字段明文。
    ///   - time: 旧值对应的 Unix 毫秒时间戳。
    public init(value: String, time: TimeInterval) {
        self.value = value
        self.time = time
    }

    /// 历史字段明文，随所在密码库一起加密；不得写入日志。
    public var value: String
    /// 此次历史值的 Unix 时间戳，单位为毫秒。
    public var time: TimeInterval // millis since epoch
    /// 用于界面列表识别历史项的毫秒时间戳。
    public var id: TimeInterval { time }
}

/// A single named field on a card.
public struct Field: Codable, Equatable, Identifiable {
    /// 创建具有持久 UUID 身份的字段值。
    ///
    /// - Parameters:
    ///   - id: 持久字段 UUID。
    ///   - name: 展示名。
    ///   - type: 字段语义类型。
    ///   - value: 当前明文值。
    ///   - autofill: 自动填充词条。
    ///   - history: 随库加密的旧值集合。
    public init(id: UUID = UUID(), name: String, type: FieldType = .text, value: String = "",
                autofill: Autofill = .off, history: [HistoryEntry] = []) {
        self.id = id
        hasPersistentID = true
        self.name = name
        self.type = type
        self.value = value
        self.autofill = autofill
        self.history = history
    }

    /// 当前内存模型中的字段标识；旧 XML 缺少持久 ID 时会使用临时值。
    public var id: UUID = UUID()
    /// ID 是否来自持久化数据；临时 ID 不写入 XML 或编码数据。
    public internal(set) var hasPersistentID: Bool = true
    /// 字段展示名称，与字段类型和自动填充词条相互独立。
    public var name: String
    /// 字段的展示、输入和安全分析类型。
    public var type: FieldType = .text
    /// 字段明文；只允许在已解锁会话中使用。
    public var value: String = ""
    /// 自动填充的语义词条；off 表示不参与语义匹配。
    public var autofill: Autofill = .off
    /// 旧字段值及其修改时间，最多由 putHistoryValue 保留 20 项。
    public var history: [HistoryEntry] = []

    private enum CodingKeys: String, CodingKey {
        case id, name, type, value, autofill, history
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedID = try container.decodeIfPresent(UUID.self, forKey: .id)
        id = decodedID ?? UUID()
        hasPersistentID = decodedID != nil
        name = try container.decode(String.self, forKey: .name)
        type = try container.decode(FieldType.self, forKey: .type)
        value = try container.decode(String.self, forKey: .value)
        autofill = try container.decode(Autofill.self, forKey: .autofill)
        history = try container.decode([HistoryEntry].self, forKey: .history)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if hasPersistentID {
            try container.encode(id, forKey: .id)
        }
        try container.encode(name, forKey: .name)
        try container.encode(type, forKey: .type)
        try container.encode(value, forKey: .value)
        try container.encode(autofill, forKey: .autofill)
        try container.encode(history, forKey: .history)
    }

    /// 当前值是否为非空字符串；不自动裁剪空白。
    public var hasValue: Bool { !value.isEmpty }
    /// 是否保存过历史字段值。
    public var hasHistory: Bool { !history.isEmpty }

    /// 追加与当前值不同的非空历史值，并去重后保留最近 20 项。
    ///
    /// 此方法仅维护历史集合，不会修改 value；调用方负责提交当前字段值。
    /// - Parameters:
    ///   - v: 待保存的历史明文。
    ///   - time: 该值的 Unix 毫秒时间戳。
    public mutating func putHistoryValue(_ v: String, time: TimeInterval) {
        guard !v.isEmpty, v != value else { return }
        history.removeAll { $0.value == v }
        history.append(HistoryEntry(value: v, time: time))
        if history.count > 20 { history.removeFirst(history.count - 20) }
    }
}

/// Attached binary payload with a stable identity and per-content version token.
public struct Attachment: Codable, Equatable, Identifiable {
    /// 创建一个尚未单独加密的附件值。
    ///
    /// - Parameters:
    ///   - id: 持久附件 UUID。
    ///   - contentVersion: 此附件内容版本的稳定 UUID。
    ///   - name: 附件展示名。
    ///   - data: 附件原始字节；nil 表示仅有远端元数据，本机尚无内容副本。
    public init(id: UUID = UUID(), contentVersion: UUID = UUID(), name: String, data: Data?) {
        self.id = id
        hasPersistentID = true
        self.contentVersion = contentVersion
        hasPersistentContentVersion = true
        self.name = name
        self.data = data
    }

    /// 当前内存模型中的附件标识；旧 XML 缺少持久 ID 时会使用临时值。
    public var id: UUID = UUID()
    /// ID 是否来自持久化数据；临时 ID 不写入 XML 或编码数据。
    public internal(set) var hasPersistentID: Bool = true
    /// 当前附件字节版本的随机稳定令牌；重加密和改密不改变该值。
    public internal(set) var contentVersion: UUID = UUID()
    /// 版本令牌是否来自持久化数据；旧数据缺少版本令牌时为 false。
    public internal(set) var hasPersistentContentVersion: Bool = true
    /// 附件的展示文件名。
    public var name: String
    private var preservesVersionForContentMutation = false
    /// 已解码的附件明文字节；nil 表示内容未下载或本机副本不可用。
    public var data: Data? {
        didSet {
            guard !preservesVersionForContentMutation, data != oldValue else { return }
            contentVersion = UUID()
            hasPersistentContentVersion = true
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, contentVersion, name, data
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedID = try container.decodeIfPresent(UUID.self, forKey: .id)
        let decodedContentVersion = try container.decodeIfPresent(UUID.self, forKey: .contentVersion)
        let decodedData = try container.decodeIfPresent(Data.self, forKey: .data)
        guard decodedData != nil || (decodedID != nil && decodedContentVersion != nil) else {
            throw DecodingError.dataCorruptedError(
                forKey: .data,
                in: container,
                debugDescription: "An unavailable attachment requires a persistent ID and content version.")
        }
        id = decodedID ?? UUID()
        hasPersistentID = decodedID != nil
        contentVersion = decodedContentVersion ?? UUID()
        hasPersistentContentVersion = decodedContentVersion != nil
        name = try container.decode(String.self, forKey: .name)
        data = decodedData
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if hasPersistentID {
            try container.encode(id, forKey: .id)
        }
        if hasPersistentContentVersion {
            try container.encode(contentVersion, forKey: .contentVersion)
        }
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(data, forKey: .data)
    }

    /// Installs bytes downloaded for the currently referenced version.
    /// - Parameters:
    ///   - data: Authenticated plaintext bytes for the attachment.
    ///   - version: Version observed when the download was requested.
    /// - Returns: Whether the bytes matched the still-current content version.
    @discardableResult
    public mutating func installDownloadedContent(_ data: Data, for version: UUID) -> Bool {
        guard hasPersistentContentVersion, contentVersion == version else { return false }
        preservesVersionForContentMutation = true
        self.data = data
        preservesVersionForContentMutation = false
        contentVersion = version
        return true
    }

    /// Drops the local byte cache without changing the referenced content version.
    public mutating func discardLocalContent() {
        preservesVersionForContentMutation = true
        data = nil
        preservesVersionForContentMutation = false
    }

    /// 当前内存是否持有附件原始字节。
    public var hasContent: Bool { data != nil }

    /// 附件原始字节数；内容缺失时为 0。调用方需要区分缺失与合法空文件时应先检查 `hasContent`。
    public var length: Int { data?.count ?? 0 }

    /// 附件原始字节数；内容缺失时返回 nil。
    public var contentLength: Int? { data?.count }
}

/// A user label (`<label name id/>`).
public struct CardLabel: Codable, Equatable, Identifiable {
    /// 创建同步身份稳定的标签。
    ///
    /// - Parameters:
    ///   - id: 跨端稳定 UUID。
    ///   - name: 展示名。
    ///   - color: 可选颜色词条。
    ///   - type: 可选内置分类词条。
    ///   - pinToTop: 是否置顶。
    ///   - timeStamp: 最后修改的 Unix 毫秒时间戳。
    public init(id: UUID = UUID(), name: String, color: String? = nil, type: String? = nil,
                pinToTop: Bool = false, timeStamp: TimeInterval = 0) {
        self.id = id
        self.name = name
        self.color = color
        self.type = type
        self.pinToTop = pinToTop
        self.timeStamp = timeStamp
    }

    /// 跨设备同步的稳定标签身份。
    public var id: UUID = UUID()
    /// 用户可见的标签名称。
    public var name: String
    /// 可选颜色词条；nil 使用界面默认颜色。
    public var color: String? = nil
    /// 内置标签的语义分类词条；用户标签可以为空。
    public var type: String? = nil            // e.g. "web_accounts"
    /// 标签是否在侧栏优先显示。
    public var pinToTop: Bool = false
    /// 标签最后修改的 Unix 毫秒时间戳，用于冲突裁决。
    public var timeStamp: TimeInterval = 0    // millis

    /// 仅使用稳定身份生成标签哈希，与标签相等性保持一致。
    ///
    /// - Parameter hasher: 标准库提供的哈希累计器。
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    /// 比较标签身份；名称、颜色和修改时间不参与相等判断。
    ///
    /// - Parameters:
    ///   - l: 左侧标签。
    ///   - r: 右侧标签。
    /// - Returns: 两个标签是否拥有相同 UUID。
    public static func == (l: CardLabel, r: CardLabel) -> Bool { l.id == r.id }
}

/// A card. Attribute names match the XML exchange format
/// (title/id/symbol/color/template/autofill/favorite/archived/
/// trashed/expiration/reminder/created/modified);id 为 UUID v4
/// (客户端生成,行级同步的条目身份,离线多端无碰撞)。
public struct Card: Codable, Equatable, Identifiable {
    /// 创建空卡片，其他内容由默认属性值初始化。
    ///
    /// - Parameters:
    ///   - id: 跨端稳定 UUID。
    ///   - title: 展示标题；创建时间与修改时间由提交入口设置。
    public init(id: UUID = UUID(), title: String = "") {
        self.id = id
        self.title = title
    }

    /// 客户端生成的稳定 UUID，作为同步行身份及加密 AAD 的来源。
    public var id: UUID = UUID()
    /// 卡片展示标题。
    public var title: String = ""
    /// 可选 SF Symbols 名称。
    public var symbol: String? = nil
    /// 卡片的颜色词条。
    public var color: String? = nil
    /// 兼容导入数据的自定义图标名称；独立于 iconSource。
    public var customIconName: String? = nil
    /// 是否为模板卡；模板不参与普通密码列表与安全统计。
    public var template: Bool = false
    /// 卡片是否允许提供自动填充候选。
    public var autofillEnabled: Bool = false          // card-level autofill="on|off"
    /// 是否收藏；不改变卡片所属标签。
    public var favorite: Bool = false                 // favorite="true"
    /// 是否归档；与回收站状态分别保存。
    public var archived: Bool = false                 // archived="true"
    /// 是否处于回收站；永久删除由会话层另外执行。
    public var trashed: Bool = false                  // trashed="true"
    /// 可选到期时间，使用 Unix 毫秒时间戳。
    public var expiration: TimeInterval? = nil        // expiration millis
    /// 可选提醒时间，使用 Unix 毫秒时间戳。
    public var reminder: TimeInterval? = nil          // reminder millis
    /// 创建时间，使用 Unix 毫秒时间戳。
    public var created: TimeInterval = 0              // created millis
    /// 最后修改时间，使用 Unix 毫秒时间戳；云端同步不以此作为冲突胜负依据。
    public var modified: TimeInterval = 0             // modified millis
    /// 兼容旧数据的网站图标偏好；当前图标来源另见 iconSource。
    public var useWebsiteIcon: Bool = false
    /// 保留的手表展示标志。
    public var watch: Bool = false                    // atWatch
    /// 图标来源词表（IconService 常量）：website / custom / url:<…> / builtin:<key>。
    /// nil = 未设置，走默认符号/颜色圆形图标。
    public var iconSource: String? = nil
    /// 图标像素数据（≤128×128 PNG，XML 里 base64 存 <icon> 元素）。
    /// builtin 来源不带数据（随 App 分发），其余来源均有数据。
    public var iconData: Data? = nil
    /// 按用户展示顺序保存的字段；包含凭据明文。
    public var fields: [Field] = []
    /// 明文备注，随整个密码库加密。
    public var notes: String = ""
    /// 关联标签 UUID；名称变化不影响关联。
    public var labelIds: [UUID] = []
    /// 随卡片保存的图片附件。
    public var images: [Attachment] = []
    /// 随卡片保存的普通文件附件。
    public var files: [Attachment] = []

    // MARK: - 派生字段与到期状态
    /// 卡片是否作为模板使用。
    public var isTemplate: Bool { template }

    /// 首个用户名或邮箱字段。
    ///
    /// - Complexity: O(n)，n 为字段数。
    public var loginField: Field? { fields.first { $0.type.isLogin } }
    /// 首个密码类型字段。
    ///
    /// - Complexity: O(n)，n 为字段数。
    public var passwordField: Field? { fields.first { $0.type == .password } }
    /// 首个网站类型字段。
    ///
    /// - Complexity: O(n)，n 为字段数。
    public var websiteField: Field? { fields.first { $0.type == .website } }

    /// 首个登录字段的明文值；没有该字段时为空字符串。
    ///
    /// - Complexity: O(n)，n 为字段数。
    public var login: String { loginField?.value ?? "" }
    /// 首个密码字段的明文值；没有该字段时为空字符串。
    ///
    /// - Complexity: O(n)，n 为字段数。
    public var password: String { passwordField?.value ?? "" }
    /// 首个网站字段的原始值；此处不校验或规范化 URL。
    ///
    /// - Complexity: O(n)，n 为字段数。
    public var website: String { websiteField?.value ?? "" }
    /// 备注是否为非空字符串。
    public var hasNotes: Bool { !notes.isEmpty }
    /// 是否包含图片附件。
    public var hasImages: Bool { !images.isEmpty }
    /// 是否包含普通文件附件。
    public var hasFiles: Bool { !files.isEmpty }

    /// 按当前日历计算目标时间相对指定日期的整日差。
    ///
    /// - Parameters:
    ///   - ms: 目标 Unix 毫秒时间戳。
    ///   - date: 比较起点，默认使用当前时间。
    /// - Returns: 未来日期为正值，过去日期为负值；计算失败返回 0。
    public static func days(fromMillis ms: TimeInterval, to date: Date = Date()) -> Int {
        let d = Date(timeIntervalSince1970: ms / 1000)
        return Calendar.current.dateComponents([.day], from: date, to: d).day ?? 0
    }
    /// 到期日是否在当前日历的未来 0 至 30 天范围内。
    public var isExpiring: Bool {
        guard let e = expiration else { return false }
        let d = Card.days(fromMillis: e)
        return d >= 0 && d <= 30
    }
    /// 按当前日历计算的剩余天数；没有到期日时为 0。
    public var expiringInDays: Int {
        expiration.map { Card.days(fromMillis: $0) } ?? 0
    }
    /// 到期日相对当前日历是否已过去至少一天。
    public var isExpired: Bool {
        guard let e = expiration else { return false }
        return Card.days(fromMillis: e) < 0
    }

    /// 字段值、备注、本机可用附件及图标数据的累计字节数，不含标题与 XML 结构开销。
    ///
    /// - Complexity: O(n + b)，n 为字段和附件数，b 为统计的文本字节数。
    public var size: Int {
        notes.utf8.count
            + fields.reduce(0) { $0 + $1.value.utf8.count }
            + images.reduce(0) { $0 + $1.length }
            + files.reduce(0) { $0 + $1.length }
            + (iconData?.count ?? 0)
    }

    /// 按标题、字段和备注的顺序生成 TXT 导出的明文。
    ///
    /// - Returns: 含敏感字段值的多行文本；调用方负责导出位置与生命周期。
    public func asPlainText() -> String {
        var lines = [title]
        for f in fields { lines.append("\(f.name): \(f.value)") }
        if !notes.isEmpty { lines.append(notes) }
        return lines.joined(separator: "\n")
    }
}

// MARK: - 安全分析

extension Card {
    /// 是否包含评分不高于 1 的非空密码字段，按需计算。
    ///
    /// - Complexity: O(n + s)，n 为字段数，s 为尚未命中缓存的密码评分开销。
    public var hasWeakPasswords: Bool {
        fields.contains { $0.type.needsScoring && !$0.value.isEmpty && PasswordStrength.score($0.value).score <= 1 }
    }
}
