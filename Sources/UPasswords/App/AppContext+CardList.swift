import Foundation

/// 卡片列表策略(CardListStrategy)、搜索、最近打开(RecentModel)。
extension AppContext {

    // MARK: - Selection

    var selectedCard: Card? {
        selectedCardId.flatMap { database.card(id: $0) }
    }

    // MARK: - Recent (RecentModel)

    private static let recentKey = "recent.cardIds"
    /// 最近打开列表容量上限(超出淘汰最旧条目)
    private static let recentLimit = 20

    var recentIds: [Int] {
        UserDefaults.standard.array(forKey: Self.recentKey) as? [Int] ?? []
    }

    func pushRecent(_ cardId: Int) {
        var ids = UserDefaults.standard.array(forKey: Self.recentKey) as? [Int] ?? []
        ids.removeAll { $0 == cardId }
        ids.insert(cardId, at: 0)
        if ids.count > Self.recentLimit { ids.removeLast(ids.count - Self.recentLimit) }
        UserDefaults.standard.set(ids, forKey: Self.recentKey)
        Log.info("ui", "pushRecent cardId=\(cardId) total=\(ids.count)")
        objectWillChange.send()
    }

    func clearRecent() {
        Log.info("ui", "clearRecent (had \(recentIds.count))")
        UserDefaults.standard.removeObject(forKey: Self.recentKey)
        objectWillChange.send()
    }

    // MARK: - Card list strategies (CardListStrategy)

    /// The card list for the current sidebar selection + search — mirrors the
    /// per-special-label strategies (ArchiveCardListStrategy, TrashCardListStrategy, …).
    func cards(for selection: SidebarSelection, search: String) -> [Card] {
        settings.sortingValue.sort(filteredCards(for: selection, search: search),
                                   favoritesFirst: settings.favoritesAtTop)
    }

    /// 过滤但未排序的列表。计数场景(侧栏角标)不必付出排序开销。
    private func filteredCards(for selection: SidebarSelection, search: String) -> [Card] {
        let searchWords = search.lowercased()
            .split(separator: " ").map(String.init).filter { !$0.isEmpty }
        var cards: [Card]
        switch selection {
        case .special(let sp):
            cards = strategyCards(for: sp)
        case .label(let labelId):
            cards = database.activeCards.filter { $0.labelIds.contains(labelId) && !$0.archived }
        }
        if !searchWords.isEmpty {
            cards = cards.filter { satisfiesSearch($0, words: searchWords) }
        }
        return cards
    }

    private func strategyCards(for sp: SpecialLabel) -> [Card] {
        let active = database.activeCards
        switch sp {
        case .allCards:
            return active.filter { !$0.archived }
        case .favorites:
            return active.filter { $0.favorite && !$0.archived }
        case .recent:
            let ids = recentIds
            return ids.compactMap { id in active.first { $0.id == id } }
        case .passwords:
            return active.filter { !$0.archived && $0.fields.contains { $0.type == .password } }
        case .oneTimeCodes:
            return active.filter { !$0.archived && $0.fields.contains { $0.type == .oneTimePassword } }
        case .notes:
            return active.filter { !$0.archived && $0.hasNotes && $0.fields.allSatisfy { !$0.type.isLogin && $0.type != .password } }
        case .files:
            return active.filter { !$0.archived && $0.hasFiles }
        case .images:
            return active.filter { !$0.archived && $0.hasImages }
        case .passkeys:
            return [] // passkeys are created in the mobile version (passkeys_empty_state)
        case .creditCards:
            return active.filter { !$0.archived && $0.symbol == "credit_card" }
        case .weakPasswords:
            return active.filter { !$0.archived && $0.hasWeakPasswords }
        case .samePasswords:
            let groups = SamePasswordsService.groups(cards: active)
            let ids = Set(groups.values.flatMap { $0 })
            return active.filter { ids.contains($0.id) }
        case .compromised:
            return active.filter { !$0.archived && $0.compromised }
        case .expiring:
            return active.filter { !$0.archived && !$0.trashed && $0.isExpiring }
        case .expired:
            return active.filter { !$0.archived && !$0.trashed && $0.isExpired }
        case .archived:
            return active.filter { $0.archived }
        case .trash:
            return database.cards.filter { $0.trashed }
        case .templates:
            return database.templateCards.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
    }

    /// Sidebar badge counts (show_card_count_setting)。只过滤不排序。
    func count(for selection: SidebarSelection) -> Int {
        filteredCards(for: selection, search: "").count
    }

    // MARK: - Search (XCard.satisfiesToSearchWords / previewForSearchWords)

    /// XCard.satisfiesToSearchWords:labelNames: — every word must hit title,
    /// field name/value, notes or label names; passwords optionally included.
    private func satisfiesSearch(_ card: Card, words: [String]) -> Bool {
        words.allSatisfy { containsWord(card, word: $0) }
    }

    private func containsWord(_ card: Card, word: String) -> Bool {
        if card.title.lowercased().contains(word) { return true }
        if card.notes.lowercased().contains(word) { return true }
        for f in card.fields {
            if f.name.lowercased().contains(word) { return true }
            if f.type.isSearchable {
                if !f.type.isHidden || settings.searchPasswords {
                    if f.value.lowercased().contains(word) { return true }
                } else if f.value.lowercased().contains(word) {
                    return true // hidden fields match on value but not shown in preview
                }
            }
        }
        if settings.searchByLabels {
            for lid in card.labelIds {
                if let l = database.label(id: lid), l.name.lowercased().contains(word) { return true }
            }
        }
        return false
    }

    /// XCard.previewForSearchWords — the "title — matched snippet" row preview.
    func searchPreview(for card: Card, word: String) -> String? {
        let w = word.lowercased()
        for f in card.fields where f.type.isSearchable {
            if !f.type.isHidden || settings.searchPasswords {
                if f.value.lowercased().contains(w) {
                    return "\(f.name): …\(snippet(f.value, around: w))…"
                }
            }
        }
        if card.notes.lowercased().contains(w) {
            return "…\(snippet(card.notes, around: w))…"
        }
        return nil
    }

    private func snippet(_ text: String, around w: String) -> String {
        guard let r = text.range(of: w, options: .caseInsensitive) else { return String(text.prefix(30)) }
        let start = text.index(r.lowerBound, offsetBy: -10, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(r.upperBound, offsetBy: 20, limitedBy: text.endIndex) ?? text.endIndex
        return String(text[start..<end])
    }
}
