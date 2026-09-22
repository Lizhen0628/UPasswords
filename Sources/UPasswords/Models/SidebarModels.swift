import Foundation

/// Mirrors the `MLabel` special sidebar labels (Models/*Label.h):
/// FavoritesLabel, RecentLabel, NotesLabel, FilesLabel, ImagesLabel,
/// PasskeysLabel, SamePasswordsLabel, CompromisedPasswordsLabel,
/// WeakPasswordsLabel, ArchivedLabel, TrashLabel, ExpiringLabel, ExpiredLabel,
/// plus AllCards / Passwords / OneTimeCodes / CreditCards / Templates.
enum SpecialLabel: String, CaseIterable, Identifiable {
    case allCards = "all_cards_label"
    case favorites = "favorites_label"
    case recent = "recent_label"
    case passwords = "passwords_label"
    case oneTimeCodes = "totp_label"
    case notes = "notes_label"
    case files = "files_label"
    case images = "images_label"
    case passkeys = "passkeys_label"
    case creditCards = "credit_cards_label"
    case weakPasswords = "weak_passwords_label"
    case samePasswords = "same_passwords_label"
    case compromised = "compromised_passwords_label"
    case expiring = "expiring_label"
    case expired = "expired_label"
    case archived = "archived_label"
    case trash = "trash_label"
    case templates = "templates_label"

    var id: String { rawValue }
    var name: String { L10n.db(rawValue) }

    var systemImage: String {
        switch self {
        case .allCards: return "square.grid.2x2"
        case .favorites: return "star.fill"
        case .recent: return "clock"
        case .passwords: return "key"
        case .oneTimeCodes: return "chart.pie.fill"
        case .notes: return "doc.plaintext"
        case .files: return "doc"
        case .images: return "photo"
        case .passkeys: return "person.badge.key.fill"
        case .creditCards: return "creditcard"
        case .weakPasswords: return "xmark.shield"
        case .samePasswords: return "exclamationmark.triangle"
        case .compromised: return "lock.open"
        case .expiring: return "hourglass"
        case .expired: return "hourglass"
        case .archived: return "archivebox"
        case .trash: return "trash"
        case .templates: return "doc.on.doc"
        }
    }

    /// Sidebar grouping per the original app: Safe / 标签 / 安全性 / 特殊,
    /// plus optional items hidden until enabled through the 「显示」 menu.
    var section: SidebarSection {
        switch self {
        case .allCards, .favorites, .creditCards, .notes, .oneTimeCodes, .passkeys, .recent:
            return .safe
        case .passwords, .files, .images:
            return .optionalItems
        case .compromised, .weakPasswords, .samePasswords:
            return .security
        case .expiring, .expired, .archived, .templates, .trash:
            return .special
        }
    }

    /// Icon tint matching the original sidebar (colored special marks).
    var iconColor: String? {
        switch self {
        case .favorites: return "yellow"
        case .compromised, .weakPasswords, .samePasswords: return "red"
        default: return nil
        }
    }

    /// Empty-state text (Localizable `*_empty_state` keys of the original).
    var emptyState: String {
        switch self {
        case .allCards: return L10n.t("user_empty_state")
        case .favorites: return L10n.t("favorites_empty_state")
        case .recent: return L10n.t("recent_empty_state")
        case .passkeys: return L10n.t("passkeys_empty_state")
        case .notes: return L10n.t("notes_empty_state")
        case .compromised: return L10n.t("compromised_passwords_empty_state")
        case .weakPasswords: return L10n.t("weak_passwords_empty_state")
        case .expired: return L10n.t("expired_empty_state")
        case .expiring: return L10n.t("expiring_empty_state")
        case .archived: return L10n.t("archived_empty_state")
        case .trash: return L10n.t("trash_empty_state")
        case .templates: return L10n.t("templates_empty_state")
        default: return L10n.t("user_empty_state")
        }
    }
}

enum SidebarSection: String, CaseIterable {
    case safe, labels, security, special, optionalItems

    var groupKey: String? {
        switch self {
        case .safe: return "safe_group"
        case .labels: return "labels_group"
        case .security: return "security_group"
        case .special: return "special_group"
        case .optionalItems: return nil
        }
    }
}

/// Colored group header icons of the original sidebar (LabelListGroupCell).
enum SidebarGroupStyle {
    case safe, labels, security, special

    var icon: String {
        switch self {
        case .safe: return "lock.shield"
        case .labels: return "tag"
        case .security: return "exclamationmark.shield"
        case .special: return "gearshape.2"
        }
    }

    var tint: Color {
        switch self {
        case .safe, .labels, .special: return .blue
        case .security: return .red
        }
    }
}

import SwiftUI

/// Sidebar selection: either a special label or a user label id.
enum SidebarSelection: Hashable {
    case special(SpecialLabel)
    case label(Int)

    static func == (l: SidebarSelection, r: SidebarSelection) -> Bool {
        switch (l, r) {
        case (.special(let a), .special(let b)): return a == b
        case (.label(let a), .label(let b)): return a == b
        default: return false
        }
    }
    func hash(into h: inout Hasher) {
        switch self {
        case .special(let s): h.combine(0); h.combine(s)
        case .label(let i): h.combine(1); h.combine(i)
        }
    }
}

/// Mirrors `SortingSet` (Services/SortingSet.h). Values = Localizable
/// `*_asc_text` / `*_desc_text` keys of the original app.
enum Sorting: String, CaseIterable, Identifiable {
    case titleAsc = "title_asc"
    case titleDesc = "title_desc"
    case createdAsc = "created_asc"
    case createdDesc = "created_desc"
    case modifiedAsc = "modified_asc"
    case modifiedDesc = "modified_desc"
    case sizeAsc = "size_asc"
    case sizeDesc = "size_desc"

    var id: String { rawValue }
    var name: String { L10n.t("\(rawValue)_text") }

    func sort(_ cards: [Card], favoritesFirst: Bool) -> [Card] {
        var out = cards
        switch self {
        case .titleAsc: out.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .titleDesc: out.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending }
        case .createdAsc: out.sort { $0.created < $1.created }
        case .createdDesc: out.sort { $0.created > $1.created }
        case .modifiedAsc: out.sort { $0.modified < $1.modified }
        case .modifiedDesc: out.sort { $0.modified > $1.modified }
        case .sizeAsc: out.sort { $0.size < $1.size }
        case .sizeDesc: out.sort { $0.size > $1.size }
        }
        if favoritesFirst {
            out.sort { $0.favorite && !$1.favorite }
        }
        return out
    }
}

/// Card color palette of `SelectColorViewController` — the original XML color
/// attribute vocabulary.
enum CardColor: String, CaseIterable, Identifiable {
    case gray, blue, red, green, yellow, purple, orange, cyan, pink, brown, white, black
    var id: String { rawValue }
}
