import Foundation

/// 卡片/标签 CRUD(DatabaseManager actions)、初始化清单、历史与数据库信息。
extension AppContext {

    // MARK: - Card CRUD (DatabaseManager actions)

    func newCardId() -> Int { database.nextItemId() }

    func upsertCard(_ card: Card) {
        var c = card
        c.modified = Date().millis
        let existed = database.cards.contains { $0.id == c.id }
        Log.info("ui", "upsertCard id=\(c.id) title.len=\(c.title.count) new=\(!existed)")
        if let i = database.cards.firstIndex(where: { $0.id == c.id }) {
            // keep old values in field history
            for (j, f) in c.fields.enumerated() {
                if let old = database.cards[i].fields.first(where: { $0.name == f.name && $0.type == f.type }) {
                    c.fields[j].putHistoryValue(old.value, time: old.modifiedOr(c.modified))
                }
            }
            database.cards[i] = c
        } else {
            database.cards.append(c)
        }
        selectedCardId = c.id
        saveDebounced()
        scheduleIconFetchAfterSave(cardId: c.id)
    }

    func trashCard(_ id: Int) {
        guard let i = database.cards.firstIndex(where: { $0.id == id }) else {
            Log.warn("ui", "trashCard id=\(id) skipped: card not found")
            return
        }
        Log.info("ui", "trashCard id=\(id)")
        database.cards[i].trashed = true
        database.cards[i].modified = Date().millis
        if selectedCardId == id { selectedCardId = nil }
        saveDebounced()
    }

    func deleteCardPermanently(_ id: Int) {
        Log.info("ui", "deleteCardPermanently id=\(id)")
        database.deleteCardPermanently(id: id)
        if selectedCardId == id { selectedCardId = nil }
        saveDebounced()
    }

    func restoreCard(_ id: Int) {
        guard let i = database.cards.firstIndex(where: { $0.id == id }) else {
            Log.warn("ui", "restoreCard id=\(id) skipped: card not found")
            return
        }
        Log.info("ui", "restoreCard id=\(id)")
        database.cards[i].trashed = false
        database.cards[i].archived = false
        database.cards[i].modified = Date().millis
        saveDebounced()
    }

    func archiveCard(_ id: Int) {
        guard let i = database.cards.firstIndex(where: { $0.id == id }) else {
            Log.warn("ui", "archiveCard id=\(id) skipped: card not found")
            return
        }
        Log.info("ui", "archiveCard id=\(id)")
        database.cards[i].archived = true
        database.cards[i].modified = Date().millis
        saveDebounced()
    }

    func unarchiveCard(_ id: Int) {
        guard let i = database.cards.firstIndex(where: { $0.id == id }) else {
            Log.warn("ui", "unarchiveCard id=\(id) skipped: card not found")
            return
        }
        Log.info("ui", "unarchiveCard id=\(id)")
        database.cards[i].archived = false
        database.cards[i].modified = Date().millis
        saveDebounced()
    }

    func toggleFavorite(_ id: Int) {
        guard let i = database.cards.firstIndex(where: { $0.id == id }) else {
            Log.warn("ui", "toggleFavorite id=\(id) skipped: card not found")
            return
        }
        database.cards[i].favorite.toggle()
        Log.info("ui", "toggleFavorite id=\(id) favorite=\(database.cards[i].favorite)")
        saveDebounced()
    }

    /// Sets the card-level `autofill="on|off"` XML attribute.
    func setCardAutofill(_ id: Int, on: Bool) {
        guard let i = database.cards.firstIndex(where: { $0.id == id }) else {
            Log.warn("ui", "setCardAutofill id=\(id) skipped: card not found")
            return
        }
        Log.info("ui", "setCardAutofill id=\(id) on=\(on)")
        database.cards[i].autofillEnabled = on
        saveDebounced()
    }

    func duplicateCard(_ id: Int) {
        guard let card = database.card(id: id) else {
            Log.warn("ui", "duplicateCard id=\(id) skipped: card not found")
            return
        }
        var copy = card
        copy.id = newCardId()
        copy.title = card.title
        copy.created = Date().millis
        copy.modified = copy.created
        copy.favorite = false
        database.cards.append(copy)
        selectedCardId = copy.id
        Log.info("ui", "duplicateCard id=\(id) → \(copy.id)")
        saveDebounced()
    }

    func emptyTrash() {
        let ids = database.cards.filter(\.trashed).map(\.id)
        Log.info("ui", "emptyTrash count=\(ids.count)")
        for id in ids { database.deleteCardPermanently(id: id) }
        saveDebounced()
    }

    // MARK: - Label CRUD

    func addLabel(name: String, color: String?) {
        let id = database.nextItemId()
        database.labels.append(CardLabel(id: id, name: name, color: color, timeStamp: Date().millis))
        Log.info("ui", "addLabel id=\(id) name.len=\(name.count)")
        saveDebounced()
    }

    func renameCardLabel(id: Int, to name: String) {
        guard let i = database.labels.firstIndex(where: { $0.id == id }) else {
            Log.warn("ui", "renameCardLabel id=\(id) skipped: label not found")
            return
        }
        Log.info("ui", "renameCardLabel id=\(id) name.len=\(name.count)")
        database.labels[i].name = name
        database.labels[i].timeStamp = Date().millis
        saveDebounced()
    }

    func setLabelColor(id: Int, color: String?) {
        guard let i = database.labels.firstIndex(where: { $0.id == id }) else {
            Log.warn("ui", "setLabelColor id=\(id) skipped: label not found")
            return
        }
        Log.info("ui", "setLabelColor id=\(id)")
        database.labels[i].color = color
        saveDebounced()
    }

    func toggleLabelPinned(id: Int) {
        guard let i = database.labels.firstIndex(where: { $0.id == id }) else {
            Log.warn("ui", "toggleLabelPinned id=\(id) skipped: label not found")
            return
        }
        database.labels[i].pinToTop.toggle()
        Log.info("ui", "toggleLabelPinned id=\(id) pinned=\(database.labels[i].pinToTop)")
        saveDebounced()
    }

    func deleteCardLabel(id: Int) {
        Log.info("ui", "deleteCardLabel id=\(id)")
        database.labels.removeAll { $0.id == id }
        for i in database.cards.indices {
            database.cards[i].labelIds.removeAll { $0 == id }
        }
        if case .label(id) = selection { selection = .special(.allCards) }
        saveDebounced()
    }

    /// Sets the labels attached to a card.
    func setLabels(cardId: Int, labelIds: [Int]) {
        guard let i = database.cards.firstIndex(where: { $0.id == cardId }) else {
            Log.warn("ui", "setLabels cardId=\(cardId) skipped: card not found")
            return
        }
        Log.info("ui", "setLabels cardId=\(cardId) labels=\(labelIds.count)")
        database.cards[i].labelIds = labelIds
        database.cards[i].modified = Date().millis
        saveDebounced()
    }

    /// Creates a label on the fly and assigns it to the card.
    func addLabelAndAssign(name: String, color: String?, to cardId: Int) {
        let id = database.nextItemId()
        database.labels.append(CardLabel(id: id, name: name, color: color, timeStamp: Date().millis))
        guard let i = database.cards.firstIndex(where: { $0.id == cardId }) else {
            Log.warn("ui", "addLabelAndAssign cardId=\(cardId) skipped: card not found (label id=\(id) kept)")
            return
        }
        Log.info("ui", "addLabelAndAssign cardId=\(cardId) labelId=\(id) name.len=\(name.count)")
        database.cards[i].labelIds.append(id)
        database.cards[i].modified = Date().millis
        saveDebounced()
    }

    // MARK: - Setup plan

    func setupTaskDone(_ task: SetupPlanTask) -> Bool {
        UserDefaults.standard.bool(forKey: "setup.done.\(task.rawValue)")
    }
    func markSetupTaskDone(_ task: SetupPlanTask) {
        UserDefaults.standard.set(true, forKey: "setup.done.\(task.rawValue)")
        objectWillChange.send()
    }
    func markSetupTaskDoneIf(_ task: SetupPlanTask, when cond: Bool) {
        if cond { markSetupTaskDone(task) }
    }
    var setupCompletedCount: Int { SetupPlanTask.allCases.filter(setupTaskDone).count }

    // MARK: - Info

    func dbsInfo() -> [DatabaseFile] { store.list() }

    var allHistoryEntries: [(card: Card, field: Field, entry: HistoryEntry)] {
        var out: [(card: Card, field: Field, entry: HistoryEntry)] = []
        for c in database.cards where !c.template {
            for f in c.fields {
                for e in f.history { out.append((card: c, field: f, entry: e)) }
            }
        }
        return out.sorted { l, r in l.entry.time > r.entry.time }
    }
}
